#!/usr/bin/env python3
"""Re-DER-sign the X11/Wayland graphics packages in a repo/debs directory.

This is the publish-time safety net invoked by ``finalize_x11_graphics_debs`` in
``bin/publish-repo.sh`` / ``bin/publish-staging.sh``. The per-package build
recipes already ``$(call SIGN,<pkg>,<ent>)`` their executables, but a .deb can be
rebuilt, repacked, or copied through tooling that drops the code signature. iOS
15+/16 AMFI rejects the IOKit/IOSurface/task_for_pid privileges these binaries
need unless the entitlements are carried as a *DER* signature, so before anything
goes live we walk every .deb and guarantee the DER blob is present and correct.

A binary is a "graphics binary" iff its current entitlements carry a GPU/IOSurface
IOKit user-client marker (AGXDeviceUserClient / IOGPUDeviceUserClient /
IOSurface*). Each such binary is re-signed with *its own current entitlements*,
extracted with ``ldid -e`` and re-applied with ``ldid -S`` so the DER blob is
regenerated. Its privileges are NEVER changed: the packages use per-binary
entitlement sets that differ in detail (e.g. Xios carries
``com.apple.private.security.no-container`` and only the IOSurface user-clients,
which iosc-gl-ent.xml deliberately omits), so imposing a single generic ent file
would silently add or drop entitlements. Preserving each binary's own set is the
only safe re-sign. --gpu-ent / --gl-ent are the reference marker sets (and satisfy
the caller's contract); they are not blindly stamped onto binaries.

A .deb with no GPU-marked binary is not a graphics package and is skipped. A
graphics binary that carries NO entitlements at all is a build bug (its recipe
SIGN step did not run) and is a hard error rather than a guess. Because the
extract-and-re-apply round-trip is deterministic, a correctly built .deb is left
byte-for-byte unchanged, so the step is safe to run on every publish (no churn).

The publish host is macOS, which has no dpkg-deb, so .debs are unpacked and
repacked with ar + tar (the same host tools xmkdeb falls back to). Ownership is
forced back to root:root on repack.

Usage:
    resign-graphics-packages.py <debs-dir> \
        --ldid /opt/homebrew/bin/ldid \
        --gpu-ent .../iosc-gpu-client-ent.xml \
        --gl-ent  .../iosc-gl-ent.xml \
        [--dry-run] [--verbose]
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile

# Mach-O magics (thin + fat, both byte orders). A file is treated as a signable
# binary iff its first 4 bytes are one of these.
MACHO_MAGICS = {
    0xFEEDFACE, 0xFEEDFACF,          # thin 32/64, host order
    0xCEFAEDFE, 0xCFFAEDFE,          # thin 32/64, swapped
    0xCAFEBABE, 0xBEBAFECA,          # fat, big/little
    0xCAFEBABF, 0xBFBAFECA,          # fat64
}

# A binary is only a graphics binary if it carries one of the GPU/IOSurface
# IOKit user-client markers. This is the gate that keeps the pass off ordinary
# Procursus daemons: those are platformized with com.apple.private.* +
# platform-application but hold no GPU markers, so they must never be reclassified
# and re-signed with a graphics entitlement set (which would strip their real
# entitlements). Both iosc-gpu-client-ent.xml and iosc-gl-ent.xml carry these.
GPU_MARKERS = ("AGXDeviceUserClient", "IOGPUDeviceUserClient",
               "IOSurfaceRootUserClient", "IOSurfaceAcceleratorClient",
               "IOSurfaceSendRight")

# Among graphics binaries, a compositor additionally holds the platform / task
# port privileges (drives ANGLE/Metal, imports client IOSurfaces); a plain GPU
# client does not. These distinguish iosc-gl-ent.xml from iosc-gpu-client-ent.xml.
COMPOSITOR_MARKERS = ("platform-application", "task_for_pid-allow",
                      "com.apple.system-task-ports")

# (compression suffix -> (decompress argv, compress argv)). Whatever a member was
# compressed with, it is repacked with the same codec.
COMPRESSORS = {
    ".zst": (["zstd", "-d", "-q"], ["zstd", "-q", "-19", "-T0"]),
    ".xz":  (["xz", "-d", "-q"], ["xz", "-q", "-6"]),
    ".lzma": (["xz", "-d", "-q", "--format=lzma"], ["xz", "-q", "-6", "--format=lzma"]),
    ".gz":  (["gzip", "-d"], ["gzip", "-9", "-n"]),
    ".bz2": (["bzip2", "-d"], ["bzip2", "-9"]),
    "":     (None, None),  # uncompressed data.tar
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def is_macho(path: str) -> bool:
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as fh:
            head = fh.read(4)
    except OSError:
        return False
    if len(head) < 4:
        return False
    return struct.unpack(">I", head)[0] in MACHO_MAGICS


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entitlements(ldid: str, path: str) -> str:
    try:
        return subprocess.run([ldid, "-e", path], capture_output=True,
                              text=True).stdout
    except OSError as exc:
        raise SystemExit(f"ERROR: cannot run ldid ({ldid}): {exc}")


def tier(ents: str) -> str | None:
    """Return 'gl' / 'gpu' (a label for logging only) or None if not a graphics
    binary. None (no GPU markers) means the binary is left untouched. The label
    does not select an entitlement file: binaries are re-signed with their own
    entitlements, not with --gl-ent / --gpu-ent.
    """
    if not any(m in ents for m in GPU_MARKERS):
        return None
    return "gl" if any(m in ents for m in COMPOSITOR_MARKERS) else "gpu"


def run(argv, **kw):
    return subprocess.run(argv, check=True, **kw)


# ---- ar archive (.deb container) ------------------------------------------
# A .deb is an ar archive of debian-binary, control.tar.*, data.tar.*. The
# macOS ar CLI mishandles dpkg's GNU-format member names (trailing '/'), so the
# reader/writer are done here. .deb member names are always short (<16), so the
# GNU long-name table is never present and can be ignored.
AR_MAGIC = b"!<arch>\n"


def ar_read(path: str) -> list[tuple[str, bytes]]:
    """Return [(member_name, data), ...] in archive order."""
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:8] != AR_MAGIC:
        raise SystemExit(f"ERROR: not an ar archive: {path}")
    members, off = [], 8
    while off + 60 <= len(blob):
        hdr = blob[off:off + 60]
        if hdr[58:60] != b"\x60\n":
            raise SystemExit(f"ERROR: corrupt ar header in {path}")
        name = hdr[0:16].decode().rstrip()
        if name.endswith("/"):
            name = name[:-1]
        size = int(hdr[48:58].decode().strip())
        start = off + 60
        members.append((name, blob[start:start + size]))
        off = start + size + (size & 1)  # members are 2-byte aligned
    return members


def ar_write(path: str, members: list[tuple[str, bytes]]) -> None:
    """Write members as an ar archive. Names are space-padded without the GNU
    trailing slash: dpkg/apt/make-repo all strip it, and slashless names are also
    matched by BSD ar (macOS), so every consumer reads the output."""
    for name, _ in members:
        if len(name) > 16:
            raise SystemExit(f"ERROR: ar member name too long: {name}")
    with open(path, "wb") as fh:
        fh.write(AR_MAGIC)
        for name, data in members:
            fh.write(name.ljust(16).encode())          # name
            fh.write(b"0".ljust(12))                    # mtime (reproducible)
            fh.write(b"0".ljust(6))                     # uid
            fh.write(b"0".ljust(6))                     # gid
            fh.write(b"100644".ljust(8))                # mode
            fh.write(str(len(data)).ljust(10).encode()) # size
            fh.write(b"\x60\n")
            fh.write(data)
            if len(data) & 1:
                fh.write(b"\n")


class DebResigner:
    def __init__(self, args):
        self.ldid = args.ldid
        self.gpu_ent = args.gpu_ent
        self.gl_ent = args.gl_ent
        self.dry_run = args.dry_run
        self.verbose = args.verbose
        self.changed_debs = 0
        self.signed_bins = 0

    def resign_preserving(self, path: str) -> None:
        """Re-DER-sign a graphics binary with its own current entitlements."""
        cur = entitlements(self.ldid, path)
        if "<key>" not in cur:
            raise SystemExit(
                f"ERROR: graphics binary carries no entitlements (unsigned?): {path}\n"
                f"       rebuild its package so the recipe SIGN step runs; refusing "
                f"to guess an entitlement set.")
        fd, plist = tempfile.mkstemp(suffix=".entitlements.xml")
        try:
            with os.fdopen(fd, "w") as fh:
                fh.write(cur)
            run([self.ldid, f"-S{plist}", path])
        finally:
            os.unlink(plist)
        # Verify the markers survived (the check the inline `ldid -S` sites
        # lacked; mirrors xsign in lib/xlib.sh).
        if not any(m in entitlements(self.ldid, path) for m in GPU_MARKERS):
            raise SystemExit(
                f"ERROR: {path} lost its GPU entitlement markers after re-signing")

    def process_deb(self, deb: str) -> None:
        work = tempfile.mkdtemp(prefix="resign-deb-")
        try:
            self._process_deb(deb, work)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def _process_deb(self, deb: str, work: str) -> None:
        members = ar_read(deb)
        data_idx = next((i for i, (n, _) in enumerate(members)
                         if n.startswith("data.tar")), None)
        if data_idx is None:
            raise SystemExit(f"ERROR: {deb} has no data.tar member")
        data_name, data_bytes = members[data_idx]
        suffix = data_name[len("data.tar"):]
        if suffix not in COMPRESSORS:
            raise SystemExit(f"ERROR: unknown data compression: {data_name}")
        decomp, comp = COMPRESSORS[suffix]

        comp_path = os.path.join(work, data_name)
        with open(comp_path, "wb") as fh:
            fh.write(data_bytes)
        tar_path = os.path.join(work, "data.tar")
        if decomp:
            with open(tar_path, "wb") as out:
                run(decomp + ["-c", comp_path], stdout=out)
        else:
            tar_path = comp_path

        root = os.path.join(work, "root")
        os.mkdir(root)
        run(["tar", "-xpf", tar_path, "-C", root])

        dirty = False
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                fp = os.path.join(dirpath, fn)
                if not is_macho(fp):
                    continue
                kind = tier(entitlements(self.ldid, fp))
                if kind is None:
                    continue
                rel = os.path.relpath(fp, root)
                before = sha256(fp)
                if self.dry_run:
                    log(f"    would re-sign [{kind}] {rel}")
                    dirty = True
                    self.signed_bins += 1
                    continue
                self.resign_preserving(fp)
                if sha256(fp) != before:
                    dirty = True
                    self.signed_bins += 1
                    if self.verbose:
                        log(f"    re-signed [{kind}] {rel}")
                elif self.verbose:
                    log(f"    already-signed [{kind}] {rel}")

        if not dirty:
            if self.verbose:
                log(f"  ok (unchanged): {os.path.basename(deb)}")
            return

        self.changed_debs += 1
        if self.dry_run:
            log(f"  would repack: {os.path.basename(deb)}")
            return

        # Repack data.tar with root:root ownership, same codec, then swap only
        # the data member back into the .deb (member order is preserved).
        # control.tar (and its md5sums) is left as-is: on a correctly built repo
        # re-signing is a no-op and this path never runs, so it only fires to
        # repair an already-degraded signature, where a correct binary with stale
        # md5sums beats a broken one (dpkg does not verify md5sums at install).
        new_tar = os.path.join(work, "data.new.tar")
        run(["tar", "--format", "gnutar",
             "--uid", "0", "--gid", "0", "--uname", "root", "--gname", "root",
             "-cf", new_tar, "-C", root, "."])
        if comp:
            new_comp = os.path.join(work, "data.new" + suffix)
            with open(new_comp, "wb") as out:
                run(comp + ["-c", new_tar], stdout=out)
            with open(new_comp, "rb") as fh:
                members[data_idx] = (data_name, fh.read())
        else:
            with open(new_tar, "rb") as fh:
                members[data_idx] = (data_name, fh.read())

        tmp_deb = deb + ".resign.tmp"
        ar_write(tmp_deb, members)
        os.replace(tmp_deb, deb)
        log(f"  repacked: {os.path.basename(deb)}")

    def run_dir(self, debs_dir: str) -> int:
        debs = sorted(f for f in os.listdir(debs_dir) if f.endswith(".deb"))
        if not debs:
            log(f"resign-graphics-packages: no .deb files in {debs_dir}")
            return 0
        for name in debs:
            self.process_deb(os.path.join(debs_dir, name))
        verb = "would re-sign" if self.dry_run else "re-signed"
        log(f"resign-graphics-packages: {verb} {self.signed_bins} binaries across "
            f"{self.changed_debs} package(s) ({len(debs)} scanned)")
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("debs_dir", help="directory of .deb files to re-sign in place")
    ap.add_argument("--ldid", default="ldid", help="ldid binary (default: ldid on PATH)")
    ap.add_argument("--gpu-ent", required=True,
                    help="reference GPU-client entitlements (contract/reference; "
                         "binaries are re-signed with their own entitlements)")
    ap.add_argument("--gl-ent", required=True,
                    help="reference compositor entitlements (contract/reference)")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would change without modifying any .deb")
    ap.add_argument("--verbose", action="store_true", help="log every binary examined")
    args = ap.parse_args()

    if not os.path.isdir(args.debs_dir):
        raise SystemExit(f"ERROR: not a directory: {args.debs_dir}")
    for ent in (args.gpu_ent, args.gl_ent):
        if not os.path.isfile(ent):
            raise SystemExit(f"ERROR: missing entitlements plist: {ent}")
    if shutil.which(args.ldid) is None and not os.path.isfile(args.ldid):
        raise SystemExit(f"ERROR: ldid not found: {args.ldid}")

    return DebResigner(args).run_dir(args.debs_dir)


if __name__ == "__main__":
    sys.exit(main())
