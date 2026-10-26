#!/usr/bin/env python3
# ptsum.py IOSC_LOG [FROM_MS TO_MS]: summarise IOSC_PRESENT_TRACE lines: per KWin frame (a commit of a surface that
# carries presentation feedback), commit -> feedback latency, frames in flight, gaps between frames.
import re, sys
ev = []
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"ptrace ([\d.]+) (\S+) ?(.*)", line)
    if m:
        ev.append((float(m.group(1)), m.group(2), m.group(3)))
lo = float(sys.argv[2]) if len(sys.argv) > 2 else 0
hi = float(sys.argv[3]) if len(sys.argv) > 3 else 1e18
ev = [e for e in ev if lo <= e[0] <= hi]
pending = []   # commit times awaiting feedback
lat, gaps, inflight, waits, timeouts = [], [], [], [], 0
last_commit = None
for t, kind, rest in ev:
    if kind == "commit" and "feedbacks=1" in rest:
        pending.append(t)
        inflight.append(len(pending))
        if last_commit is not None:
            gaps.append(t - last_commit)
        last_commit = t
    elif kind == "feedback-presented":
        for c in pending:
            lat.append(t - c)
        pending = []
    elif kind == "present-ack":
        m = re.search(r"waited=(\d+)ms", rest)
        if m: waits.append(int(m.group(1)))
        if "TIMEOUT" in rest: timeouts += 1
def st(name, xs):
    if not xs: print(name, "none"); return
    xs = sorted(xs)
    print("%-28s n=%4d  median %6.1f  p10 %6.1f  p90 %6.1f  max %6.1f" % (name, len(xs), xs[len(xs)//2], xs[len(xs)//10], xs[len(xs)*9//10], xs[-1]))
st("commit->feedback ms", lat)
st("gap between commits ms", gaps)
st("frames in flight at commit", inflight)
st("present-ack wait ms", waits)
print("ack timeouts", timeouts)
print("repaints", sum(1 for e in ev if e[1] == "repaint-start"), "commits w/ feedback", sum(1 for e in ev if e[1] == "commit" and "feedbacks=1" in e[2]),
      "present-wait replaced", sum(1 for e in ev if e[1] == "present-wait" and "replacing 0)" not in e[2]))
