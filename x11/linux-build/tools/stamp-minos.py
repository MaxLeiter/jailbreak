#!/usr/bin/env python3
"""Stamp MinimumOSVersion into every out/*.deb, computed from the binaries.

WHY: none of the built debs set MinimumOSVersion, so Sileo/Zebra offer them to
iOS devices below the binaries' dyld floor (LC_BUILD_VERSION minos), where they
crash with "built for a newer version of iOS". This tool computes the true floor
and stamps it, control-only (the signed Mach-O data.tar is kept byte-identical).

The stamped value is the EFFECTIVE (dependency-closure) floor = max of a package's
own binary minos and the minos of every in-repo package it Depends on. That way a
package is only offered where its whole in-repo closure can load (e.g. gnome-console
inherits 16.5 from libgtop-2.0-11; the GTK/GNOME catalog inherits 16.2 from
libgtkintl + gobject-introspection). Pure-data packages with no Mach-O and no
binary deps (icon themes, iso-codes, wayland-protocols) get no field.

Also adds Provides to libwayland0 (it ships the four split Debian wayland dylibs
under one package, so consumers using the Debian names — e.g. libmutter's
libwayland-server0 — resolve).

Usage:
    python3 tools/stamp-minos.py            # dry-run, prints planned floors
    python3 tools/stamp-minos.py --apply    # rewrite out/*.deb in place

Pure Python; needs 3.14 (zstd via `compression.zstd`). No dpkg/docker required.
Idempotent: re-running replaces the managed fields, never duplicates them.
"""
import os, io, sys, re, json, struct, tarfile, lzma, gzip
from compression import zstd

HERE = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.normpath(os.path.join(HERE, "..", "out"))
APPLY = "--apply" in sys.argv

PROVIDES_FIX = {
    "libwayland0": "libwayland-client0, libwayland-cursor0, libwayland-egl1, libwayland-server0",
}

# Depends the recipes missed but the binaries strongly link (dyld-landmine audit
# 2026-07: a fresh install dyld-fails without these; the dev device only worked
# because the libs happened to be present). Control-only, appended at stamp time
# and merged into the effective-floor graph below. The recipe .control sources
# should grow the same lines whenever their package next rebuilds.
DEPENDS_ADD = {
    "libgtk-4-1":               ["libxkbcommon0", "libwayland0", "libcairo-script-interpreter2"],
    "gtk-4-bin":                ["libxkbcommon0", "libwayland0", "libcairo-script-interpreter2"],
    "libgjs0":                  ["libcairo-gobject2"],
    "libgnome-autoar-0-0":      ["libgtk-3-0"],
    "libtracker-sparql-3.0-0":  ["libsoup-3.0-0"],   # dlopen'd libtracker-http-soup3.so
    "xwayland":                 ["libxau6"],
    "libxkbcommon-dev":         ["libxcb1"],          # libxkbcommon-x11
    "libmutter-14-0":           ["angle", "libei1", "libatk1.0-0"],
    "libstartup-notification0": ["libxcb-util1", "libx11-xcb1"],          # procursus
    "libxcb-render0":           ["libxau6", "libxdmcp6"],                 # procursus
    "tigervnc-common":          ["libsm6", "libice6", "libx11-6", "libxext6",
                                 "libjpeg62-turbo", "libpixman-1-0", "libgnutls30"],
    "tigervnc-scraping-server": ["libxtst6", "libxfixes3", "libxrandr2",
                                 "libsm6", "libice6", "libxext6"],
    # These link @rpath/libintl.dylib (unversioned). Procursus libintl-dev owns
    # the /var/jb/usr/lib/libintl.dylib -> libintl.8.dylib symlink that resolves
    # it, so depend on it as a bridge until each recipe relinks to libintl.8
    # (do NOT ship our own copy of that symlink: dpkg file conflict).
    "ibus":                     ["libintl-dev"],
    "libenchant-2-2":           ["libintl-dev"],
    "libgee-0.8-2":             ["libintl-dev"],
    "libgeocode-glib0":         ["libintl-dev"],
    "libgweather-4-0":          ["libintl-dev"],
    "libibus-1.0-5":            ["libintl-dev"],
}

# ── Mach-O minos (LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS), fat-aware ──────
FAT=(0xcafebabe,0xcafebabf); MH64=0xfeedfacf; MH64R=0xcffaedfe
LC_VMIN_IOS=0x25; LC_BUILD=0x32
def _vs(v): return f"{(v>>16)&0xffff}.{(v>>8)&0xff}.{v&0xff}"
def _thin(data,off):
    m=struct.unpack_from("<I",data,off)[0]
    end = "<" if m==MH64 else ">" if m==MH64R else None
    if end is None: return 0
    ncmds=struct.unpack_from(end+"I",data,off+16)[0]; p=off+32
    best=0
    for _ in range(ncmds):
        cmd,sz=struct.unpack_from(end+"II",data,p)
        if cmd==LC_BUILD:
            plat,minos=struct.unpack_from(end+"II",data,p+8)[:2]
            if plat in (2,7): best=max(best,minos)
        elif cmd==LC_VMIN_IOS:
            best=max(best,struct.unpack_from(end+"I",data,p+8)[0])
        p+=sz
        if sz==0: break
    return best
def macho_minos(data):
    if len(data)<8: return 0
    if struct.unpack_from(">I",data,0)[0] in FAT:
        nfat=struct.unpack_from(">I",data,4)[0]; p=8; best=0; f64=data[3]==0xbf
        for _ in range(nfat):
            if f64: off=struct.unpack_from(">Q",data,p+8)[0]; p+=32
            else:   off=struct.unpack_from(">I",data,p+8)[0]; p+=20
            best=max(best,_thin(data,off))
        return best
    return _thin(data,0)

# ── ar (deb) split/build, keeping non-control members byte-identical ─────────
def ar_split(data):
    assert data[:8]==b"!<arch>\n"
    out=[]; off=8
    while off+60<=len(data):
        hdr=data[off:off+60]; off+=60
        size=int(hdr[48:58].decode().strip()); body=data[off:off+size]; off+=size
        if size&1: off+=1
        out.append({"hdr":hdr,"name":hdr[0:16].decode().strip().rstrip("/"),"body":body})
    return out
def ar_build(members):
    b=io.BytesIO(); b.write(b"!<arch>\n")
    for m in members:
        b.write(m["hdr"]); b.write(m["body"])
        if len(m["body"])&1: b.write(b"\n")
    return b.getvalue()
def _hdr_size(hdr,n): return hdr[:48]+f"{n}".ljust(10).encode()+hdr[58:]
def _tar_mode(n): return {"gz":"r:gz","xz":"r:xz","zst":"r:zst"}.get(n.rsplit(".",1)[-1],"r:*")
def _compress_like(name,data):
    suf=name.rsplit(".",1)[-1]
    if suf=="zst": return zstd.compress(data,level=19)
    if suf=="xz":  return lzma.compress(data,format=lzma.FORMAT_XZ,preset=6)
    if suf=="gz":  return gzip.compress(data,9,mtime=0)
    raise ValueError(name)

def read_control_and_minos(raw):
    members=ar_split(raw)
    cm=next(m for m in members if m["name"].startswith("control.tar"))
    with tarfile.open(fileobj=io.BytesIO(cm["body"]),mode=_tar_mode(cm["name"])) as tf:
        ci=next(m for m in tf.getmembers() if m.name.lstrip("./")=="control")
        text=tf.extractfile(ci).read().decode()
    dm=next(m for m in members if m["name"].startswith("data.tar"))
    floor=0
    with tarfile.open(fileobj=io.BytesIO(dm["body"]),mode=_tar_mode(dm["name"])) as tf:
        for mi in tf.getmembers():
            if not mi.isreg(): continue
            f=tf.extractfile(mi); head=f.read(4)
            if head in (b"\xcf\xfa\xed\xfe",b"\xfe\xed\xfa\xcf",b"\xca\xfe\xba\xbe",b"\xca\xfe\xba\xbf"):
                floor=max(floor,macho_minos(head+f.read()))
    return text,floor

def deps_of(text):
    d={}
    for ln in text.splitlines():
        if ln.startswith(("Depends:","Pre-Depends:")):
            for part in ln.split(":",1)[1].split(","):
                for alt in part.split("|"):
                    n=re.sub(r"\(.*","",alt.strip().split()[0]).split(":")[0] if alt.strip().split() else ""
                    if n: d.setdefault(n,None)
    return list(d)

def _merge_depends(line,adds):
    existing={re.sub(r"\(.*","",alt.strip()).strip().split()[0]
              for part in line.split(":",1)[1].split(",")
              for alt in part.split("|") if alt.strip()}
    missing=[a for a in adds if a not in existing]
    return line.rstrip()+(", "+", ".join(missing) if missing else "")

def edit_control(text,pkg,minos):
    lines=[l for l in text.split("\n")]
    while lines and lines[-1]=="": lines.pop()
    out=[]; arch=None; had_dep=False
    for ln in lines:
        key=ln.split(":",1)[0] if (":" in ln and not ln.startswith(" ")) else ""
        if key=="MinimumOSVersion": continue
        if key=="Provides" and pkg in PROVIDES_FIX: continue
        if key=="Depends" and pkg in DEPENDS_ADD:
            ln=_merge_depends(ln,DEPENDS_ADD[pkg]); had_dep=True
        out.append(ln)
        if key=="Architecture": arch=len(out)-1
    ins=([f"MinimumOSVersion: {minos}"] if minos else []) + \
        ([f"Provides: {PROVIDES_FIX[pkg]}"] if pkg in PROVIDES_FIX else []) + \
        ([f"Depends: {', '.join(DEPENDS_ADD[pkg])}"]
         if (pkg in DEPENDS_ADD and not had_dep) else [])
    if ins:
        at=(arch+1) if arch is not None else len(out)
        out[at:at]=ins
    return ("\n".join(out)+"\n").encode()

def rewrite(raw,minos):
    members=ar_split(raw)
    ci=next(i for i,m in enumerate(members) if m["name"].startswith("control.tar"))
    cm=members[ci]; text,_=None,None
    with tarfile.open(fileobj=io.BytesIO(cm["body"]),mode=_tar_mode(cm["name"])) as tf:
        text=tf.extractfile(next(m for m in tf.getmembers() if m.name.lstrip("./")=="control")).read().decode()
    pkg=next((l.split(":",1)[1].strip() for l in text.splitlines() if l.startswith("Package:")),None)
    newctl=edit_control(text,pkg,minos)
    buf=io.BytesIO()
    with tarfile.open(fileobj=buf,mode="w",format=tarfile.GNU_FORMAT) as dst, \
         tarfile.open(fileobj=io.BytesIO(cm["body"]),mode=_tar_mode(cm["name"])) as src:
        for mi in src.getmembers():
            if mi.name.lstrip("./")=="control":
                ni=tarfile.TarInfo(mi.name); ni.mode=mi.mode; ni.uid=mi.uid; ni.gid=mi.gid
                ni.uname=mi.uname; ni.gname=mi.gname; ni.mtime=mi.mtime; ni.size=len(newctl)
                dst.addfile(ni,io.BytesIO(newctl))
            elif mi.isreg(): dst.addfile(mi,io.BytesIO(src.extractfile(mi).read()))
            else: dst.addfile(mi)
    z=_compress_like(cm["name"],buf.getvalue())
    members[ci]={"hdr":_hdr_size(cm["hdr"],len(z)),"name":cm["name"],"body":z}
    new=ar_build(members)
    a=next(m for m in ar_split(raw) if m["name"].startswith("data.tar"))["body"]
    b=next(m for m in ar_split(new) if m["name"].startswith("data.tar"))["body"]
    assert a==b, "data.tar changed!"
    return new,pkg

def main():
    debs=sorted(f for f in os.listdir(OUT) if f.endswith(".deb"))
    own={}; deps={}; pkgfile={}
    for fn in debs:
        text,floor=read_control_and_minos(open(os.path.join(OUT,fn),"rb").read())
        pkg=next((l.split(":",1)[1].strip() for l in text.splitlines() if l.startswith("Package:")),fn)
        own[pkg]=max(own.get(pkg,0),floor); deps[pkg]=deps_of(text); pkgfile.setdefault(pkg,fn)
    for p,adds in DEPENDS_ADD.items():
        if p in deps: deps[p]=list(dict.fromkeys(deps[p]+adds))
    floor=dict(own)
    for _ in range(40):
        ch=False
        for p in floor:
            c=floor[p]
            for t in deps[p]:
                if t in floor and floor[t]>c: c=floor[t]
            if c!=floor[p]: floor[p]=c; ch=True
        if not ch: break
    # --json PATH: emit the per-package floor map (own binary minos + effective
    # dependency-closure floor) for the distribution chooser to gate flavors on:
    # a flavor's minimum iOS = max effective floor over its package closure.
    if "--json" in sys.argv:
        out_path=sys.argv[sys.argv.index("--json")+1]
        m={p:{"own":_vs(own[p]),"effective":_vs(floor[p]),
              "file":pkgfile.get(p,"")} for p in sorted(floor)}
        json.dump({"packages":m,
                   "note":"effective = max(own binary minos, all in-repo deps' floors); "
                          "a flavor's min iOS = max effective over its package closure"},
                  open(out_path,"w"), indent=1)
        print(f"wrote floor map: {out_path} ({len(m)} packages)")
    for fn in debs:
        raw=open(os.path.join(OUT,fn),"rb").read()
        pkg=next((l.split(":",1)[1].strip() for l in read_control_and_minos(raw)[0].splitlines() if l.startswith("Package:")),fn)
        mv=_vs(floor[pkg]) if floor[pkg] else ""
        new,_=rewrite(raw,mv)
        if APPLY: open(os.path.join(OUT,fn),"wb").write(new)
        print(f"  [{'WROTE' if APPLY else 'dry'}] {fn:58} minos={mv or '-'}"
              +("  +Provides" if pkg in PROVIDES_FIX else ""))
    print(f"\n{'APPLIED' if APPLY else 'DRY-RUN'}: {len(debs)} debs")

if __name__=="__main__":
    main()
