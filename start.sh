#!/bin/bash
# Start Spotify Lyrics for Tidbyt.
# Runs the lyrics proxy and push loop together.
#
# Usage: ./start.sh
# Stop:  Ctrl+C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Kill background processes on exit
cleanup() {
    echo ""
    echo "Stopping..."
    kill $PROXY_PID 2>/dev/null
    wait $PROXY_PID 2>/dev/null
    exit 0
}
trap cleanup INT TERM

# Start lyrics proxy in background
python3 "$SCRIPT_DIR/lyrics_proxy.py" &
PROXY_PID=$!
sleep 1

# Check proxy started
if ! kill -0 $PROXY_PID 2>/dev/null; then
    echo "Error: lyrics proxy failed to start"
    exit 1
fi

# Push loop handles .env loading, token refresh, and render/push cycles
"$SCRIPT_DIR/push_loop.sh"
