#!/usr/bin/env python3
"""macho-weaken.py — weak-link dead dylib dependencies in a Mach-O, at BOTH levels dyld checks.

Why: mutter 46 cannot be built without X11 (core/frame.c + core/keybindings.c are always-compiled
and use X11 unconditionally; the `x11` decoupling is GNOME 47/48 work). So libmutter/cogl/mtk (and
the libxkbcommon-x11 dep) link X11/xcb libraries and their symbols, even though that code is dead on
iOS (we run Wayland + MetaBackendIOS, never MetaBackendX11). Some of those libs — the xcb *extension*
sublibs libxcb-randr.0 / libxcb-res.0 / libxcb-xkb.1 — do not exist on the iPad, so dyld hard-fails at
load before anything runs.

Making a dependency truly optional on modern arm64 (chained fixups) takes TWO edits, because dyld
binds in two stages:
  1. the LC_LOAD_DYLIB load command -> LC_LOAD_WEAK_DYLIB   (library may be absent)
  2. every imported SYMBOL from that library -> a weak import (symbol may be absent -> bind to 0)
Doing only (1) still crashes: dyld reaches the symbol-bind stage, the lib is gone, and a *strong*
import has nowhere to resolve -> "Symbol not found". So this tool does both:
  - flips matching LC_LOAD_DYLIB commands to LC_LOAD_WEAK_DYLIB (the <name-substr> args), then
  - for EVERY library whose load command is now weak, sets the `weak_import` bit on its entries in
    the LC_DYLD_CHAINED_FIXUPS imports table (the authority dyld actually uses) AND sets N_WEAK_REF
    (n_desc bit 0x0040) on the matching LC_SYMTAB undefined symbols (so `nm -m` shows "weak external").
Weakening an import from a lib that IS present is harmless (it still binds normally); the point is
that imports from ABSENT libs bind to 0, and the dead X11 code never calls them.

All edits are byte-length-preserving (only flag bits change), so offsets/sizes are untouched and
MinimumOSVersion (LC_BUILD_VERSION) is preserved. The code signature IS invalidated — re-sign after
(`codesign -f -s -` on host, or ldid -S in the Procursus container).

Usage:
    macho-weaken.py <mach-o-file> <name-substr> [<name-substr> ...]
Each <name-substr> is matched (literally) against each LC_LOAD_DYLIB install path; a match flips that
command to weak. Then ALL weak-linked libs (the just-flipped ones plus any already weak) have their
imports weakened. Exit status 0 on success (including 0 changes). Prints per-file change counts.
"""
import struct
import sys

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD           # 0x80000018
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_SYMTAB = 0x02
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD        # 0x80000034
# Load commands that contribute a slot to the two-level-namespace library ordinal list, in order.
DYLIB_LOADERS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
                 LC_LOAD_UPWARD_DYLIB, LC_LAZY_LOAD_DYLIB)

N_WEAK_REF = 0x0040
N_TYPE = 0x0E
N_UNDF = 0x00
N_EXT = 0x01

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA


def _cstr(buf, off):
    end = buf.index(b"\x00", off)
    return bytes(buf[off:end])


def weaken_slice(buf, base, targets):
    """Weaken (in place) matching load commands + all imports/symbols from weak libs. One slice."""
    magic = struct.unpack_from("<I", buf, base)[0]
    if magic == MH_MAGIC_64:
        en = "<"
    elif magic == MH_CIGAM_64:
        en = ">"
    else:
        return (0, 0)  # not a 64-bit Mach-O slice we handle

    ncmds = struct.unpack_from(en + "I", buf, base + 16)[0]
    p = base + 32
    dylib_is_weak = []          # 1-based ordinal -> bool (weak after our flip)
    chained = None              # (dataoff, datasize)
    symtab = None               # (symoff, nsyms, stroff, strsize)
    lc_flips = 0

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(en + "II", buf, p)
        if cmd in DYLIB_LOADERS:
            name_off = struct.unpack_from(en + "I", buf, p + 8)[0]
            name = _cstr(buf, p + name_off).decode("utf-8", "replace")
            if cmd == LC_LOAD_DYLIB and any(t in name for t in targets):
                struct.pack_into(en + "I", buf, p, LC_LOAD_WEAK_DYLIB)
                cmd = LC_LOAD_WEAK_DYLIB
                lc_flips += 1
            dylib_is_weak.append(cmd == LC_LOAD_WEAK_DYLIB)
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            chained = struct.unpack_from(en + "II", buf, p + 8)
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from(en + "IIII", buf, p + 8)
        p += cmdsize

    weak_ords = {i + 1 for i, w in enumerate(dylib_is_weak) if w}
    weak_names = set()
    imp_flips = 0

    # --- stage 2a: chained-fixups imports (what dyld binds through) ---
    if chained is not None and weak_ords:
        dataoff = base + chained[0]
        (_ver, _starts, imports_off, symbols_off,
         imports_count, imports_format, _symfmt) = struct.unpack_from(en + "7I", buf, dataoff)
        ibase = dataoff + imports_off
        sbase = dataoff + symbols_off
        for k in range(imports_count):
            if imports_format in (1, 2):      # DYLD_CHAINED_IMPORT / _ADDEND (u32 header)
                off = ibase + k * (4 if imports_format == 1 else 8)
                v = struct.unpack_from(en + "I", buf, off)[0]
                lib = v & 0xFF
                weak_bit = (v >> 8) & 0x1
                name_off = (v >> 9) & 0x7FFFFF
                if lib in weak_ords and not weak_bit:
                    struct.pack_into(en + "I", buf, off, v | (1 << 8))
                    weak_names.add(_cstr(buf, sbase + name_off))
                    imp_flips += 1
            else:                              # DYLD_CHAINED_IMPORT_ADDEND64 (u64 header)
                off = ibase + k * 16
                v = struct.unpack_from(en + "Q", buf, off)[0]
                lib = v & 0xFFFF
                weak_bit = (v >> 16) & 0x1
                name_off = (v >> 32) & 0xFFFFFFFF
                if lib in weak_ords and not weak_bit:
                    struct.pack_into(en + "Q", buf, off, v | (1 << 16))
                    weak_names.add(_cstr(buf, sbase + name_off))
                    imp_flips += 1

    # --- stage 2b: mirror into the symbol table so `nm -m` shows weak external ---
    if symtab is not None and weak_names:
        symoff, nsyms, stroff, _strsize = symtab
        for i in range(nsyms):
            noff = symoff + i * 16
            n_strx, n_type, _n_sect, n_desc = struct.unpack_from(en + "IBBH", buf, noff)
            if (n_type & N_TYPE) == N_UNDF and (n_type & N_EXT):
                nm = _cstr(buf, stroff + n_strx)
                if nm in weak_names and not (n_desc & N_WEAK_REF):
                    struct.pack_into(en + "H", buf, noff + 6, n_desc | N_WEAK_REF)

    return (lc_flips, imp_flips)


def process(path, targets):
    with open(path, "rb") as f:
        buf = bytearray(f.read())
    magic = struct.unpack_from(">I", buf, 0)[0]
    lc = imp = 0
    if magic in (FAT_MAGIC, FAT_CIGAM):
        nfat = struct.unpack_from(">I", buf, 4)[0]
        for i in range(nfat):
            off = struct.unpack_from(">I", buf, 8 + i * 20 + 8)[0]
            a, b = weaken_slice(buf, off, targets)
            lc += a
            imp += b
    else:
        a, b = weaken_slice(buf, 0, targets)
        lc += a
        imp += b
    if lc or imp:
        with open(path, "wb") as f:
            f.write(buf)
    return lc, imp


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    path, targets = argv[1], argv[2:]
    lc, imp = process(path, targets)
    print("%s: %d load command(s) made weak, %d import(s) made weak" % (path, lc, imp))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
