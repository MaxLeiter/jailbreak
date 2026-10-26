#!/usr/bin/env python3
# tracedur.py TAPS IOSC_LOG: for each tap printed by taptrace.py, the KWin frames that followed it in iosc's present
# trace: first and last commit of the burst (a burst ends at the first gap > 120 ms) and the last frame's
# presentation feedback, i.e. when the final animation frame reached the panel.
import re, sys
taps = [(l.split()[1], float(l.split()[2])) for l in open(sys.argv[1]) if l.startswith("tap ")]
commits, fbs = [], []
for line in open(sys.argv[2], errors="replace"):
    m = re.match(r"ptrace ([\d.]+) (\S+) ?(.*)", line)
    if not m:
        continue
    t, kind, rest = float(m.group(1)), m.group(2), m.group(3)
    if kind == "commit" and "feedbacks=1" in rest:
        commits.append(t)
    elif kind == "feedback-presented":
        fbs.append(t)
res = {}
for i, (kind, t0) in enumerate(taps):
    t_end = taps[i + 1][1] if i + 1 < len(taps) else 1e18
    cs = [c for c in commits if t0 < c < t_end]
    if not cs:
        print("%-5s %.0f: no frames" % (kind, t0)); continue
    burst = [cs[0]]
    for c in cs[1:]:
        if c - burst[-1] > 120: break
        burst.append(c)
    last_fb = min([f for f in fbs if f >= burst[-1]] or [burst[-1]])
    d = last_fb - t0
    res.setdefault(kind, []).append(d)
    print("%-5s first frame +%4.0f ms, %3d frames, last frame shown +%5.0f ms (%.1f fps)" % (
        kind, burst[0] - t0, len(burst), d, (len(burst) - 1) * 1000 / max(1, burst[-1] - burst[0])))
for k, v in res.items():
    v.sort()
    print("%s: median %.0f ms (min %.0f, max %.0f, n=%d)" % (k, v[len(v) // 2], v[0], v[-1], len(v)))
