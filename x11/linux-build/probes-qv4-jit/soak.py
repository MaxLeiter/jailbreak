#!/usr/bin/env python3
# soak.py SLOT ROUNDS: open Kickoff, the clock and a few tray popups ROUNDS times (each dismissed by a tap on
# the empty desktop), checking that
# plasmashell and kwin_wayland keep their pids. Landscape 2880x2160 physical layout.
import ctypes, socket, struct, subprocess, sys, time
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
        return float("nan")
    return (ru.user + ru.system) * tb.numer / tb.denom / 1e6
slot, rounds = sys.argv[1], int(sys.argv[2])
TARGETS = [("kickoff", 72, 2096), ("clock", 2600, 2096), ("volume", 2176, 2096), ("tray-arrow", 2432, 2096),
           ("battery", 2272, 2096)]
def pids():
    out = {}
    for l in subprocess.run(["ps", "-Ao", "pid,comm"], capture_output=True, text=True).stdout.splitlines()[1:]:
        pid, comm = l.strip().split(None, 1)
        for name in ("plasmashell", "kwin_wayland"):
            if comm.endswith("/" + name):
                out[name] = int(pid)
    return out
MAGIC = 0x584D5331
def msg(t, x=0, y=0, code=0, state=0): return struct.pack("<IIIIiiii", MAGIC, t, state, 0, x, y, code, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/jb/tmp/iosc-%s-input.sock" % slot)
s.sendall(struct.pack("<IIIIiiii", MAGIC, 1, 1, 0, 0, 0, 0, 0)); s.recv(32)
def tap(x, y):
    s.sendall(msg(0x105, x, y, 9, 1)); time.sleep(0.05); s.sendall(msg(0x105, x, y, 9, 0))
start = pids()
print("start", start, flush=True)
c0 = {k: cpu_ms(v) for k, v in start.items()}
t0 = time.time()
for r in range(rounds):
    for name, x, y in TARGETS:
        tap(x, y); time.sleep(1.5); tap(1000, 800); time.sleep(1.2)  # dismiss by tapping the empty desktop
    now = pids()
    if now != start:
        print("round %d: PIDS CHANGED %s -> %s" % (r, start, now), flush=True)
        sys.exit(1)
    if r % 5 == 4:
        print("round %d ok (%.0f s)" % (r + 1, time.time() - t0), flush=True)
print("soak done: %d rounds, %d popups, pids stable %s; cpu during soak: %s" % (rounds, rounds * len(TARGETS), start,
      ", ".join("%s %.0f ms" % (k, cpu_ms(v) - c0[k]) for k, v in start.items())), flush=True)
