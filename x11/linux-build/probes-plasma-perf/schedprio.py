#!/usr/bin/env python3
# schedprio.py PID...: base and current scheduling priority of each thread (PROC_PIDTHREADINFO), plus the process's
# darwin-background state (PROC_PIDTASKINFO doesn't carry it; proc_pidinfo PROC_PIDT_BSDINFO's pbi_flags does: PROC_FLAG_DARWINBG 0x8000, PROC_FLAG_EXT_DARWINBG 0x10000).
import ctypes, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class TI(ctypes.Structure):
    _fields_ = [("user", ctypes.c_uint64), ("system", ctypes.c_uint64), ("cpu", ctypes.c_int32), ("policy", ctypes.c_int32),
                ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32), ("sleep", ctypes.c_int32), ("curpri", ctypes.c_int32),
                ("pri", ctypes.c_int32), ("maxpri", ctypes.c_int32), ("name", ctypes.c_char * 64)]
class BSD(ctypes.Structure):
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32), ("pid", ctypes.c_uint32),
                ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
                ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32), ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32),
                ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32), ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
                ("pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32), ("e_tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
                ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
for a in sys.argv[1:]:
    pid = int(a)
    b = BSD()
    libc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(b), ctypes.sizeof(b))  # PROC_PIDTBSDINFO
    buf = (ctypes.c_uint64 * 256)()
    n = libc.proc_pidinfo(pid, 6, ctypes.c_uint64(0), buf, ctypes.sizeof(buf))
    out = []
    for h in list(buf[: max(0, n) // 8])[:6]:
        ti = TI()
        if libc.proc_pidinfo(pid, 5, ctypes.c_uint64(h), ctypes.byref(ti), ctypes.sizeof(ti)) > 0:
            out.append("%s:%d/%d" % (ti.name.decode(errors="replace")[:14] or "-", ti.pri, ti.curpri))
    print("%6d %-14s darwinbg=%d ext_darwinbg=%d nice=%d  %s" % (pid, b.comm.decode(errors="replace"),
          bool(b.flags & 0x8000), bool(b.flags & 0x10000), b.nice, " ".join(out)))
