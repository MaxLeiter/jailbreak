#!/usr/bin/env python3
# taptrace.py SLOT REPS [TX TY]: open/close the portrait clock popup REPS times without screen capture, printing each
# tap's CLOCK_UPTIME_RAW ms (the clock IOSC_PRESENT_TRACE / KWIN_IOS_FRAME_TRACE stamp), so the frames each tap caused
# can be read out of the traces afterwards (tracedur.py).
import ctypes, socket, struct, sys, time
slot, reps = sys.argv[1], int(sys.argv[2])
tx, ty = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (1888, 2813)
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libc.clock_gettime_nsec_np.restype = ctypes.c_uint64
def up_ms(): return libc.clock_gettime_nsec_np(8) / 1e6   # CLOCK_UPTIME_RAW
MAGIC = 0x584D5331
def msg(t, x=0, y=0, code=0, state=0): return struct.pack("<IIIIiiii", MAGIC, t, state, 0, x, y, code, 0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect("/var/jb/tmp/iosc-%s-input.sock" % slot)
s.sendall(struct.pack("<IIIIiiii", MAGIC, 1, 1, 0, 0, 0, 0, 0)); s.recv(32)
def tap(kind):
    print("tap %s %.3f" % (kind, up_ms()), flush=True)
    s.sendall(msg(0x105, tx, ty, 9, 1)); time.sleep(0.05); s.sendall(msg(0x105, tx, ty, 9, 0))
for i in range(reps):
    tap("open"); time.sleep(2.5)
    tap("close"); time.sleep(2.0)
