"""
Local lyrics cache proxy for spotify_lyrics.star.

Pixlet has a 5-second HTTP timeout, and LRCLIB is often slower than that.
This proxy forwards requests to LRCLIB with a 30-second timeout and caches
the results in memory.

Usage: python3 lyrics_proxy.py  (start.sh runs it for you)
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import json
import urllib.request
import sys

cache = {}

class LyricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path not in ("/api/get", "/api/search"):
            self.send_response(404)
            self.end_headers()
            return

        params = parse_qs(parsed.query)
        cache_key = self.path

        if cache_key in cache:
            print(f"  Cache HIT: {cache_key[:80]}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(cache[cache_key])
            return

        url = "https://lrclib.net" + self.path
        print(f"  Fetching: {url[:80]}...")
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "SpotifyLyricsTidbyt/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
                cache[cache_key] = data
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data)
                print("  Cached OK")
        except Exception as e:
            print(f"  Error: {e}")
            self.send_response(502)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # suppress default logging

if __name__ == "__main__":
    port = 5555
    server = HTTPServer(("127.0.0.1", port), LyricsHandler)
    print(f"Lyrics proxy running on http://127.0.0.1:{port}")
    print("Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped")
