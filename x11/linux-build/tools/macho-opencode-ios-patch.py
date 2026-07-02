#!/usr/bin/env python3
"""Patch OpenCode's Bun standalone Mach-O for the iOS bring-up probe.

This is intentionally narrow and reproducible:
  * add one LC_LOAD_DYLIB for /var/jb/usr/lib/libopencode-ios-shim.dylib
  * rewrite only the chained-fixups imports supplied by that shim

It does not try to make a macOS Bun runtime into a supported iOS runtime. The
build script runs an on-device smoke test and refuses to package if the patched
binary still fails.
"""

from __future__ import annotations

import argparse
import shutil
import struct
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0x0C
LC_DYLD_CHAINED_FIXUPS = 0x80000034

SHIM_PATH = b"/var/jb/usr/lib/libopencode-ios-shim.dylib\0"
SHIM_SYMBOLS = {
    b"___clear_cache",
    b"_pthread_jit_write_protect_np",
    b"_pthread_jit_write_protect_supported_np",
}


def align8(n: int) -> int:
    return (n + 7) & ~7


def cstr(data: bytes | bytearray, off: int) -> bytes:
    end = data.index(0, off)
    return bytes(data[off:end])


def parse_load_commands(data: bytes | bytearray):
    magic, _cputype, _cpusubtype, _filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a little-endian 64-bit Mach-O: magic=0x{magic:x}")

    off = 32
    dylib_count = 0
    chained_fixups: tuple[int, int] | None = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_LOAD_DYLIB:
            dylib_count += 1
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            chained_fixups = struct.unpack_from("<II", data, off + 8)
        off += cmdsize

    return ncmds, sizeofcmds, dylib_count, chained_fixups


def add_load_dylib(data: bytearray, ncmds: int, sizeofcmds: int) -> tuple[int, int]:
    cmdsize = align8(24 + len(SHIM_PATH))
    load_end = 32 + sizeofcmds
    if any(data[load_end : load_end + cmdsize]):
        raise SystemExit("no zeroed load-command padding available for shim LC_LOAD_DYLIB")

    cmd = bytearray(cmdsize)
    # struct dylib_command { cmd, cmdsize, name.offset, timestamp, current_version, compatibility_version }
    struct.pack_into("<IIIIII", cmd, 0, LC_LOAD_DYLIB, cmdsize, 24, 2, 0, 0)
    cmd[24 : 24 + len(SHIM_PATH)] = SHIM_PATH
    data[load_end : load_end + cmdsize] = cmd
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    return ncmds + 1, sizeofcmds + cmdsize


def patch_chained_imports(data: bytearray, chained_fixups: tuple[int, int], new_ordinal: int) -> list[str]:
    dataoff, _datasize = chained_fixups
    (
        _version,
        _starts_offset,
        imports_offset,
        symbols_offset,
        imports_count,
        imports_format,
        _symbols_format,
    ) = struct.unpack_from("<IIIIIII", data, dataoff)
    if imports_format != 1:
        raise SystemExit(f"unsupported chained imports format {imports_format}; expected DYLD_CHAINED_IMPORT")

    imports_base = dataoff + imports_offset
    symbols_base = dataoff + symbols_offset
    patched: list[str] = []
    for i in range(imports_count):
        pos = imports_base + 4 * i
        raw = struct.unpack_from("<I", data, pos)[0]
        name_offset = (raw >> 9) & 0x7FFFFF
        name = cstr(data, symbols_base + name_offset)
        if name not in SHIM_SYMBOLS:
            continue

        old_ordinal = raw & 0xFF
        if old_ordinal == new_ordinal:
            patched.append(name.decode())
            continue
        if old_ordinal == 0:
            raise SystemExit(f"{name.decode()} is a flat/weak import; refusing ambiguous patch")
        struct.pack_into("<I", data, pos, (raw & ~0xFF) | new_ordinal)
        patched.append(name.decode())

    missing = {s.decode() for s in SHIM_SYMBOLS} - set(patched)
    if missing:
        raise SystemExit(f"missing expected shim imports: {', '.join(sorted(missing))}")
    return patched


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()

    shutil.copyfile(args.input, args.output)
    data = bytearray(args.output.read_bytes())
    ncmds, sizeofcmds, dylib_count, chained_fixups = parse_load_commands(data)
    if chained_fixups is None:
        raise SystemExit("LC_DYLD_CHAINED_FIXUPS not found")

    new_ordinal = dylib_count + 1
    add_load_dylib(data, ncmds, sizeofcmds)
    patched = patch_chained_imports(data, chained_fixups, new_ordinal)
    args.output.write_bytes(data)
    print(f"added {SHIM_PATH[:-1].decode()} as dylib ordinal {new_ordinal}")
    print("patched imports: " + ", ".join(patched))


if __name__ == "__main__":
    main()
