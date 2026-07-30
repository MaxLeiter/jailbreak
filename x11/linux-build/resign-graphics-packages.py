#!/usr/bin/env python3
"""Re-DER-sign the X11/Wayland graphics packages in a repo/debs directory.

This is the publish-time safety net invoked by ``finalize_x11_graphics_debs`` in
``bin/publish-repo.sh`` / ``bin/publish-staging.sh``. The per-package build
recipes already ``$(call SIGN,<pkg>,<ent>)`` their executables, but a .deb can be
rebuilt, repacked, or copied through tooling that drops the code signature. iOS
15+/16 AMFI rejects the IOKit/IOSurface/task_for_pid privileges these binaries
need unless the entitlements are carried as a *DER* signature, so before anything
goes live we walk every .deb and guarantee the DER blob is present and correct.

A binary is a "graphics binary" iff its current entitlements carry a
GPU/IOSurface IOKit user-client marker (AGXDeviceUserClient /
IOGPUDeviceUserClient / IOSurface*). Each graphics binary is first classified
and validated against one of four hardware profiles:

  * gpu-client: unplatformed AGX/IOGPU + IOSurface client.
  * platform-gl: platform/task-port AGX/IOGPU + IOSurface compositor/helper.
  * iosurface-ipc: unplatformed IOSurface-only IPC helper.
  * platform-iosurface: platform/task-port IOSurface-only host.

After validation, each binary is re-signed with *its own current entitlements*,
extracted with ``ldid -e`` and re-applied with ``ldid -S`` so the DER blob is
regenerated. Its privileges are NEVER changed: the packages use per-binary
entitlement sets that differ in detail (e.g. Xios carries
``com.apple.private.security.no-container`` and only the IOSurface user-clients,
which iosc-gl-ent.xml deliberately omits), so imposing a single generic ent file
would silently add or drop entitlements. Preserving each binary's own set is the
only safe re-sign. --gpu-ent / --gl-ent are validated reference marker sets (and
satisfy the caller's contract); they are not blindly stamped onto binaries.

A .deb with no GPU-marked binary is not a graphics package and is skipped. A
graphics binary that carries NO entitlements at all is a build bug (its recipe
SIGN step did not run) and is a hard error rather than a guess. Because the
extract-and-re-apply round-trip is deterministic, a correctly built .deb is left
byte-for-byte unchanged, so the step is safe to run on every publish (no churn).

The publish host is macOS, which has no dpkg-deb, so .debs are unpacked and
repacked with ar + tar (the same host tools xmkdeb falls back to). Ownership is
forced back to root:root on repack.

Because the round-trip is byte-stable, the expensive part is finding the binaries,
not signing them: a full pass over ~780 packages unpacks and repacks ~750MB to
normally change nothing, which measured 110s and dominated publish time. Two flags
bound that without weakening the check -- they decide what to LOOK at, never what
counts as valid:

  --only  <pkg,...>  restrict to those packages. A scoped publish deploys nothing
                     else, so signing the rest cannot change what ships (0.9s).
  --cache <file>     remember (size,mtime) of packages that already passed and skip
                     them while unchanged (1.0s for a full pass, and a package that
                     is new or rebuilt is still signed).

A .deb that disappears mid-pass is skipped rather than fatal: repo/debs is shared
with concurrent builds that add and retire packages, and a package this publish is
not deploying must not be able to fail it.

Usage:
    resign-graphics-packages.py <debs-dir> \
        --ldid /opt/homebrew/bin/ldid \
        --gpu-ent .../iosc-gpu-client-ent.xml \
        --gl-ent  .../iosc-gl-ent.xml \
        [--only iosc,kwin] [--cache ~/.cache/xios-der-resign.stamps] \
        [--dry-run] [--verbose]
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
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

LC_CODE_SIGNATURE = 0x1D
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSSLOT_DER_ENTITLEMENTS = 0x7

# Raw file magic -> (byte order, Mach-O header size). Load commands start after
# the 28-byte 32-bit or 32-byte 64-bit header.
THIN_MACHO_LAYOUTS = {
    b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xfe\xed\xfa\xce": (">", 28),
    b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xfe\xed\xfa\xcf": (">", 32),
}
FAT_MACHO_LAYOUTS = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}

# A binary is only a graphics binary if it carries one of the GPU/IOSurface
# IOKit user-client markers. This is the gate that keeps the pass off ordinary
# Procursus daemons: those are platformized with com.apple.private.* +
# platform-application but hold no GPU markers, so they must never be reclassified
# and re-signed with a graphics entitlement set (which would strip their real
# entitlements). Both iosc-gpu-client-ent.xml and iosc-gl-ent.xml carry these.
GPU_ACCEL_MARKERS = ("AGXDeviceUserClient", "IOGPUDeviceUserClient")
IOSURFACE_MARKERS = ("IOSurfaceRootUserClient", "IOSurfaceSendRight")
GPU_MARKERS = GPU_ACCEL_MARKERS + IOSURFACE_MARKERS + ("IOSurfaceAcceleratorClient",)

# Among graphics binaries, a platform GL/IOSurface process additionally holds
# the platform / task-port privileges (drives ANGLE/Metal and/or imports client
# IOSurfaces). These distinguish iosc-gl-ent.xml from iosc-gpu-client-ent.xml.
COMPOSITOR_MARKERS = ("platform-application", "task_for_pid-allow",
                      "com.apple.system-task-ports")
GPU_CLIENT_REQUIRED = ("com.apple.private.amfi.can-allow-non-platform",
                       "get-task-allow")
PLATFORM_GL_REQUIRED = ("platform-application",
                        "com.apple.private.amfi.can-allow-non-platform",
                        "com.apple.private.skip-library-validation",
                        "task_for_pid-allow",
                        "com.apple.system-task-ports")
IOSURFACE_IPC_REQUIRED = ("com.apple.private.amfi.can-allow-non-platform",)
PLATFORM_IOSURFACE_REQUIRED = ("platform-application",
                               "com.apple.private.amfi.can-allow-non-platform",
                               "task_for_pid-allow",
                               "com.apple.system-task-ports")
FORBIDDEN_GRAPHICS_MARKERS = ("com.apple.private.security.no-container",)

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


def macho_slices(blob: bytes, path: str) -> list[tuple[int, int]]:
    """Return (offset, size) for every thin Mach-O slice in *blob*."""
    layout = THIN_MACHO_LAYOUTS.get(blob[:4])
    if layout:
        return [(0, len(blob))]

    fat = FAT_MACHO_LAYOUTS.get(blob[:4])
    if not fat or len(blob) < 8:
        raise SystemExit(f"ERROR: unsupported Mach-O layout: {path}")
    endian, is_64 = fat
    count = struct.unpack_from(endian + "I", blob, 4)[0]
    arch_format = endian + ("IIQQII" if is_64 else "IIIII")
    arch_size = struct.calcsize(arch_format)
    cursor = 8
    slices = []
    for _ in range(count):
        if cursor + arch_size > len(blob):
            raise SystemExit(f"ERROR: truncated fat Mach-O header: {path}")
        arch = struct.unpack_from(arch_format, blob, cursor)
        offset, size = arch[2], arch[3]
        if offset + size > len(blob):
            raise SystemExit(f"ERROR: invalid fat Mach-O slice bounds: {path}")
        slices.append((offset, size))
        cursor += arch_size
    return slices


def signature_slots(path: str) -> list[set[int]]:
    """Return the embedded code-signature slot types for each Mach-O slice."""
    with open(path, "rb") as fh:
        blob = fh.read()
    result = []
    for base, slice_size in macho_slices(blob, path):
        layout = THIN_MACHO_LAYOUTS.get(blob[base:base + 4])
        if not layout:
            raise SystemExit(f"ERROR: fat archive contains a non-Mach-O slice: {path}")
        endian, header_size = layout
        if base + header_size > len(blob):
            raise SystemExit(f"ERROR: truncated Mach-O header: {path}")
        command_count = struct.unpack_from(endian + "I", blob, base + 16)[0]
        cursor = base + header_size
        signature = None
        for _ in range(command_count):
            if cursor + 8 > base + slice_size:
                raise SystemExit(f"ERROR: truncated Mach-O load commands: {path}")
            command, command_size = struct.unpack_from(endian + "II", blob, cursor)
            if command_size < 8 or cursor + command_size > base + slice_size:
                raise SystemExit(f"ERROR: invalid Mach-O load command: {path}")
            if command == LC_CODE_SIGNATURE:
                signature = struct.unpack_from(endian + "II", blob, cursor + 8)
            cursor += command_size
        if signature is None:
            result.append(set())
            continue
        data_offset, data_size = signature
        start = base + data_offset
        end = start + data_size
        if end > base + slice_size or start + 12 > len(blob):
            raise SystemExit(f"ERROR: invalid Mach-O code-signature bounds: {path}")
        magic, length, count = struct.unpack_from(">III", blob, start)
        if magic != CSMAGIC_EMBEDDED_SIGNATURE or length > data_size:
            raise SystemExit(f"ERROR: invalid embedded code signature: {path}")
        if 12 + count * 8 > length:
            raise SystemExit(f"ERROR: truncated embedded code-signature index: {path}")
        result.append({
            struct.unpack_from(">II", blob, start + 12 + index * 8)[0]
            for index in range(count)
        })
    return result


def has_der_entitlements(path: str) -> bool:
    slots = signature_slots(path)
    return bool(slots) and all(CSSLOT_DER_ENTITLEMENTS in item for item in slots)


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


def strip_xml_comments(ents: str) -> str:
    return re.sub(r"<!--.*?-->", "", ents, flags=re.S)


def missing_markers(ents: str, markers: tuple[str, ...]) -> list[str]:
    return [m for m in markers if m not in ents]


def tier(ents: str) -> str | None:
    """Return a graphics/IOSurface profile label or None.

    The label does not select an entitlement file: binaries are re-signed with
    their own entitlements, not with --gl-ent / --gpu-ent.
    """
    ents = strip_xml_comments(ents)
    if not any(m in ents for m in GPU_MARKERS):
        return None
    has_platform = any(m in ents for m in COMPOSITOR_MARKERS)
    has_gpu_accel = any(m in ents for m in GPU_ACCEL_MARKERS)
    if has_platform and has_gpu_accel:
        return "platform-gl"
    if has_platform:
        return "platform-iosurface"
    return "gpu-client" if has_gpu_accel else "iosurface-ipc"


def validate_graphics_profile(ents: str, path: str) -> str | None:
    """Validate the named graphics entitlement profile for a binary.

    This intentionally checks markers rather than plist structure so it works on
    the ldid -e output we already use. It preserves the existing policy that the
    finalizer never changes a binary's privileges; it only refuses incoherent
    profiles before re-DER-signing them.
    """
    ents = re.sub(r"<!--.*?-->", "", ents, flags=re.S)
    kind = tier(ents)
    if kind is None:
        return None
    bad = [m for m in FORBIDDEN_GRAPHICS_MARKERS if m in ents]
    if bad and kind in ("platform-gl", "gpu-client"):
        raise SystemExit(
            f"ERROR: {path} matches graphics profile {kind} but carries forbidden "
            f"entitlement marker(s): {', '.join(bad)}")
    missing = missing_markers(ents, IOSURFACE_MARKERS)
    if missing:
        raise SystemExit(
            f"ERROR: {path} matches graphics profile {kind} but is missing "
            f"IOSurface marker(s): {', '.join(missing)}")
    if kind in ("platform-gl", "gpu-client"):
        missing = missing_markers(ents, GPU_ACCEL_MARKERS)
        if missing:
            raise SystemExit(
                f"ERROR: {path} matches graphics profile {kind} but is missing "
                f"GPU acceleration marker(s): {', '.join(missing)}")
    if kind == "platform-gl":
        required = PLATFORM_GL_REQUIRED
    elif kind == "platform-iosurface":
        required = PLATFORM_IOSURFACE_REQUIRED
    elif kind == "gpu-client":
        required = GPU_CLIENT_REQUIRED
    else:
        required = IOSURFACE_IPC_REQUIRED
    missing = missing_markers(ents, required)
    if missing:
        raise SystemExit(
            f"ERROR: {path} matches graphics profile {kind} but is missing "
            f"required marker(s): {', '.join(missing)}")
    if kind in ("gpu-client", "iosurface-ipc"):
        accidental = [m for m in COMPOSITOR_MARKERS if m in ents]
        if accidental:
            raise SystemExit(
                f"ERROR: {path} matches {kind} but carries platform/task "
                f"marker(s): {', '.join(accidental)}")
    return kind


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
        self.only = tuple(n for n in (x.strip() for x in args.only.split(",")) if n)
        self.cache_path = args.cache
        self.cache = {}
        self.skipped = 0
        self.vanished = 0
        if self.cache_path and not self.dry_run:
            try:
                with open(self.cache_path, "r", encoding="utf-8") as fh:
                    for line in fh:
                        name, _, stamp = line.rstrip("\n").partition("\t")
                        if name and stamp:
                            self.cache[name] = stamp
            except FileNotFoundError:
                pass

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
        if not has_der_entitlements(path):
            raise SystemExit(
                f"ERROR: {path} still lacks DER entitlements after host re-signing")

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
                kind = validate_graphics_profile(entitlements(self.ldid, fp), fp)
                if kind is None:
                    continue
                rel = os.path.relpath(fp, root)
                if has_der_entitlements(fp):
                    if self.verbose:
                        log(f"    already-signed [{kind}] {rel}")
                    continue
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

    @staticmethod
    def _stamp(path: str) -> str:
        st = os.stat(path)
        return f"{st.st_size}:{st.st_mtime_ns}"

    def _write_cache(self, debs_dir: str, debs) -> None:
        """Persist stamps. In a finally block, so a crash mid-pass still banks the
        work already done rather than throwing the whole run away."""
        if not self.cache_path or self.dry_run:
            return
        # Re-stat AFTER processing: a re-signed .deb has a new mtime, and stamping
        # the pre-run value would make the next publish redo it.
        for name in debs:
            try:
                self.cache[name] = self._stamp(os.path.join(debs_dir, name))
            except OSError:
                self.cache.pop(name, None)
        try:
            tmp = self.cache_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                for name in sorted(self.cache):
                    fh.write(f"{name}\t{self.cache[name]}\n")
            os.replace(tmp, self.cache_path)
        except OSError as exc:
            # A cache is an optimisation; failing to write one must never fail a
            # publish that has otherwise succeeded.
            log(f"resign-graphics-packages: could not write cache: {exc}")

    def run_dir(self, debs_dir: str) -> int:
        debs = sorted(f for f in os.listdir(debs_dir) if f.endswith(".deb"))
        if not debs:
            log(f"resign-graphics-packages: no .deb files in {debs_dir}")
            return 0

        if self.only:
            # Debian filenames are <package>_<version>_<arch>.deb, so match on the
            # name up to the first underscore rather than a prefix: "iosc" must not
            # also pull in "iosc-desktop".
            wanted = set(self.only)
            debs = [f for f in debs if f.partition("_")[0] in wanted]
            if not debs:
                raise SystemExit("ERROR: --only matched no .deb in "
                                 f"{debs_dir}: {', '.join(sorted(wanted))}")

        considered = len(debs)
        todo = []
        for name in debs:
            path = os.path.join(debs_dir, name)
            if self.cache.get(name) == self._stamp(path):
                self.skipped += 1
                continue
            todo.append(name)

        try:
            for name in todo:
                path = os.path.join(debs_dir, name)
                try:
                    self.process_deb(path)
                except FileNotFoundError:
                    # repo/debs is shared: other builds copy packages in and drop
                    # superseded ones while a publish is walking the directory. A
                    # .deb that disappeared mid-pass is not being deployed by this
                    # publish either, so it must not abort it -- this used to raise
                    # straight out of the signer and fail the whole run.
                    log(f"  vanished mid-pass, skipping: {name}")
                    self.vanished += 1
        finally:
            self._write_cache(debs_dir, debs)

        verb = "would re-sign" if self.dry_run else "re-signed"
        log(f"resign-graphics-packages: {verb} {self.signed_bins} binaries across "
            f"{self.changed_debs} package(s) ({considered} considered, "
            f"{self.skipped} unchanged-skipped, {self.vanished} vanished)")
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
    ap.add_argument("--only", default="",
                    help="comma-separated package names; restrict the pass to .debs "
                         "whose filename starts with one of them. A scoped publish "
                         "deploys nothing else, so signing the rest is pure work.")
    ap.add_argument("--cache", default="",
                    help="stamp file recording (name,size,mtime) of .debs already "
                         "verified. Re-signing is byte-stable, so an unchanged .deb "
                         "cannot need work; skipping it is what makes repeat "
                         "publishes cheap.")
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

    with open(args.gpu_ent, "r", encoding="utf-8") as fh:
        gpu_kind = validate_graphics_profile(fh.read(), args.gpu_ent)
    if gpu_kind != "gpu-client":
        raise SystemExit(
            f"ERROR: --gpu-ent must match gpu-client profile, got {gpu_kind}")
    with open(args.gl_ent, "r", encoding="utf-8") as fh:
        gl_kind = validate_graphics_profile(fh.read(), args.gl_ent)
    if gl_kind != "platform-gl":
        raise SystemExit(
            f"ERROR: --gl-ent must match platform-gl profile, got {gl_kind}")

    return DebResigner(args).run_dir(args.debs_dir)


if __name__ == "__main__":
    sys.exit(main())
