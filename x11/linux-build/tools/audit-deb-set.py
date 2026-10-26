#!/usr/bin/env python3
"""Audit a set of debs that will be installed together (a staged lane, a publish batch).

    audit-deb-set.py <deb>... | <dir>

Stdlib only (plus the zstd/xz CLIs for the data tarballs), so it runs on the Mac host and in the
procursus-xbuild container alike. Checks, each of which has bitten a device install:

  DUPLICATE   a non-directory path shipped by two debs of the set with no Replaces between them
              (dpkg: "trying to overwrite ..., which is also in package ...")
  DIRS-ONLY   a deb that holds directories and no file or symlink. dpkg treats every path of such a
              package as shared with whichever package owns the same directories, so it is dropped
              right after it is unpacked ("Noting disappearance of ..., which has been completely
              replaced") and everything that depends on it stays unconfigured. Control-only metas (no
              data entries at all) are fine.
  UNSIGNED    a Mach-O executable/dylib/bundle with no LC_CODE_SIGNATURE (iOS refuses to load it).
              MH_OBJECT files (static-plugin .o) are listed as info only; they are never loaded.
  GTKINTL     a Mach-O that imports _g_libintl_* but does not link libgtkintl, or links libintl.dylib
              while importing them (dyld aborts: the published kf6-i18n 6.3.0+ios1 bug)

Exit status 1 when any of the first four is found.
"""
import io
import os
import re
import struct
import subprocess
import sys
import tarfile
import collections

LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_CODE_SIGNATURE = 0x1D
MH_OBJECT = 1
MH_FVMLIB_OR_DSYM = (3, 10)


def ar_members(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"!<arch>\n", path
    pos = 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode().strip().rstrip("/")
        size = int(data[pos + 48:pos + 58].decode().strip())
        yield name, data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)


def untar(name, blob):
    if name.endswith(".zst"):
        blob = subprocess.run(["zstd", "-dc"], input=blob, capture_output=True, check=True).stdout
    elif name.endswith(".xz"):
        blob = subprocess.run(["xz", "-dc"], input=blob, capture_output=True, check=True).stdout
    elif name.endswith(".gz"):
        import gzip
        blob = gzip.decompress(blob)
    return tarfile.open(fileobj=io.BytesIO(blob))


def macho_slices(blob):
    if len(blob) < 8:
        return
    m = struct.unpack(">I", blob[:4])[0]
    if m == 0xCAFEBABE:
        n = struct.unpack(">I", blob[4:8])[0]
        for i in range(n):
            off, size = struct.unpack(">II", blob[8 + 20 * i + 8:8 + 20 * i + 16])
            yield blob[off:off + size]
    elif struct.unpack("<I", blob[:4])[0] in (0xFEEDFACF, 0xFEEDFACE):
        yield blob


def macho_facts(sl):
    """-> (filetype, signed, dylib names, undefined symbol strings) for a thin little-endian Mach-O."""
    magic = struct.unpack("<I", sl[:4])[0]
    if magic == 0xFEEDFACF:
        hdr = 32
        _, _, _, ftype, ncmds, _, _, _ = struct.unpack("<8I", sl[:32])
        wide = True
    else:
        hdr = 28
        _, _, _, ftype, ncmds, _, _ = struct.unpack("<7I", sl[:28])
        wide = False
    off = hdr
    signed = False
    libs = []
    undef = []
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", sl[off:off + 8])
        if cmd == LC_CODE_SIGNATURE:
            signed = True
        elif cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            noff = struct.unpack("<I", sl[off + 8:off + 12])[0]
            libs.append(sl[off + noff:off + size].split(b"\0")[0].decode(errors="replace"))
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack("<4I", sl[off + 8:off + 24])
            esz = 16 if wide else 12
            strtab = sl[stroff:stroff + strsize]
            for i in range(nsyms):
                e = sl[symoff + i * esz:symoff + (i + 1) * esz]
                strx, ntype = struct.unpack("<IB", e[:5])
                if (ntype & 0x0E) == 0 and (ntype & 0x01):  # N_UNDF | N_EXT
                    undef.append(strtab[strx:strtab.index(b"\0", strx)])
        off += size
    return ftype, signed, libs, undef


def field(ctl, key):
    m = re.search(r"^%s:\s*(.*(?:\n[ \t].*)*)" % key, ctl, re.M)
    return m.group(1).replace("\n", " ") if m else ""


def main():
    args = sys.argv[1:]
    debs = []
    for a in args:
        if os.path.isdir(a):
            debs += sorted(os.path.join(a, n) for n in os.listdir(a) if n.endswith(".deb"))
        else:
            debs.append(a)
    if not debs:
        sys.exit(__doc__)

    owners = collections.defaultdict(list)  # path -> [pkg]
    replaces = {}
    versions = {}
    findings = collections.defaultdict(list)
    info_objects = []
    macho_count = 0

    for deb in debs:
        ctl = None
        data = None
        for name, blob in ar_members(deb):
            if name.startswith("control.tar"):
                ctl = untar(name, blob).extractfile("./control").read().decode()
            elif name.startswith("data.tar"):
                data = untar(name, blob)
        pkg = field(ctl, "Package")
        replaces[pkg] = field(ctl, "Replaces")
        versions[pkg] = field(ctl, "Version")
        ndirs = nfiles = 0
        for ti in data.getmembers():
            p = "/" + ("" if ti.name in (".", "./") else ti.name[2:] if ti.name.startswith("./") else ti.name.lstrip("/")).rstrip("/")
            if ti.isdir():
                if p != "/":
                    ndirs += 1
                continue
            nfiles += 1
            owners[p].append(pkg)
            if ti.isreg() and ti.size >= 8:
                blob = data.extractfile(ti).read()
                for sl in macho_slices(blob):
                    macho_count += 1
                    ftype, signed, libs, undef = macho_facts(sl)
                    if ftype == MH_OBJECT:
                        info_objects.append((pkg, p))
                    elif not signed:
                        findings["UNSIGNED"].append("%s: %s" % (pkg, p))
                    imports_intl = any(s.startswith(b"_g_libintl_") for s in undef)
                    if imports_intl and not any("libgtkintl" in l for l in libs):
                        findings["GTKINTL"].append("%s: %s imports _g_libintl_* but does not link libgtkintl" % (pkg, p))
                    if imports_intl and any(re.search(r"libintl[.0-9]*\.dylib", l) for l in libs):
                        findings["GTKINTL"].append("%s: %s links libintl while importing _g_libintl_*" % (pkg, p))
        if ndirs and not nfiles:
            findings["DIRS-ONLY"].append("%s %s" % (pkg, versions[pkg]))

    for path, pk in sorted(owners.items()):
        if len(pk) < 2:
            continue
        bad = True
        for a in pk:
            others = [b for b in pk if b != a]
            if all(re.search(r"(^|[ ,])%s( |\(|,|$)" % re.escape(b), replaces.get(a, "")) for b in others):
                bad = False
        if bad:
            findings["DUPLICATE"].append("%s : %s" % (path, ", ".join(pk)))

    print("debs: %d   files: %d   Mach-O slices: %d   MH_OBJECT (info): %d"
          % (len(debs), len(owners), macho_count, len(info_objects)))
    for k in ("DUPLICATE", "DIRS-ONLY", "UNSIGNED", "GTKINTL"):
        v = findings.get(k, [])
        print("%-10s %d" % (k, len(v)))
        for line in v:
            print("   " + line)
    if info_objects:
        print("info: static-plugin object files (never loaded):")
        for pkg, p in info_objects:
            print("   %s: %s" % (pkg, p))
    sys.exit(1 if findings else 0)


if __name__ == "__main__":
    main()
