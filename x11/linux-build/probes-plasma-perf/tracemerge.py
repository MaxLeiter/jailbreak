#!/usr/bin/env python3
# tracemerge.py KWIN_LOG IOSC_LOG [LAST_SECONDS]: merge KWIN_IOS_FRAME_TRACE (ftrace) and IOSC_PRESENT_TRACE (ptrace) lines
# by their shared CLOCK_UPTIME_RAW stamps, print relative ms.
import re, sys
ev = []
for path, tag in ((sys.argv[1], "K"), (sys.argv[2], "I")):
    for line in open(path, errors="replace"):
        m = re.match(r"(?:.*?)(ftrace|ptrace) ([\d.]+) (.*)", line.rstrip())
        if m:
            ev.append((float(m.group(2)), tag, m.group(3)))
ev.sort()
last = float(sys.argv[3]) if len(sys.argv) > 3 else 1e9
end = ev[-1][0]
ev = [e for e in ev if e[0] >= end - last * 1000]
t0 = ev[0][0]
for t, tag, text in ev:
    print("%9.1f %s %s" % (t - t0, tag, text))
