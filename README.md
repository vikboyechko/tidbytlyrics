# Spotify Lyrics for Tidbyt

Show synced lyrics on your Tidbyt for whatever you're playing on Spotify.

![Tidbyt on a shelf showing synced Spotify lyrics](images/spotify-lyrics-tidbyt.jpg)

The current line shows in white, with the next line in gray below it. A green header scrolls the song title and artist. When nothing is playing, the app stops sending new frames.

Lyrics come from [LRCLIB](https://lrclib.net), a free community database of timestamped lyrics.

Read the full story of how this was built: **[Spotify Lyrics on a Tidbyt](https://vikboyechko.com/blog/spotify-lyrics-tidbyt/)**

## What you need

- A Tidbyt
- A Mac, Linux computer, or Raspberry Pi with internet access, left running while you listen
- [Pixlet](https://github.com/tidbyt/pixlet) (on a Mac: `brew install tidbyt/tidbyt/pixlet`)
- Python 3
- A Spotify Premium account (Spotify requires Premium for developer apps)

## Setup

### 1. Download this project

```bash
git clone https://github.com/vikboyechko/tidbytlyrics.git
cd tidbytlyrics
cp .env.example .env
```

You'll paste your keys into `.env` in the next steps.

### 2. Create a Spotify developer app

1. Go to the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and click **Create app**.
2. Give it any name, like "Tidbyt Lyrics".
3. Add `http://127.0.0.1:8080/callback` as a **Redirect URI**.
4. Check the **Web API** box and save.
5. Copy the **Client ID** and **Client Secret** into `.env`.

### 3. Get a Spotify refresh token

You only do this once.

**a.** Open this URL in your browser. Replace `YOUR_CLIENT_ID` first.

```
https://accounts.spotify.com/authorize?client_id=YOUR_CLIENT_ID&scope=user-read-currently-playing&redirect_uri=http://127.0.0.1:8080/callback&response_type=code
```

**b.** Log in and click **Agree**. The browser goes to a page that doesn't load. That's expected. Copy the `code` value from the address bar:

```
http://127.0.0.1:8080/callback?code=AQB-xxxxx...
                                    ^^^^^^^^^^^^ copy this part
```

**c.** Run this in your terminal. Replace the code, client ID, and client secret.

```bash
curl -s -X POST https://accounts.spotify.com/api/token \
  -d "grant_type=authorization_code&code=PASTE_CODE_HERE&redirect_uri=http://127.0.0.1:8080/callback&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET" \
  | python3 -m json.tool
```

**d.** Copy the `refresh_token` value from the response into `.env`.

The code from step b works only once and expires after a few minutes. If step c gives an error, start again at step a.

### 4. Get your Tidbyt device ID and API key

In the Tidbyt mobile app, open your device's settings and tap **Get API key**. Copy the **Device ID** and **API Token** into `.env`.

### 5. Start it

```bash
./start.sh
```

Play a song on Spotify. Lyrics show up on your Tidbyt within a few seconds. Press `Ctrl+C` to stop.

## Adjusting the timing

If lyrics show up too late or too early, change `DISPLAY_LEAD_MS` in `.env`:

- Lyrics too late: raise it (for example, from `-300` to `0`).
- Lyrics too early: lower it (for example, from `-300` to `-600`).

You don't need to restart. The app reads `.env` again every cycle.

## Troubleshooting

- **"Token refresh failed" in the terminal**: check the client ID and secret in `.env`. If they're right, your refresh token may be revoked. Do step 3 again.
- **"Nothing playing, keeping last frame" while music plays**: make sure Spotify is playing on a device signed in to the same account you authorized in step 3.
- **"Push failed, keeping last frame"**: check the device ID and API token in `.env`, and make sure your Tidbyt is online.
- **"Now Playing" instead of lyrics**: LRCLIB doesn't have timed lyrics for that song. The app shows the song title and artist instead.
- **"Error: .env file not found"**: run `cp .env.example .env` and fill in your keys.

## How it works

`start.sh` runs two things:

- `lyrics_proxy.py` is a small local server that fetches lyrics from LRCLIB and caches them. Pixlet stops any web request after 5 seconds, and LRCLIB is sometimes slower than that.
- `push_loop.sh` renders a new frame with `spotify_lyrics.star` about every 2 seconds. Then it sends the frame to your Tidbyt through the Tidbyt push API (`pixlet push`). The frames go through Tidbyt's servers, not over your home network, so the app needs Tidbyt's servers to be online. Each render asks Spotify for the exact playback position. When the next line is about to start, the app renders it early, and the loop times the push so the line shows when it's sung.

`tools/analyze_timing.py` is an optional debugging script. It reads the timing log that the push loop writes to `/tmp/lyrics_timing.log` and shows how close each line change was to its target.

## Future work

Every frame goes through Tidbyt's servers, so the app stops working if those servers go offline. A possible next step is a local [Tronbyt](https://tronbyt.com/) server. A Tidbyt with Tronbyt firmware gets its images from a server on your own network, so the app would not depend on Tidbyt. This is not built or tested yet.

## License

MIT. See [LICENSE](LICENSE).
