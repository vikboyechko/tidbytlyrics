"""
Applet: Spotify Lyrics
Summary: Display lyrics for currently playing Spotify track
Description: Shows lyrics synced to your currently playing Spotify song.
Author: Vik Boyechko
"""

load("cache.star", "cache")
load("encoding/base64.star", "base64")
load("encoding/json.star", "json")
load("http.star", "http")
load("humanize.star", "humanize")
load("render.star", "render")
load("schema.star", "schema")
load("secret.star", "secret")
load("time.star", "time")

# Spotify OAuth endpoints
SPOTIFY_AUTH_ENDPOINT = "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN_ENDPOINT = "https://accounts.spotify.com/api/token"

# LRCLIB endpoints (free, no auth required)
# Requests go through the local lyrics proxy (lyrics_proxy.py) to avoid
# Pixlet's 5s HTTP timeout. Use LRCLIB_BASE_PROD to call LRCLIB directly.
LRCLIB_BASE = "http://127.0.0.1:5555"
LRCLIB_BASE_PROD = "https://lrclib.net"
LRCLIB_ENDPOINT = LRCLIB_BASE + "/api/get"
LRCLIB_SEARCH_ENDPOINT = LRCLIB_BASE + "/api/search"

# Tidbyt display dimensions
DISPLAY_WIDTH = 64
DISPLAY_HEIGHT = 32

# Display layout
HEADER_HEIGHT = 7
LYRICS_HEIGHT = 25  # 32 - 7

# Latency compensation for deployed mode (no push loop): accounts for
# render + push + device display delay. Override with the latency_ms config arg.
LATENCY_OFFSET_MS = 2000

# Scheduled flips (push_loop.sh passes lead_ms + push_ms):
# time from here to the end of the render process, before the push can start
RENDER_TAIL_MS = 150

# Pre-render the next line if its push must start within this window. Must
# exceed the loop's idle cycle (~0.4s render + ~0.3s push + 1s sleep) so no
# flip falls between two renders.
SCHEDULE_HORIZON_MS = 2500

# Only used for server deployment (encrypt with `pixlet encrypt`). The local
# push loop reads your credentials from .env and never uses these values.
# The placeholders are needed for Pixlet's OAuth schema validation.
SPOTIFY_CLIENT_ID = secret.decrypt("YOUR_ENCRYPTED_CLIENT_ID") or "REPLACE_WITH_YOUR_CLIENT_ID"
SPOTIFY_CLIENT_SECRET = secret.decrypt("YOUR_ENCRYPTED_CLIENT_SECRET") or "REPLACE_WITH_YOUR_CLIENT_SECRET"

# Cache keys
CACHE_TOKEN_KEY = "spotify_access_token"
CACHE_TOKEN_TTL = 3500  # Spotify tokens last 3600s, refresh a bit early

def main(config):
    """Main entry point for the app."""

    # Demo mode for local testing
    demo_mode = config.bool("demo", False)
    if demo_mode:
        return demo_render(config)

    # Access token passed directly by push_loop.sh, which handles the refresh.
    # Each `pixlet render` is a fresh process, so cache.star never persists
    # between renders — refreshing in here would hit Spotify every cycle.
    access_token = config.get("access_token")

    if not access_token:
        # Deployed mode (Tidbyt/Tronbyt server): long-running process, cache
        # persists, so refreshing from the OAuth token in-app is fine.
        refresh_token = config.get("auth")

        if not refresh_token:
            return render_message("Please connect Spotify in the Tidbyt app")

        client_id = config.get("client_id", SPOTIFY_CLIENT_ID)
        client_secret = config.get("client_secret", SPOTIFY_CLIENT_SECRET)

        access_token = get_access_token(refresh_token, client_id, client_secret)

    if not access_token:
        return render_message("Could not authenticate with Spotify")

    # Get currently playing track
    track = get_currently_playing(access_token)

    if not track:
        return []

    track_name = track.get("name", "Unknown")
    artist_name = track.get("artist", "Unknown")
    duration_ms = track.get("duration_ms", 0)
    progress_ms = track.get("progress_ms", 0)

    # Push-loop mode: an immediate frame reaches the device about the render
    # tail + push time from now; scrolling text is phased for that moment
    display_shift_ms = 0
    if config.get("lead_ms"):
        display_shift_ms = RENDER_TAIL_MS + int(config.get("push_ms", "300"))

    # Fetch lyrics from LRCLIB
    lyrics_data = get_lyrics(track_name, artist_name, duration_ms)

    if not lyrics_data:
        return render_no_lyrics(track_name, artist_name)

    synced = lyrics_data.get("synced", "")
    parsed = parse_synced_lyrics(synced) if synced else []

    header_shift_ms = 0
    if len(parsed) > 0 and config.get("lead_ms"):
        # Scheduled mode (push_loop.sh). A fixed offset can't beat sampling:
        # with a ~2s cycle, each flip lands 0..2s after the ideal moment. So
        # when the next line starts soon, render it now and tell the loop the
        # exact wall-clock time the push must complete (FLIP_AT).
        lead_ms = int(config.get("lead_ms"))
        push_ms = int(config.get("push_ms", "300"))
        sample_ms = track["sample_ms"]
        now_ms = time.now().unix_nano // 1000000

        # Song position when an immediate push would reach the panel
        immediate_pos = progress_ms + (now_ms - sample_ms) + RENDER_TAIL_MS + push_ms + lead_ms
        current, upcoming, current_ts = get_current_lines(parsed, immediate_pos)
        next_ts = next_line_ts(parsed, current_ts)

        # Header scroll phase is set for the moment the push completes, for
        # both frame kinds - otherwise the header jumps a few px whenever an
        # immediate frame and a pre-rendered flip frame replace each other
        header_shift_ms = display_shift_ms

        if next_ts >= 0:
            # Push must complete lead_ms before the line is sung
            flip_at = sample_ms + (next_ts - progress_ms) - lead_ms
            push_start = flip_at - push_ms
            if push_start - now_ms <= SCHEDULE_HORIZON_MS:
                current, upcoming, current_ts = get_current_lines(parsed, next_ts)
                header_shift_ms = flip_at - now_ms
                print("FLIP_AT|%d" % flip_at)

        # Timing marker for /tmp/lyrics_timing.log (see tools/analyze_timing.py):
        # progress | sample wall ms | lead | shown line's LRC timestamp | text
        print("SHOWING|%d|%d|%d|%d|%s" % (progress_ms, sample_ms, lead_ms, current_ts, current))
    elif len(parsed) > 0:
        # Deployed mode: fixed offset for render/push/display latency
        latency_ms = int(config.get("latency_ms", LATENCY_OFFSET_MS))
        current, upcoming, _ = get_current_lines(parsed, progress_ms + latency_ms)
    else:
        # No usable timestamps (plain-only lyrics, or un-timestamped text in
        # syncedLyrics, even after get_lyrics tried other uploads). Without
        # timing a lyric line would sit frozen, so treat it as no lyrics.
        return render_no_lyrics(track_name, artist_name)

    current = normalize_case(current)
    upcoming = normalize_case(upcoming)

    if not current and not upcoming:
        return render_no_lyrics(track_name, artist_name)

    return render_lyrics(current, upcoming, track_name, artist_name, progress_ms, header_shift_ms)

def get_access_token(refresh_token, client_id, client_secret):
    """Get access token from cache or refresh it."""

    # Check cache first
    cached_token = cache.get(CACHE_TOKEN_KEY)
    if cached_token:
        return cached_token

    # Refresh the token
    auth_header = base64.encode("%s:%s" % (client_id, client_secret))

    response = http.post(
        url = SPOTIFY_TOKEN_ENDPOINT,
        headers = {
            "Authorization": "Basic %s" % auth_header,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        body = "grant_type=refresh_token&refresh_token=%s" % refresh_token,
    )

    if response.status_code != 200:
        print("Failed to refresh token: %s" % response.body())
        return None

    data = response.json()
    access_token = data.get("access_token")

    if access_token:
        cache.set(CACHE_TOKEN_KEY, access_token, ttl_seconds = CACHE_TOKEN_TTL)

    return access_token

def get_currently_playing(access_token):
    """Fetch currently playing track from Spotify."""

    t0 = time.now().unix_nano // 1000000
    response = http.get(
        url = "https://api.spotify.com/v1/me/player/currently-playing",
        headers = {
            "Authorization": "Bearer %s" % access_token,
        },
        ttl_seconds = 1,
    )

    # Wall clock (unix ms) at which progress_ms was true: midpoint of the
    # request, since Spotify samples somewhere between send and receive
    sample_ms = (t0 + time.now().unix_nano // 1000000) // 2

    # 204 means nothing is playing
    if response.status_code == 204:
        return None

    # Marker for push_loop.sh: token rejected, force a refresh and skip push
    if response.status_code == 401:
        print("AUTH_ERROR_401")
        return None

    if response.status_code != 200:
        print("Spotify API error: %s" % response.body())
        return None

    data = response.json()

    # Check if actually playing
    if not data.get("is_playing", False):
        return None

    item = data.get("item")
    if not item:
        return None

    # Extract artist name (first artist if multiple)
    artists = item.get("artists", [])
    artist_name = artists[0].get("name", "Unknown") if artists else "Unknown"

    return {
        "name": item.get("name", "Unknown"),
        "artist": artist_name,
        "duration_ms": item.get("duration_ms", 0),
        "progress_ms": int(data.get("progress_ms", 0)),
        "sample_ms": sample_ms,
    }

def get_lyrics(track_name, artist_name, duration_ms):
    """Fetch lyrics from LRCLIB. Returns dict with synced and plain lyrics.

    If the primary /api/get entry has no usable timestamps (some uploads
    put plain text in syncedLyrics), searches alternative uploads of the
    same track and picks the timestamped entry whose duration best matches
    the track Spotify is playing.
    """

    query = "artist_name=%s&track_name=%s" % (
        humanize.url_encode(artist_name),
        humanize.url_encode(track_name),
    )

    synced = ""
    plain = ""
    response = http.get(url = LRCLIB_ENDPOINT + "?" + query, ttl_seconds = 3600)
    if response.status_code == 200:
        data = response.json()
        synced = data.get("syncedLyrics") or ""
        plain = data.get("plainLyrics") or ""

    # Primary entry has real timestamps - done
    if synced and len(parse_synced_lyrics(synced)) > 0:
        return {"synced": synced, "plain": plain}

    # Primary entry missing or un-timestamped: try alternative uploads
    response = http.get(url = LRCLIB_SEARCH_ENDPOINT + "?" + query, ttl_seconds = 3600)
    if response.status_code == 200:
        best = None
        best_diff = 0
        for entry in response.json():
            alt_synced = entry.get("syncedLyrics") or ""
            if not alt_synced or len(parse_synced_lyrics(alt_synced)) == 0:
                continue
            diff = (entry.get("duration") or 0) * 1000 - duration_ms
            if diff < 0:
                diff = -diff
            if best == None or diff < best_diff:
                best = entry
                best_diff = diff
        if best != None:
            return {
                "synced": best.get("syncedLyrics") or "",
                "plain": best.get("plainLyrics") or plain,
            }

    if not synced and not plain:
        return None

    return {"synced": synced, "plain": plain}

def is_digits(s):
    """True if s is non-empty and all ASCII digits (Starlark has no regex)."""
    if s == "":
        return False
    for c in s.elems():
        if c < "0" or c > "9":
            return False
    return True

def parse_timestamp(ts_str):
    """Parse LRC timestamp MM:SS.xx to milliseconds.

    Returns -1 for bracket tags that aren't timestamps - LRC files can
    contain metadata like [ar: artist] or section markers like [Verse 1].
    """
    parts = ts_str.split(":")
    if len(parts) != 2:
        return -1
    sec_parts = parts[1].split(".")
    seconds = sec_parts[0]
    centiseconds = sec_parts[1] if len(sec_parts) > 1 else "0"
    if not is_digits(parts[0]) or not is_digits(seconds) or not is_digits(centiseconds):
        return -1
    return (int(parts[0]) * 60 + int(seconds)) * 1000 + int(centiseconds) * 10

def parse_synced_lyrics(synced_text):
    """Parse LRC format into list of {time_ms, text} entries."""
    result = []
    for line in synced_text.split("\n"):
        line = line.strip()
        if not line or not line.startswith("["):
            continue
        bracket_end = line.find("]")
        if bracket_end == -1:
            continue
        ts_str = line[1:bracket_end]
        text = line[bracket_end + 1:].strip()
        time_ms = parse_timestamp(ts_str)
        if time_ms < 0:
            continue  # metadata/section tag, not a timestamped lyric
        result.append({"time_ms": time_ms, "text": text})
    return result

def get_current_lines(parsed_lyrics, progress_ms):
    """Find the current and next lyric lines at the given progress.

    Returns (current_text, upcoming_text, current_line_timestamp_ms).
    Timestamp is -1 when no line has been reached yet.
    """
    current = ""
    upcoming = ""
    current_ts = -1
    found = False

    for i in range(len(parsed_lyrics)):
        if parsed_lyrics[i]["time_ms"] <= progress_ms:
            found = True
            current = parsed_lyrics[i]["text"]
            current_ts = parsed_lyrics[i]["time_ms"]
            if i + 1 < len(parsed_lyrics):
                upcoming = parsed_lyrics[i + 1]["text"]
            else:
                upcoming = ""
        else:
            break

    # If we haven't reached any lyrics yet, show first line as dim preview
    if not found and len(parsed_lyrics) > 0:
        upcoming = parsed_lyrics[0]["text"]

    return current, upcoming, current_ts

def next_line_ts(parsed_lyrics, current_ts):
    """Timestamp of the first line after current_ts, or -1 at the end."""
    for line in parsed_lyrics:
        if line["time_ms"] > current_ts:
            return line["time_ms"]
    return -1

def normalize_case(text):
    """Convert ALL CAPS or MOSTLY CAPS text to sentence case."""
    if not text:
        return text

    # Count uppercase vs lowercase letters
    upper = 0
    lower = 0
    for c in text.elems():
        if c != c.lower():
            upper = upper + 1
        elif c != c.upper():
            lower = lower + 1

    # If more than half of letters are uppercase, convert to sentence case
    if upper > 0 and (lower == 0 or upper > lower):
        return text[0] + text[1:].lower()
    return text

def wrap_rows(text, chars_per_row):
    """Estimate display rows after greedy word wrap (~4px/char fonts)."""
    rows = 1
    cur = 0
    for word in text.split(" "):
        if word == "":
            continue
        need = len(word) if cur == 0 else cur + 1 + len(word)
        if need <= chars_per_row:
            cur = need
        else:
            rows += 1
            cur = min(len(word), chars_per_row)
    return rows

def truncate_to_rows(text, chars_per_row, max_rows):
    """Cut text at a word boundary so it (plus ellipsis) fits max_rows."""
    out = ""
    for word in text.split(" "):
        candidate = word if out == "" else out + " " + word
        if wrap_rows(candidate + "...", chars_per_row) > max_rows:
            return out + "..."
        out = candidate
    return out

# 62px wrap width / ~4px per char (tom-thumb and CG-pixel-3x5-mono alike)
LYRIC_CHARS_PER_ROW = 15

def render_lyrics(current, upcoming, track_name, artist_name, progress_ms, header_shift_ms = 0):
    """Render current lyric line with upcoming line below.

    Overflow handling for the 25px lyrics area:
    - <= 4 rows of tom-thumb (6px each): normal rendering
    - 5 rows: linespacing -1 tightens rows to 5px, so 5 fit exactly
    - 6+ rows: tightened rows + truncate at a word boundary with ellipsis
    """

    rows = wrap_rows(current, LYRIC_CHARS_PER_ROW) if current else 0
    lyric_linespacing = 0
    if rows >= 5:
        lyric_linespacing = -1
        if rows >= 6:
            current = truncate_to_rows(current, LYRIC_CHARS_PER_ROW, 5)

    # If current is long (3+ display lines), drop upcoming to avoid overflow
    show_upcoming = upcoming and len(current) <= 32

    children = []
    if current:
        children.append(
            render.WrappedText(
                content = current,
                width = DISPLAY_WIDTH - 2,
                font = "tom-thumb",
                linespacing = lyric_linespacing,
                color = "#CCCCCC",
                align = "center",
            ),
        )
    if show_upcoming:
        children.append(render.Box(height = 2, width = 1))
        children.append(
            render.WrappedText(
                content = upcoming,
                width = DISPLAY_WIDTH - 2,
                font = "tom-thumb",
                color = "#555555",
                align = "center",
            ),
        )

    return render.Root(
        delay = 100,
        child = render.Column(
            children = [
                render_header(track_name, artist_name, header_shift_ms),
                # Lyrics (static)
                render.Box(
                    width = DISPLAY_WIDTH,
                    height = LYRICS_HEIGHT,
                    child = render.Column(
                        expanded = True,
                        main_align = "center",
                        cross_align = "center",
                        children = children,
                    ),
                ),
            ],
        ),
    )

def render_header(track_name, artist_name, shift_ms = 0):
    """Header bar with continuously scrolling title - artist."""
    header_text = render.Text(
        content = "%s - %s" % (track_name, artist_name),
        font = "CG-pixel-3x5-mono",
        color = "#888888",
    )

    return render.Box(
        width = DISPLAY_WIDTH,
        height = HEADER_HEIGHT,
        color = "#0D3320",
        child = clock_marquee(header_text, 100, shift_ms),
    )

def clock_marquee(text_widget, ms_per_px, shift_ms = 0):
    """Marquee whose scroll position follows the wall clock.

    Each push replaces the whole image, which restarts any animation from
    frame 0 - so a plain Marquee never scrolls past its first ~2 seconds.
    Instead, the scroll position is derived from the wall clock: every push
    starts the marquee at the offset the previous one reached, so the scroll
    appears continuous across pushes. shift_ms moves the clock forward to the
    moment the frame reaches the device. ms_per_px must match the Root delay
    (Marquee moves 1px per frame).
    """
    text_w = text_widget.size()[0]
    if text_w <= DISPLAY_WIDTH:
        return text_widget  # fits without scrolling

    # Virtual infinite scroll: text moves left 1px per frame, exits left,
    # re-enters from the right edge. Loop length in px:
    loop_px = text_w + DISPLAY_WIDTH
    phase = ((time.now().unix_nano // 1000000 + shift_ms) // ms_per_px) % loop_px
    if phase <= text_w:
        offset = -phase  # scrolling out: text starts shifted left
    else:
        offset = DISPLAY_WIDTH - (phase - text_w)  # re-entering from right
    return render.Marquee(
        width = DISPLAY_WIDTH,
        offset_start = offset,
        child = text_widget,
    )

def render_no_lyrics(track_name, artist_name):
    """Render display when no lyrics are found.

    Nothing here changes until the track does, so push_loop.sh pushes this
    screen once per track (STATIC_FRAME marker) and lets the device loop it.
    Plain Marquees loop seamlessly that way; re-pushing every cycle would make
    them jump.
    """

    print("STATIC_FRAME|%s|%s" % (track_name, artist_name))

    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "space_evenly",
            cross_align = "center",
            children = [
                render.Text(
                    content = "Now Playing",
                    font = "tom-thumb",
                    color = "#888888",
                ),
                render.Marquee(
                    width = DISPLAY_WIDTH,
                    align = "center",
                    child = render.Text(
                        content = track_name,
                        font = "5x8",
                        color = "#FFF",
                    ),
                ),
                render.Marquee(
                    width = DISPLAY_WIDTH,
                    align = "center",
                    child = render.Text(
                        content = artist_name,
                        font = "tom-thumb",
                        color = "#AAA",
                    ),
                ),
            ],
        ),
    )

def render_message(message):
    """Render a simple message."""

    return render.Root(
        child = render.Box(
            width = DISPLAY_WIDTH,
            height = DISPLAY_HEIGHT,
            child = render.WrappedText(
                content = message,
                width = DISPLAY_WIDTH - 4,
                font = "tom-thumb",
                color = "#FFF",
                align = "center",
            ),
        ),
    )

def demo_render(config):
    """Demo mode for local testing - uses sample track data.

    Optional config overrides for testing:
        pixlet render spotify_lyrics.star demo=true line='very long line...' next='...'
        pixlet render spotify_lyrics.star demo=true track='Song' artist='Artist' at=60000
    """

    track_name = config.get("track") or "Yellow"
    artist_name = config.get("artist") or "Coldplay"
    progress_ms = int(config.get("at", "60000"))

    test_line = config.get("line")
    if test_line:
        return render_lyrics(test_line, config.get("next", ""), track_name, artist_name, progress_ms)

    lyrics_data = get_lyrics(track_name, artist_name, 269000)

    if not lyrics_data:
        return render_no_lyrics(track_name, artist_name)

    synced = lyrics_data.get("synced")
    if synced and synced != "":
        parsed = parse_synced_lyrics(synced)
        current, upcoming, _ = get_current_lines(parsed, progress_ms)
    else:
        current = "Demo lyrics line"
        upcoming = "Next line preview"

    return render_lyrics(current, upcoming, track_name, artist_name, progress_ms)

def oauth_handler(params):
    """
    Handle OAuth callback from Spotify.
    Exchange authorization code for refresh token.
    """

    params = json.decode(params)
    code = params.get("code")
    redirect_uri = params.get("redirect_uri")

    if not code:
        return None

    auth_header = base64.encode("%s:%s" % (SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET))

    response = http.post(
        url = SPOTIFY_TOKEN_ENDPOINT,
        headers = {
            "Authorization": "Basic %s" % auth_header,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        body = "grant_type=authorization_code&code=%s&redirect_uri=%s" % (code, redirect_uri),
    )

    if response.status_code != 200:
        print("OAuth token exchange failed: %s" % response.body())
        return None

    data = response.json()
    refresh_token = data.get("refresh_token")

    # Also cache the initial access token
    access_token = data.get("access_token")
    if access_token:
        cache.set(CACHE_TOKEN_KEY, access_token, ttl_seconds = CACHE_TOKEN_TTL)

    return refresh_token

def get_schema():
    """Define the app configuration schema."""

    return schema.Schema(
        version = "1",
        fields = [
            schema.OAuth2(
                id = "auth",
                name = "Spotify",
                desc = "Connect your Spotify account",
                icon = "spotify",
                handler = oauth_handler,
                client_id = SPOTIFY_CLIENT_ID,
                authorization_endpoint = SPOTIFY_AUTH_ENDPOINT,
                scopes = [
                    "user-read-currently-playing",
                ],
            ),
            schema.Toggle(
                id = "demo",
                name = "Demo Mode",
                desc = "Use sample data for testing (no Spotify auth needed)",
                icon = "flask",
                default = False,
            ),
        ],
    )
