#!/bin/sh
# abpass.sh LABEL [SLOT] (on the iPad, from the directory holding popmeasure.py): one measurement pass on a session
# that was just (re)started and is presented by Xios: refuse if iosc has no display clock, wait for plasmashell to go
# idle, then cold + 2 warm clock popups and cold + 2 warm Kickoff popups (portrait presets), plus startup CPU.
SLOT=${2:-kde-0b85}
cd "$(dirname "$0")"
st=$(head -1 /var/jb/tmp/xios-status.d/iosc-$SLOT.status)
case "$st" in *vblank*) ;; *) echo "NOT PRESENTING: $st"; exit 1;; esac
echo "=== $1 $(date +%H:%M:%S) $st"
sleep 45
python3 - <<'PY'
import ctypes, subprocess
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class RU(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("a", ctypes.c_uint64 * 8)]
for l in subprocess.run(["ps", "-Ao", "pid,etime,comm"], capture_output=True, text=True).stdout.splitlines()[1:]:
    pid, et, comm = l.split(None, 2)
    if comm.endswith("/plasmashell"):
        ru = RU(); libc.proc_pid_rusage(int(pid), 0, ctypes.byref(ru))
        print("plasmashell pid %s up %s, CPU so far %.0f ms" % (pid, et, (ru.user + ru.system) * 125 / 3 / 1e6))
PY
python3 /var/jb/tmp/cpuall.py 3 | head -3
python3 popmeasure.py $SLOT pclock 3
python3 popmeasure.py $SLOT pkickoff 3
