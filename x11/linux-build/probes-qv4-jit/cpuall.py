#!/usr/bin/env python3
# cpuall.py SECS: top-like CPU ms per process over SECS (proc_pid_rusage user+sys).
import ctypes, subprocess, sys, time
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class RU(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64),
                ("a", ctypes.c_uint64 * 8)]
class TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = TB(); libc.mach_timebase_info(ctypes.byref(tb))
def cpu_ms(pid):
    ru = RU()
    if libc.proc_pid_rusage(pid, 0, ctypes.byref(ru)) != 0:
        return None
    return (ru.user + ru.system) * tb.numer / tb.denom / 1e6
procs = {}
for l in subprocess.run(["ps", "-Ao", "pid,comm"], capture_output=True, text=True).stdout.splitlines()[1:]:
    pid, comm = l.strip().split(None, 1)
    procs[int(pid)] = comm
a = {p: cpu_ms(p) for p in procs}
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5
time.sleep(secs)
rows = []
for p, c0 in a.items():
    c1 = cpu_ms(p)
    if c0 is not None and c1 is not None and c1 - c0 > 1:
        rows.append((c1 - c0, p, procs[p]))
for d, p, c in sorted(rows, reverse=True)[:15]:
    print("%8.0f ms %6.1f%% %6d %s" % (d, d / secs / 10, p, c[-70:]))
