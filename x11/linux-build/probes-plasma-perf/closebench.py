#!/usr/bin/env python3
# closebench.py SLOT REPS [TX TY GEOM]: portrait clock popup. Tap open, wait until the watched region (logical
# "x,y wxh") has changed and settled, hold, tap close, poll grim as fast as it goes until the region is back to its
# baseline. Prints open/close ms per rep and, with -v, every close-phase sample (ms, mean) so the slide is visible.
import os, socket, struct, subprocess, sys, time
verbose = "-v" in sys.argv
args = [a for a in sys.argv[1:] if a != "-v"]
slot, reps = args[0], int(args[1])
tx, ty, geom = (int(args[2]), int(args[3]), args[4]) if len(args) > 4 else (1888, 2813, "320,920 700x200")
env = dict(os.environ, XDG_RUNTIME_DIR="/var/jb/tmp/xios-kde-runtime-" + slot, WAYLAND_DISPLAY="wayland-" + slot)
ppm = "/var/jb/tmp/closebench-%d.ppm" % os.getpid()
def shot():
    subprocess.run(["grim", "-t", "ppm", "-g", geom, ppm], env=env, check=True)
    d = open(ppm, "rb").read()
    body = d[d.index(b"255\n") + 4:]
    s = body[::31]
    return sum(s) / len(s)
MAGIC = 0x584D5331
def msg(t, x=0, y=0, code=0, state=0): return struct.pack("<IIIIiiii", MAGIC, t, state, 0, x, y, code, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/jb/tmp/iosc-%s-input.sock" % slot)
s.sendall(struct.pack("<IIIIiiii", MAGIC, 1, 1, 0, 0, 0, 0, 0)); s.recv(32)
def tap():
    s.sendall(msg(0x105, tx, ty, 9, 1)); time.sleep(0.05); s.sendall(msg(0x105, tx, ty, 9, 0))
def poll(pred, t0, limit=15):
    trace = []
    while time.time() - t0 < limit:
        v = shot(); t = (time.time() - t0) * 1000
        trace.append((t, v))
        if pred(v):
            return t, trace
    return None, trace
base = shot()
print("baseline %.2f geom %s" % (base, geom), flush=True)
opens, closes = [], []
for i in range(reps):
    t0 = time.time(); tap()
    o, _ = poll(lambda v: abs(v - base) > 3, t0)
    time.sleep(2.0)
    full = shot()
    t1 = time.time(); mono1 = time.monotonic(); tap()
    c, trace = poll(lambda v: abs(v - base) <= 0.6, t1)
    print("rep %d close-tap mono %.3f open %s ms close %s ms (open level %.2f, %d close samples)" % (
        i, mono1, "%.0f" % o if o else "TIMEOUT", "%.0f" % c if c else "TIMEOUT", full, len(trace)), flush=True)
    if verbose:
        print("   " + " ".join("%.0f:%.1f" % tv for tv in trace), flush=True)
    if o: opens.append(o)
    if c: closes.append(c)
    time.sleep(1.5)
if closes:
    closes.sort(); opens.sort()
    print("open median %.0f ms, close median %.0f ms (min %.0f max %.0f)" % (
        opens[len(opens) // 2], closes[len(closes) // 2], closes[0], closes[-1]), flush=True)
os.unlink(ppm)
