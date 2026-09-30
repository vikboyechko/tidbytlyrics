#!/bin/bash
# Continuously renders and pushes lyrics to Tidbyt.
#
# The Spotify access token is refreshed here (once per ~50 min), not in the
# Starlark app: each `pixlet render` is a fresh process whose cache doesn't
# persist, so refreshing in-app would hit Spotify's token endpoint every cycle.
#
# Usage: ./push_loop.sh  (or ./start.sh to run it with the lyrics proxy)
# Requires:
#   - .env file with credentials (copy .env.example and fill in values)
#   - lyrics_proxy.py running

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load credentials from .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
else
    echo "Error: .env file not found. Copy .env.example to .env and fill in your credentials."
    exit 1
fi

DEVICE_ID="${TIDBYT_DEVICE_ID:?Set TIDBYT_DEVICE_ID in .env}"
API_TOKEN="${TIDBYT_API_TOKEN:?Set TIDBYT_API_TOKEN in .env}"
REFRESH_TOKEN="${SPOTIFY_REFRESH_TOKEN:?Set SPOTIFY_REFRESH_TOKEN in .env}"
CLIENT_ID="${SPOTIFY_CLIENT_ID:?Set SPOTIFY_CLIENT_ID in .env}"
CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:?Set SPOTIFY_CLIENT_SECRET in .env}"

INTERVAL=1           # sleep between cycles; render+push adds ~0.7s on top
TOKEN_LIFETIME=3000  # refresh access token every ~50 min (Spotify tokens last 60)

ACCESS_TOKEN=""
TOKEN_TIME=0
RENDER_FAILS=0
LAST_STATIC=""       # STATIC_FRAME key of the frame on the device, if static
PUSH_TIMES=()        # recent push durations (ms), for the scheduling estimate

now_ms() {
    perl -MTime::HiRes=time -e 'printf("%d\n", time * 1000)'
}

# Median of the last 7 push durations; 300ms until we have data
push_estimate_ms() {
    if [ ${#PUSH_TIMES[@]} -eq 0 ]; then
        echo 300
        return
    fi
    printf '%s\n' "${PUSH_TIMES[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}

refresh_access_token() {
    local resp token
    resp=$(curl -s --max-time 10 -X POST https://accounts.spotify.com/api/token \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=refresh_token&refresh_token=${REFRESH_TOKEN}&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}")
    token=$(printf '%s' "$resp" | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token', ''))" 2>/dev/null)
    if [ -n "$token" ]; then
        ACCESS_TOKEN="$token"
        TOKEN_TIME=$(date +%s)
        echo "$(date '+%H:%M:%S') Refreshed Spotify access token"
    else
        echo "$(date '+%H:%M:%S') Token refresh failed: $resp"
    fi
}

echo "Spotify Lyrics push loop started (Ctrl+C to stop)"

while true; do
    # Refresh token at startup, near expiry, or after a 401
    now=$(date +%s)
    if [ -z "$ACCESS_TOKEN" ] || [ $((now - TOKEN_TIME)) -ge "$TOKEN_LIFETIME" ]; then
        refresh_access_token
        if [ -z "$ACCESS_TOKEN" ]; then
            sleep 5
            continue
        fi
    fi

    # Re-read .env each cycle so DISPLAY_LEAD_MS can be tuned live while a
    # song plays (edit, save, takes effect within ~2s)
    source "$SCRIPT_DIR/.env"
    push_est=$(push_estimate_ms)

    output=$(pixlet render -d 300000 "$SCRIPT_DIR/spotify_lyrics.star" \
        "access_token=$ACCESS_TOKEN" \
        "lead_ms=${DISPLAY_LEAD_MS:--300}" \
        "push_ms=$push_est" 2>&1)
    render_status=$?
    [ "$render_status" -eq 0 ] && RENDER_FAILS=0

    # Token rejected mid-lifetime: force a refresh, keep last frame on screen
    if echo "$output" | grep -q "AUTH_ERROR_401"; then
        echo "$(date '+%H:%M:%S') Spotify rejected token, refreshing"
        ACCESS_TOKEN=""
        continue
    fi

    if [ "$render_status" -eq 0 ]; then
        # Nothing playing -> app renders an empty webp; skip the push and keep
        # the last good frame on the device instead of spamming the API
        if [ ! -s "$SCRIPT_DIR/spotify_lyrics.webp" ]; then
            echo "$(date '+%H:%M:%S') Nothing playing, keeping last frame"
            sleep "$INTERVAL"
            continue
        fi
        # Static screen ("Now Playing", no lyrics) already on the device:
        # don't re-push. The device loops the image seamlessly; re-pushing
        # restarts its marquees and makes them jump
        static=$(printf '%s\n' "$output" | grep -m1 'STATIC_FRAME|' | sed 's/.*STATIC_FRAME|//')
        if [ -n "$static" ] && [ "$static" = "$LAST_STATIC" ]; then
            sleep "$INTERVAL"
            continue
        fi

        # The app pre-rendered the next line: wait so the push completes at
        # FLIP_AT (the line's start minus DISPLAY_LEAD_MS)
        flip_at=$(printf '%s\n' "$output" | grep -m1 'FLIP_AT|' | sed 's/.*FLIP_AT|//')
        if [ -n "$flip_at" ]; then
            wait_ms=$((flip_at - push_est - $(now_ms)))
            if [ "$wait_ms" -gt 0 ]; then
                sleep "$(printf '%d.%03d' $((wait_ms / 1000)) $((wait_ms % 1000)))"
            fi
        fi

        p0=$(now_ms)
        if pixlet push "$DEVICE_ID" "$SCRIPT_DIR/spotify_lyrics.webp" \
            -t "$API_TOKEN" -i spotifylyrics 2>/dev/null; then
            p1=$(now_ms)
            PUSH_TIMES=("${PUSH_TIMES[@]: -6}" $((p1 - p0)))
            LAST_STATIC="$static"
            echo "$(date '+%H:%M:%S') Pushed update${flip_at:+ (scheduled flip)}"
            # Timing log for tools/analyze_timing.py: push-complete wall
            # clock (ms) + the app's SHOWING marker
            marker=$(printf '%s\n' "$output" | grep -m1 'SHOWING|' | sed 's/.*SHOWING|/SHOWING|/')
            if [ -n "$marker" ]; then
                echo "$p1 $marker" >> /tmp/lyrics_timing.log
            fi
            # Flip done: render again at once to catch a quick next line
            [ -n "$flip_at" ] && continue
        else
            echo "$(date '+%H:%M:%S') Push failed, keeping last frame"
        fi
    else
        echo "$(date '+%H:%M:%S') Render failed: $output"
        # Usually a rare Pixlet font-cache race ("concurrent map writes"):
        # retry at once so a scheduled flip isn't lost (once; then back off)
        RENDER_FAILS=$((RENDER_FAILS + 1))
        [ "$RENDER_FAILS" -le 1 ] && continue
    fi

    sleep "$INTERVAL"
done
