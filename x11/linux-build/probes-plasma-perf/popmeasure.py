#!/usr/bin/env python3
# popmeasure.py SLOT WHAT REPS [HOLD_S]: open and close a Plasma popup REPS times and report, per phase,
#   cpu   plasmashell CPU (all threads, proc_pid_rusage) from the tap to the end of the phase
#   main  CPU of plasmashell's main thread in that window
#   busy  wall time from the tap to the end of the last 50 ms window in which the main thread ran at least half
#         the time (polled every 5 ms through PROC_PIDTHREADINFO, no thread suspension). A latency proxy: small
#         per-frame work while a popup sits open does not count.
# WHAT = pclock | pkickoff (portrait 2160x2880) | clock | kickoff (landscape) | X,Y physical px.
# The first rep after a fresh session is the cold open. Taps go through iosc's input socket.
import ctypes, socket, struct, subprocess, sys, time
slot, what, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
hold = float(sys.argv[4]) if len(sys.argv) > 4 else 2.5
PRESETS = {"clock": (2600, 2096), "kickoff": (72, 2096), "pclock": (1888, 2813), "pkickoff": (75, 2813)}
tx, ty = PRESETS[what] if what in PRESETS else map(int, what.split(","))
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class RU(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("a", ctypes.c_uint64 * 8)]
class TI(ctypes.Structure):
    _fields_ = [("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("cpu", ctypes.c_int32), ("policy", ctypes.c_int32),
                ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32), ("sleep", ctypes.c_int32), ("curpri", ctypes.c_int32),
                ("pri", ctypes.c_int32), ("maxpri", ctypes.c_int32), ("name", ctypes.c_char * 64)]
def cpu_ms(pid):
    ru = RU(); libc.proc_pid_rusage(pid, 0, ctypes.byref(ru)); return (ru.user + ru.system) * 125 / 3 / 1e6
def threads(pid):
    buf = (ctypes.c_uint64 * 512)()
    n = libc.proc_pidinfo(pid, 6, ctypes.c_uint64(0), buf, ctypes.sizeof(buf))  # PROC_PIDLISTTHREADS
    return list(buf[: max(0, n) // 8])
def tcpu(pid, h):
    ti = TI()
    if libc.proc_pidinfo(pid, 5, ctypes.c_uint64(h), ctypes.byref(ti), ctypes.sizeof(ti)) <= 0:  # PROC_PIDTHREADINFO
        return None
    return (ti.user + ti.system) / 1e6  # nanoseconds here
pid = max(int(l.split()[0]) for l in subprocess.run(["ps", "-Ao", "pid,comm"], capture_output=True, text=True).stdout.splitlines()
          if l.strip().endswith("/plasmashell"))
main = max(threads(pid), key=lambda h: tcpu(pid, h) or 0)  # the main thread does by far the most work
MAGIC = 0x584D5331
def msg(t, x=0, y=0, code=0, state=0): return struct.pack("<IIIIiiii", MAGIC, t, state, 0, x, y, code, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/jb/tmp/iosc-%s-input.sock" % slot)
s.sendall(struct.pack("<IIIIiiii", MAGIC, 1, 1, 0, 0, 0, 0, 0)); s.recv(32)
def phase(secs):
    c0 = cpu_ms(pid); m0 = tcpu(pid, main); t0 = time.time(); series = [(t0, m0)]
    s.sendall(msg(0x105, tx, ty, 9, 1)); time.sleep(0.05); s.sendall(msg(0x105, tx, ty, 9, 0))
    while time.time() - t0 < secs:
        series.append((time.time(), tcpu(pid, main)))
        time.sleep(0.005)
    last = t0
    j = 0
    for i, (t, m) in enumerate(series):  # windows ending at each sample
        while series[j][0] < t - 0.05:
            j += 1
        if t - series[j][0] >= 0.04 and m - series[j][1] >= 0.5 * (t - series[j][0]) * 1000:
            last = t
    return cpu_ms(pid) - c0, series[-1][1] - m0, (last - t0) * 1000
rows = []
for i in range(reps):
    o = phase(hold); c = phase(2.5)
    rows.append((o, c))
    print("%s rep %d  open: cpu %4.0f main %4.0f busy %4.0f ms | close: cpu %4.0f main %4.0f busy %4.0f ms" % (
        what, i, o[0], o[1], o[2], c[0], c[1], c[2]), flush=True)
