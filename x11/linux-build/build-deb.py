#!/usr/bin/env python3
"""Build a rootless iOS .deb (control.tar.zst + data.tar.zst) on macOS, no dpkg.

Usage: build-deb.py <stagedir> <outdir>
  <stagedir> contains DEBIAN/ (control + maintainer scripts) and the payload
  tree (e.g. var/jb/...). All files are forced to root:root; dirs 0755;
  maintainer scripts 0755; other files keep their on-disk mode (masked to 0644
  unless already executable).
Prints the built .deb path.
"""
import io, os, sys, tarfile, subprocess, time

def zst(raw: bytes) -> bytes:
    return subprocess.run(["zstd", "-19", "-c"], input=raw,
                          stdout=subprocess.PIPE, check=True).stdout

def build_tar(root, arcnames):
    """Tar the given (abs_path, arcname) pairs, root:root, sorted, reproducible."""
    buf = io.BytesIO()
    tf = tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT)
    for abspath, arcname in arcnames:
        ti = tf.gettarinfo(abspath, arcname)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        if ti.isdir():
            ti.mode = 0o755
            tf.addfile(ti)
        elif ti.issym():
            tf.addfile(ti)
        else:
            base = os.path.basename(arcname)
            if base in ("postinst", "preinst", "postrm", "prerm", "config", "extrainst_"):
                ti.mode = 0o755
            elif ti.mode & 0o111:
                ti.mode = 0o755
            else:
                ti.mode = 0o644
            with open(abspath, "rb") as f:
                tf.addfile(ti, io.BytesIO(f.read()))
    tf.close()
    return buf.getvalue()

def walk(root, prefix_filter=None):
    """Yield (abspath, arcname) for every entry under root, dirs before files."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort(); filenames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            out.append((dirpath, "./" + rel))
        for fn in filenames:
            ap = os.path.join(dirpath, fn)
            arc = "./" + os.path.relpath(ap, root)
            out.append((ap, arc))
    return out

def ar_member(name, data, mtime=0, mode=0o100644):
    hdr = (f"{name:<16}{mtime:<12}{0:<6}{0:<6}{mode:<8o}{len(data):<10}`\n")
    assert len(hdr) == 60, len(hdr)
    out = hdr.encode() + data
    if len(data) % 2: out += b"\n"
    return out

def main():
    stage, outdir = sys.argv[1], sys.argv[2]
    debian = os.path.join(stage, "DEBIAN")
    ctrl = {}
    for ln in open(os.path.join(debian, "control")):
        if ": " in ln and not ln.startswith(" "):
            k, v = ln.rstrip("\n").split(": ", 1); ctrl[k] = v
    pkg, ver, arch = ctrl["Package"], ctrl["Version"], ctrl["Architecture"]

    # control.tar: contents of DEBIAN/ (as ./control, ./postinst, ...)
    ctrl_entries = walk(debian)
    control_tar = build_tar(debian, ctrl_entries)

    # data.tar: everything in stage EXCEPT DEBIAN/
    data_entries = [(a, n) for (a, n) in walk(stage)
                    if not (n == "./DEBIAN" or n.startswith("./DEBIAN/"))]
    data_tar = build_tar(stage, data_entries)

    deb = os.path.join(outdir, f"{pkg}_{ver}_{arch}.deb")
    with open(deb, "wb") as f:
        f.write(b"!<arch>\n")
        f.write(ar_member("debian-binary", b"2.0\n"))
        f.write(ar_member("control.tar.zst", zst(control_tar)))
        f.write(ar_member("data.tar.zst", zst(data_tar)))
    print(deb)

if __name__ == "__main__":
    main()
