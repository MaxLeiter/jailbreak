#!/usr/bin/env python3
# vmrx.py PID [-v]: count QV4 JIT code in PID. QV4 maps its executable chunks with the Darwin VM tag
# VM_TAG_FOR_EXECUTABLEALLOCATOR_MEMORY (64, masm/wtf/VMTags.h), so tag-64 regions are JIT chunks; r-x ones
# hold linked code. An interpreter-only process has none. (Protection alone does not tell: under Dopamine
# mapped images also report max protection rwx, and proc_regionfilename returns a path even for anon memory.)
import ctypes, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class RI(ctypes.Structure):
    _fields_ = [("prot", ctypes.c_uint32), ("maxprot", ctypes.c_uint32), ("inherit", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("offset", ctypes.c_uint64), ("behavior", ctypes.c_uint32),
                ("wired", ctypes.c_uint32), ("tag", ctypes.c_uint32), ("resident", ctypes.c_uint32),
                ("shared_now_private", ctypes.c_uint32), ("swapped", ctypes.c_uint32), ("dirtied", ctypes.c_uint32),
                ("refcnt", ctypes.c_uint32), ("shadow", ctypes.c_uint32), ("share_mode", ctypes.c_uint32),
                ("priv_res", ctypes.c_uint32), ("shared_res", ctypes.c_uint32), ("obj_id", ctypes.c_uint32),
                ("depth", ctypes.c_uint32), ("addr", ctypes.c_uint64), ("size", ctypes.c_uint64)]
pid = int(sys.argv[1]); verbose = "-v" in sys.argv
addr = 0; regions = 0; byprot = {}
while True:
    ri = RI()
    if libc.proc_pidinfo(pid, 7, ctypes.c_uint64(addr), ctypes.byref(ri), ctypes.sizeof(ri)) <= 0:
        break
    regions += 1
    if ri.tag == 64:
        c, kb = byprot.get(ri.prot, (0, 0)); byprot[ri.prot] = (c + 1, kb + ri.size // 1024)
        if verbose:
            print("jit prot %d %#x-%#x %5d KiB" % (ri.prot, ri.addr, ri.addr + ri.size, ri.size // 1024))
    addr = ri.addr + ri.size
names = {5: "r-x", 3: "rw-", 1: "r--", 0: "---"}
print("pid %d: %d regions; JIT chunks (VM tag 64): %s" % (pid, regions,
      ", ".join("%s %d regions %d KiB" % (names.get(p, p), c, kb) for p, (c, kb) in sorted(byprot.items())) or "none"))
