#!/usr/bin/env bash
# Runs INSIDE the container (see Dockerfile). Clones Procursus, applies our patches
# portably, and builds the fixed tigervnc .deb for the selected Procursus target.
# Output debs are copied to /out (bind-mounted from the host by run.sh).
set -euo pipefail
umask 022

PATCHES=/work/patches
OUT=/out
cd /work

echo "==> [1/4] clone Procursus (fresh)"
if [ ! -d Procursus/.git ]; then
  git clone --depth 1 https://github.com/ProcursusTeam/Procursus.git
fi
cd Procursus

echo "==> [2/4] apply our patches (idempotent, no absolute paths)"
stage_port_patch_stack() {
  local pkg="$1"
  local patch_dir="/work/ports/$pkg/patches"
  local dest="build_patch/$pkg"
  local patch_file
  [ -f "$patch_dir/series" ] || {
    echo "ERROR: missing $patch_dir/series; mount x11/ports at /work/ports" >&2
    exit 1
  }
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -v "$patch_dir/series" "$dest/"
  while IFS= read -r patch_file || [ -n "$patch_file" ]; do
    patch_file="${patch_file%%#*}"
    set -- $patch_file
    [ "$#" -gt 0 ] || continue
    cp -v "$patch_dir/$1" "$dest/"
  done < "$patch_dir/series"
}

stage_port_patch_stack tigervnc
stage_port_patch_stack mesa

python3 - <<'PY'
import io, re, pathlib

def edit(path, fn):
    p = pathlib.Path(path); s = p.read_text(); n = fn(s)
    if n != s: p.write_text(n); print(f"   patched {path}")
    else: print(f"   (already patched) {path}")

# 1) Xvnc shell-path fix: apply our os/utils.c patch right after tigervnc's own
#    xserver patch, gated to the rootless /var/jb prefix.
def tigervnc(s):
    anchor = "patch -p1 < $(BUILD_WORK)/tigervnc/unix/xserver$(XORG_VERSION).patch && \\\n"
    inject = ('\t{ [ "$(MEMO_PREFIX)" != "/var/jb" ] || patch -p1 < '
              '$(BUILD_ROOT)/build_patch/tigervnc/0001-xserver-popen-shell-rootless.patch; } && \\\n')
    if "0001-xserver-popen-shell-rootless.patch" in s:
        return s
    return s.replace(anchor, anchor + inject, 1)
edit("makefiles/tigervnc.mk", tigervnc)

# 2) Drop the bogus tigervnc-xorg-extension dependency from the standalone server.
def control(s):
    return s.replace(", tigervnc-common, tigervnc-xorg-extension",
                     ", tigervnc-common")
edit("build_info/tigervnc-standalone-server.control", control)

# 3) Fix the stale mesa download URL (freedesktop archive 404s for old versions)
#    and move Procursus's source sed edits into the x11/ports patch stack.
def mesa(s):
    s = s.replace("https://mesa.freedesktop.org/archive/mesa-$(MESA_VERSION).tar.xz",
                  "https://archive.mesa3d.org/older-versions/21.x/mesa-$(MESA_VERSION).tar.xz")
    if "$(call DO_PATCH,mesa,mesa,-p1)" in s:
        return s
    extract = "\t$(call EXTRACT_TAR,mesa-$(MESA_VERSION).tar.xz,mesa-$(MESA_VERSION),mesa)\n"
    mkdir = "\tmkdir -p $(BUILD_WORK)/mesa/build\n"
    start = s.find(extract)
    if start < 0:
        raise SystemExit("ERROR: mesa.mk extract anchor not found; Procursus layout changed")
    start += len(extract)
    end = s.find(mkdir, start)
    if end < 0:
        raise SystemExit("ERROR: mesa.mk build-dir anchor not found; Procursus layout changed")
    old_block = s[start:end]
    for marker in ("with_dri_platform = 'apple'", "dep_xcb_shm = dependency('xcb-shm')", "OpenGL/gl.h"):
        if marker not in old_block:
            raise SystemExit("ERROR: mesa.mk source-edit block not found; Procursus layout changed")
    return s[:start] + "\t$(call DO_PATCH,mesa,mesa,-p1)\n" + s[end:]
edit("makefiles/mesa.mk", mesa)

# 4) Skip libpng's APNG add-on patch (no longer applies; APNG not needed for X).
def libpng(s):
    return s.replace("\t$(call DO_PATCH,libpng16,libpng16,-p1)",
                     "\t# apng patch skipped (does not apply; not needed)\n"
                     "\t# $(call DO_PATCH,libpng16,libpng16,-p1)")
edit("makefiles/libpng16.mk", libpng)

# 5) The `setup` target copies macOS-SDK framework headers (FSEvents, Kernel, IOKit,
#    Security, sys/ttydev.h, ...). We provide a real MacOSX.sdk in the image, but keep
#    these copies non-fatal as a safety net for any header a newer SDK might drop.
edit("Makefile", lambda s: re.sub(r'(\n\t)@(cp -af\s+\$\(MACOSX_SYSROOT\))', r'\1-@\2', s))

# 6) cctools-port's clang++ defaults to GNU libstdc++ (absent); force Apple libc++.
def cxxflags(s):
    if "-stdlib=libc++" in s: return s
    s = s.replace("CXXFLAGS            := $(CFLAGS)",
                  "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
    s = s.replace("-Wl,-not_for_dyld_shared_cache",
                  "-Wl,-not_for_dyld_shared_cache -stdlib=libc++", 1)  # LDFLAGS line
    return s
edit("Makefile", cxxflags)

# 7) libpng's sourceforge "files" URL 404s for curl; use the direct-download mirror.
edit("makefiles/libpng16.mk", lambda s: s.replace(
    "https://sourceforge.net/projects/libpng/files/libpng16/$(LIBPNG16_VERSION)/libpng-$(LIBPNG16_VERSION).tar.xz",
    "https://downloads.sourceforge.net/libpng/libpng-$(LIBPNG16_VERSION).tar.xz"))

# 8) Xcode-26 macOS headers (arpa/inet.h, ...) that setup copies into build_base
#    #include <_bounds.h> (bounds-safety, 2024+). Also copy _bounds.h so they resolve
#    (it only needs sys/cdefs.h, which is present).
edit("Makefile", lambda s: s.replace(
    "/usr/include/{arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}",
    "/usr/include/{_bounds.h,arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}"))

# 9) mesa's shader disk-cache (disk_cache.c) needs dladdr/Dl_info and trips -Werror; a
#    swrast software build doesn't need it. Disable it in the meson config.
edit("makefiles/mesa.mk", lambda s: s.replace(
    "-Dgles1=disabled \\\n",
    "-Dgles1=disabled \\\n\t\t-Dshader-cache=disabled \\\n", 1))

# 10) dladdr/Dl_info are gated behind `!_POSIX_C_SOURCE || _DARWIN_C_SOURCE` (dlfcn.h:39);
#     define _DARWIN_C_SOURCE globally so dlfcn.h (incl. mesa's added include) exposes
#     them. (No global -include dlfcn.h — that regressed C deps like ncurses/libffi.)
def darwinsrc(s):
    s = s.replace("-D_DARWIN_C_SOURCE -include dlfcn.h", "-D_DARWIN_C_SOURCE")  # undo prior global force-include
    if "-D_DARWIN_C_SOURCE" in s: return s
    return s.replace("CXXFLAGS            := $(CFLAGS) -stdlib=libc++",
                     "CFLAGS              += -D_DARWIN_C_SOURCE\n"
                     "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
edit("Makefile", darwinsrc)

# 11) Build Xvfb from the same patched xserver for headless/debug X11 sessions.
edit("makefiles/tigervnc.mk", lambda s: s.replace("--disable-xvfb", "--enable-xvfb", 1))
PY

echo "==> [3/4] build tigervnc (NO_PGP=1 to skip flaky tarball gpg checks)"
# Default remains the current palera1n rootless target. A target-aware caller can
# pass XIOS_MEMO_TARGET/XIOS_MEMO_CFVER/XIOS_PREFIX from linux-build/target-lib.sh.
MEMO_TARGET="${XIOS_MEMO_TARGET:-${MEMO_TARGET:-iphoneos-arm64-rootless}}"
MEMO_CFVER="${XIOS_MEMO_CFVER:-${MEMO_CFVER:-1900}}"
if [ "${XIOS_PREFIX+x}" = x ]; then
  TARGET_PREFIX="$XIOS_PREFIX"
else
  TARGET_PREFIX="/var/jb"
fi
EXPECTED_SH="${TARGET_PREFIX}/bin/sh"
[ -n "$TARGET_PREFIX" ] || EXPECTED_SH="/bin/sh"
COMMON="MEMO_TARGET=$MEMO_TARGET MEMO_CFVER=$MEMO_CFVER NO_PGP=1"
# Force tigervnc (and its bundled xserver/hw/vfb) to recompile so the IOSurface DDX
# changes take effect — Procursus's .build_complete marker would otherwise skip it.
# All other deps (mesa, libx11, ...) keep their markers and are reused (fast).
# Paths derived from the same target/CFVER above so they can't drift out of sync.
echo "==> force tigervnc rebuild (IOSurface DDX changed; deps stay cached)"
rm -rf "build_work/$MEMO_TARGET/$MEMO_CFVER/tigervnc" \
       "build_stage/$MEMO_TARGET/$MEMO_CFVER/tigervnc" 2>/dev/null || true
# tigervnc's bundled xorg-server needs build deps missing from tigervnc's dep list:
# font-util (m4 macros for autoreconf) and libxkbfile (xkbfile.pc for configure).
make font-util libxkbfile $COMMON -j"$(nproc)"
make tigervnc-package     $COMMON -j"$(nproc)"

echo "==> extract + sign Xvfb (built alongside Xvnc via --enable-xvfb)"
XVFB="$(find build_stage -name Xvfb -type f 2>/dev/null | head -1)"
if [ -n "$XVFB" ]; then
  mkdir -p "$OUT"; cp -v "$XVFB" "$OUT"/Xvfb
  ldid -Sbuild_misc/entitlements/general.xml "$OUT"/Xvfb 2>/dev/null || ldid -S "$OUT"/Xvfb
  echo "   Xvfb signed -> $OUT/Xvfb"
else
  echo "!! Xvfb not found in build_stage (did --enable-xvfb apply?)"
fi

echo "==> [4/4] collect debs -> $OUT"
mkdir -p "$OUT"
found=0
for d in $(find . -name 'tigervnc-*_*.deb'); do
  cp -v "$d" "$OUT"/; found=1
done
[ "$found" = 1 ] || { echo "!! no tigervnc debs produced"; exit 1; }
echo "==> done. Verify the target shell path landed in the binary:"
tar_xvnc=".$TARGET_PREFIX/usr/bin/Xvnc"
dpkg-deb --fsys-tarfile "$OUT"/tigervnc-standalone-server_*.deb 2>/dev/null \
  | tar -xO "$tar_xvnc" 2>/dev/null \
  | grep -c "$EXPECTED_SH" | sed "s#^#   \"$EXPECTED_SH\" occurrences in Xvnc: #" || true
