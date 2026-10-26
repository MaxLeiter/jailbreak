#!/usr/bin/env python3
# resign.py PKG...: re-sign every Mach-O a package installed, on the device, the safe way:
# copy to a new file, ldid -S (keeping the file's own entitlements) on the copy, then mv over the original.
import os, subprocess, sys, tempfile
n = 0
for pkg in sys.argv[1:]:
    files = subprocess.run(["dpkg", "-L", pkg], capture_output=True, text=True, check=True).stdout.split("\n")
    for f in files:
        if not f or os.path.islink(f) or not os.path.isfile(f):
            continue
        with open(f, "rb") as fh:
            hdr = fh.read(16)
            if hdr[:4] != b"\xcf\xfa\xed\xfe" or int.from_bytes(hdr[12:16], "little") == 1:  # skip MH_OBJECT
                continue
        ent = subprocess.run(["ldid", "-e", f], capture_output=True).stdout
        new = f + ".jitnew"
        subprocess.run(["cp", "-p", f, new], check=True)
        if ent.strip():
            with tempfile.NamedTemporaryFile(suffix=".xml", delete=False, dir="/var/jb/tmp") as t:
                t.write(ent)
            subprocess.run(["ldid", "-S" + t.name, new], check=True)
            os.unlink(t.name)
        else:
            subprocess.run(["ldid", "-S", new], check=True)
        os.rename(new, f)
        n += 1
print("re-signed %d Mach-O files" % n)
