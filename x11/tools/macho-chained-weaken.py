#!/usr/bin/env python3
"""Set the weak_import bit on named imports in a chained-fixups Mach-O.

Usage: macho-chained-weaken.py <macho> <symbol> [<symbol>...]

Modern arm64 Mach-Os bind via LC_DYLD_CHAINED_FIXUPS, whose import table (not
the classic symtab's N_WEAK_REF) carries the weak_import bit dyld consults. A
weak import missing from its two-level-namespace dylib resolves to NULL instead
of aborting the process. Re-sign with ldid afterwards.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_DYLD_CHAINED_FIXUPS = 0x80000034

DYLD_CHAINED_IMPORT = 1
DYLD_CHAINED_IMPORT_ADDEND = 2
DYLD_CHAINED_IMPORT_ADDEND64 = 3


def find_chained_fixups(data):
    ncmds, = struct.unpack_from("<I", data, 16)
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            return dataoff
        off += cmdsize
    return None


def weaken(path, names):
    wanted = set(names)
    with open(path, "r+b") as f:
        data = bytearray(f.read())
        if struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
            sys.exit(f"!! {path}: not a little-endian 64-bit Mach-O")
        base = find_chained_fixups(data)
        if base is None:
            sys.exit(f"!! {path}: no LC_DYLD_CHAINED_FIXUPS")
        (_ver, _starts, imports_off, symbols_off,
         imports_count, imports_format, _sym_format) = struct.unpack_from("<7I", data, base)
        imports = base + imports_off
        symbols = base + symbols_off

        def name_at(name_offset):
            p = symbols + name_offset
            return data[p : data.index(b"\0", p)].decode()

        hits = set()
        for i in range(imports_count):
            if imports_format == DYLD_CHAINED_IMPORT:
                e = imports + i * 4
                v, = struct.unpack_from("<I", data, e)
                name_offset = v >> 9
                if name_at(name_offset) in wanted:
                    struct.pack_into("<I", data, e, v | (1 << 8))
                    hits.add(name_at(name_offset))
            elif imports_format == DYLD_CHAINED_IMPORT_ADDEND:
                e = imports + i * 8
                v, = struct.unpack_from("<I", data, e)
                name_offset = v >> 9
                if name_at(name_offset) in wanted:
                    struct.pack_into("<I", data, e, v | (1 << 8))
                    hits.add(name_at(name_offset))
            elif imports_format == DYLD_CHAINED_IMPORT_ADDEND64:
                e = imports + i * 16
                v, = struct.unpack_from("<Q", data, e)
                name_offset = v >> 32
                if name_at(name_offset) in wanted:
                    struct.pack_into("<Q", data, e, v | (1 << 16))
                    hits.add(name_at(name_offset))
            else:
                sys.exit(f"!! unknown imports_format {imports_format}")
        for n in sorted(hits):
            print(f"   weakened import: {n}")
        missing = wanted - hits
        if missing:
            sys.exit(f"!! not found in chained imports: {sorted(missing)}")
        f.seek(0)
        f.write(data)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    weaken(sys.argv[1], sys.argv[2:])
