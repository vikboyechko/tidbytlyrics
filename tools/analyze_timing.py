"""Analyze /tmp/lyrics_timing.log produced by push_loop.sh.

Each entry: <push_done_ms> SHOWING|<progress_ms>|<sample_ms>|<lead_ms>|<line_ts_ms>|<text>

For each line flip (first push showing a new LRC line), measures when the push
completed vs when it was meant to:
  sung_wall   = sample_ms + (line_ts - progress_ms)   [when the line is sung]
  target      = sung_wall - lead_ms                   [scheduled push-complete]
  error       = push_done - target                    [+ = late, - = early]

Device lag and audio lag are folded into DISPLAY_LEAD_MS, so this measures only
how precisely the loop hits its target. Tune DISPLAY_LEAD_MS by ear; tune the
scheduler with this.

Usage: python3 tools/analyze_timing.py [logfile]
"""

import statistics
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lyrics_timing.log"

entries = []
for line in open(path):
    wall, _, rest = line.partition(" SHOWING|")
    parts = rest.rstrip("\n").split("|", 4)
    if len(parts) != 5:
        continue
    try:
        nums = [int(float(wall))] + [int(p) for p in parts[:4]]
    except ValueError:
        continue  # malformed entry
    entries.append((*nums, parts[4]))

errors = []
prev_ts = None
for push_done, progress, sample, lead, line_ts, text in entries:
    if line_ts < 0:
        prev_ts = None
        continue
    if prev_ts is not None and line_ts != prev_ts:  # a flip
        target = sample + (line_ts - progress) - lead
        err = (push_done - target) / 1000
        errors.append(err)
        print(f"  {err:+.2f}s  {text[:50]}")
    prev_ts = line_ts

if not errors:
    print("No line flips found in log (need a playing track with synced lyrics)")
    sys.exit(1)

print(f"\n{len(errors)} flips at DISPLAY_LEAD_MS={entries[-1][3]}")
print(f"median error {statistics.median(errors):+.2f}s, "
      f"mean {statistics.mean(errors):+.2f}s, "
      f"range [{min(errors):+.2f}, {max(errors):+.2f}]")
within = sum(1 for e in errors if abs(e) <= 0.25)
print(f"within ±0.25s: {within}/{len(errors)}")
