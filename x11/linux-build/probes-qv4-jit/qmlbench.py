#!/usr/bin/env python3
# qmlbench.py SLOT WHAT REPS [TX TY GEOM]
#   WHAT = clock | kickoff | custom. Taps the panel button (physical px), polls a grim region (logical
#   "x,y wxh") until it changes (= popup visible), lets it settle, taps again and polls until the region
#   is back to its baseline (= popup gone). Prints open/close ms and plasmashell CPU ms per phase
#   (proc_pid_rusage, user+sys). Landscape 1440x1080 logical / 2880x2160 physical layout.
import ctypes, os, socket, struct, subprocess, sys, time
slot, what, reps = sys.argv[1], sys.argv[2], int(sys.argv[3])
PRESETS = {
    "clock":   (2600, 2096, "1150,640 260x300"),
    "kickoff": (72, 2096, "40,560 300x400"),
}
if what in PRESETS:
    tx, ty, geom = PRESETS[what]
else:
    tx, ty, geom = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
env = dict(os.environ, XDG_RUNTIME_DIR="/var/jb/tmp/xios-kde-runtime-" + slot, WAYLAND_DISPLAY="wayland-" + slot)

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
pid = max(int(l.split()[0]) for l in subprocess.run(["ps", "-Ao", "pid,comm"], capture_output=True, text=True).stdout.splitlines()
          if l.strip().endswith("/plasmashell"))

ppm = "/var/jb/tmp/qmlbench-%d.ppm" % os.getpid()
def shot():
    subprocess.run(["grim", "-t", "ppm", "-g", geom, ppm], env=env, check=True)
    d = open(ppm, "rb").read()
    body = d[d.index(b"255\n") + 4:]
    return sum(body[::97]) / len(body[::97])
MAGIC = 0x584D5331
def msg(t, x=0, y=0, code=0, state=0): return struct.pack("<IIIIiiii", MAGIC, t, state, 0, x, y, code, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/jb/tmp/iosc-%s-input.sock" % slot)
s.sendall(struct.pack("<IIIIiiii", MAGIC, 1, 1, 0, 0, 0, 0, 0)); s.recv(32)
def tap():
    s.sendall(msg(0x105, tx, ty, 9, 1)); time.sleep(0.05); s.sendall(msg(0x105, tx, ty, 9, 0))
def wait(pred, t0, limit=15):
    while time.time() - t0 < limit:
        v = shot()
        if pred(v):
            return (time.time() - t0) * 1000, v
    return None, v

print("pid %d what %s tap %d,%d geom %s, plasmashell cpu so far %.0f ms" % (pid, what, tx, ty, geom, cpu_ms(pid)), flush=True)
base = shot()
for i in range(reps):
    c0 = cpu_ms(pid); t0 = time.time()
    tap()
    ms, v = wait(lambda v: abs(v - base) > 3, t0)
    time.sleep(1.5)
    c1 = cpu_ms(pid); t1 = time.time()
    tap()
    cms, v2 = wait(lambda v: abs(v - base) <= 1.5, t1)
    time.sleep(1.5)
    c2 = cpu_ms(pid)
    print("rep %d open %s ms  close %s ms  cpu open %.0f ms  cpu close %.0f ms" % (
        i, "%.0f" % ms if ms is not None else "TIMEOUT", "%.0f" % cms if cms is not None else "TIMEOUT",
        c1 - c0, c2 - c1), flush=True)
os.unlink(ppm)
