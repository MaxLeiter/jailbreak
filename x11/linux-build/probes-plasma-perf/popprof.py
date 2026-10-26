#!/usr/bin/env python3
# popprof.py SLOT WHAT OUT [INTERVAL_US] [OPEN_HOLD_S]: stack-sample plasmashell (fpsample, all running threads)
# while tapping a panel button to open a popup and tapping again to close it.
# WHAT = clock | kickoff (landscape presets) | pclock | pkickoff (portrait) | X,Y (physical px). INTERVAL_US 0 = no
# sampler (to measure the sampler's own overhead). Writes OUT (fpsample format) plus "E <mach_abs> <event>" lines
# for the taps, and prints plasmashell CPU per phase. Landscape 2880x2160 layout.
import ctypes, os, socket, struct, subprocess, sys, time
slot, what, out = sys.argv[1], sys.argv[2], sys.argv[3]
iv = sys.argv[4] if len(sys.argv) > 4 else "2000"
hold = float(sys.argv[5]) if len(sys.argv) > 5 else 2.5
PRESETS = {"clock": (2600, 2096), "kickoff": (72, 2096), "pclock": (1888, 2813), "pkickoff": (75, 2813)}
tx, ty = PRESETS[what] if what in PRESETS else map(int, what.split(","))
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libc.mach_absolute_time.restype = ctypes.c_uint64
class RU(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("a", ctypes.c_uint64 * 8)]
def cpu_ms(pid):
    ru = RU(); libc.proc_pid_rusage(pid, 0, ctypes.byref(ru)); return (ru.user + ru.system) * 125 / 3 / 1e6
pid = max(int(l.split()[0]) for l in subprocess.run(["ps", "-Ao", "pid,comm"], capture_output=True, text=True).stdout.splitlines()
          if l.strip().endswith("/plasmashell"))
MAGIC = 0x584D5331
def msg(t, x=0, y=0, code=0, state=0): return struct.pack("<IIIIiiii", MAGIC, t, state, 0, x, y, code, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/jb/tmp/iosc-%s-input.sock" % slot)
s.sendall(struct.pack("<IIIIiiii", MAGIC, 1, 1, 0, 0, 0, 0, 0)); s.recv(32)
ev = []
def tap(name):
    ev.append((libc.mach_absolute_time(), name))
    s.sendall(msg(0x105, tx, ty, 9, 1)); time.sleep(0.05); s.sendall(msg(0x105, tx, ty, 9, 0))
total = 0.6 + hold + 2.5
here = os.path.dirname(os.path.abspath(__file__))
p = subprocess.Popen([os.path.join(here, "fpsample"), str(pid), "%.1f" % total, iv, out]) if iv != "0" else None
time.sleep(0.5)
c0 = cpu_ms(pid); tap("open"); time.sleep(hold)
c1 = cpu_ms(pid); tap("close"); time.sleep(2.5)
c2 = cpu_ms(pid)
if p:
    p.wait()
with open(out, "a") as f:
    for t, n in ev:
        f.write("E %d %s\n" % (t, n))
print("pid %d %s: cpu open %.0f ms, close %.0f ms" % (pid, what, c1 - c0, c2 - c1), flush=True)
