#!/bin/sh
# abrun.sh LABEL (copy this directory to /var/jb/tmp on the iPad first): one measurement pass on a fresh KDE session (slot kde-0b85): startup CPU, cold + warm Kickoff,
# clock popup, a 3-round popup sequence, and the plasmashell JIT chunk census.
cd /var/jb/tmp
echo "=== $1 $(dpkg-query -W -f='${Version}' qt6-declarative) $(date +%H:%M:%S)"
python3 kderestart.py kde-0b85 | tail -1
sleep 60
P=$(ps -Ao pid,comm | grep "/plasmashell\$" | head -1 | awk '{print $1}')
python3 - "$P" <<'EOF'
import ctypes, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class RU(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("a", ctypes.c_uint64 * 8)]
class TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = TB(); libc.mach_timebase_info(ctypes.byref(tb)); ru = RU()
libc.proc_pid_rusage(int(sys.argv[1]), 0, ctypes.byref(ru))
print("plasmashell CPU, start + 60 s idle: %.0f ms" % ((ru.user + ru.system) * tb.numer / tb.denom / 1e6))
EOF
python3 cpuall.py 3 | head -2
python3 qmlbench.py kde-0b85 kickoff 3
python3 qmlbench.py kde-0b85 clock 4
python3 soak.py kde-0b85 3 | tail -1
python3 vmrx.py "$P"
