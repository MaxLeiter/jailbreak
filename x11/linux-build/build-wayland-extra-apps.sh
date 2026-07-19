#!/usr/bin/env bash
# Build the second wave of Wayland/GTK desktop apps for rootless iOS.
#
# This driver is intentionally opt-in and separate from build-wayland-apps.sh:
# the first app wave owns foot/imv/mpv and their runtime fixes, while this
# script is for smaller shell utilities and user apps such as swaybg, tofi,
# yad, gnumeric, and transmission. Built but heavier targets such as waybar and
# swayimg remain opt-in; nwg-look and Geary/WebKitGTK are explicitly blocked.
#
# Typical use:
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-gtk-calc:/work/Procursus \
#     -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
#     -v "$PWD/linux-build/recipes:/work/recipes:ro" \
#     -v "$PWD/ports:/work/ports:ro" \
#     -v "$PWD/linux-build/build_info:/work/build_info:ro" \
#     -v "$PWD/linux-build/out:/out" \
#     -e TARGETS="swaybg-package tofi-package" \
#     procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
set -euo pipefail
cd /work/Procursus

BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
BBINC="$BB/usr/include"

TARGETS="${TARGETS:-swaybg-package tofi-package yad-package libgsf-package libxslt-package goffice-package gnumeric-package transmission-package}"

target_requests() {
  [[ " $TARGETS " == *" $1"* ]]
}

target_needs_gtk3_wayland() {
  target_requests gtk+3.0 || target_requests gtk-layer-shell || target_requests waybar
}

stage_port_patch_stack() {
  local pkg="$1"
  [ -d "/work/ports/$pkg/patches" ] || return 0
  echo "==> staging $pkg source patches"
  bash /work/recipes/stage-port-patches.sh "$pkg" /work/ports build_patch
}

echo "==> installing host build tools"
apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  cmake gettext gperf gtk-doc-tools intltool itstool libglib2.0-bin libglib2.0-dev-bin \
  libgdk-pixbuf2.0-bin libwayland-bin libxml2-utils linux-libc-dev ninja-build \
  desktop-file-utils appstream gtk-update-icon-cache python3 wget >/dev/null 2>&1 \
  || { echo "ERROR: could not install host build tools"; exit 1; }

echo "==> installing our recipes into makefiles/"
cp /work/recipes/*.mk makefiles/ 2>/dev/null || true
cp /work/recipes/gtkintl_shim.c build_tools/ 2>/dev/null || true

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp /work/build_info/* build_info/ 2>/dev/null || true
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true
fi

for pkg in swaybg tofi swayimg waybar yad nwg-look geary webkitgtk gnumeric transmission libsigcplusplus; do
  target_requests "$pkg" && stage_port_patch_stack "$pkg"
done
target_needs_gtk3_wayland && stage_port_patch_stack gtk+3.0

echo "==> installing -Wno-unused-command-line-argument clang wrappers"
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# Several Wayland clients include Linux input code definitions for BTN_/KEY_
# constants. The values are protocol payloads, so the lightweight UAPI header
# is enough and avoids dragging Linux types into Darwin.
echo "==> installing linux/input-event-codes.h shim into build_base"
mkdir -p "$BBINC/linux"
cp /usr/include/linux/input-event-codes.h "$BBINC/linux/" 2>/dev/null || true
echo '#include <linux/input-event-codes.h>' > "$BBINC/linux/input.h"

# The iOS SDK lacks C11 <threads.h>; small Wayland clients such as tofi use the
# mtx_/cnd_/thrd_ subset. Match the shim used by the first app-wave driver.
echo "==> installing C11 threads.h shim into build_base"
cat > "$BBINC/threads.h" <<'EOF'
#ifndef _XIOS_THREADS_H
#define _XIOS_THREADS_H
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
typedef pthread_mutex_t mtx_t;
typedef pthread_cond_t  cnd_t;
typedef pthread_t       thrd_t;
typedef int (*thrd_start_t)(void *);
enum { mtx_plain = 0, mtx_recursive = 1, mtx_timed = 2 };
enum { thrd_success = 0, thrd_error = 1, thrd_nomem = 2, thrd_timedout = 3, thrd_busy = 4 };
static inline int mtx_init(mtx_t *m, int type) {
  if (type & mtx_recursive) {
    pthread_mutexattr_t a; pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    int r = pthread_mutex_init(m, &a); pthread_mutexattr_destroy(&a);
    return r == 0 ? thrd_success : thrd_error;
  }
  return pthread_mutex_init(m, NULL) == 0 ? thrd_success : thrd_error;
}
static inline int  mtx_lock(mtx_t *m) { return pthread_mutex_lock(m) == 0 ? thrd_success : thrd_error; }
static inline int  mtx_trylock(mtx_t *m) { return pthread_mutex_trylock(m) == 0 ? thrd_success : thrd_busy; }
static inline int  mtx_unlock(mtx_t *m) { return pthread_mutex_unlock(m) == 0 ? thrd_success : thrd_error; }
static inline void mtx_destroy(mtx_t *m) { pthread_mutex_destroy(m); }
static inline int  cnd_init(cnd_t *c) { return pthread_cond_init(c, NULL) == 0 ? thrd_success : thrd_error; }
static inline int  cnd_wait(cnd_t *c, mtx_t *m) { return pthread_cond_wait(c, m) == 0 ? thrd_success : thrd_error; }
static inline int  cnd_signal(cnd_t *c) { return pthread_cond_signal(c) == 0 ? thrd_success : thrd_error; }
static inline int  cnd_broadcast(cnd_t *c) { return pthread_cond_broadcast(c) == 0 ? thrd_success : thrd_error; }
static inline void cnd_destroy(cnd_t *c) { pthread_cond_destroy(c); }
struct _xios_thrd_pack { thrd_start_t f; void *a; };
static inline void *_xios_thrd_trampoline(void *p) {
  struct _xios_thrd_pack pk = *(struct _xios_thrd_pack *)p; free(p);
  return (void *)(intptr_t)pk.f(pk.a);
}
static inline int thrd_create(thrd_t *t, thrd_start_t f, void *a) {
  struct _xios_thrd_pack *pk = (struct _xios_thrd_pack *)malloc(sizeof *pk);
  if (!pk) return thrd_nomem;
  pk->f = f; pk->a = a;
  return pthread_create(t, NULL, _xios_thrd_trampoline, pk) == 0 ? thrd_success : thrd_error;
}
static inline int thrd_join(thrd_t t, int *res) {
  void *r; if (pthread_join(t, &r) != 0) return thrd_error;
  if (res) *res = (int)(intptr_t)r; return thrd_success;
}
static inline thrd_t thrd_current(void) { return pthread_self(); }
static inline int thrd_equal(thrd_t a, thrd_t b) { return pthread_equal(a, b); }
static inline void thrd_exit(int res) { pthread_exit((void *)(intptr_t)res); }
#endif
EOF

# The iOS SDK also lacks C11 <uchar.h>. Darwin wchar_t is 32-bit, so the
# multibyte conversion helpers can map through mbrtowc/wcrtomb.
echo "==> installing uchar.h shim into build_base"
cat > "$BBINC/uchar.h" <<'EOF'
#ifndef _XIOS_UCHAR_H
#define _XIOS_UCHAR_H
#include <stdint.h>
#include <wchar.h>
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
static inline size_t mbrtoc32(char32_t *pc32, const char *s, size_t n, mbstate_t *ps) {
  return mbrtowc((wchar_t *)pc32, s, n, ps);
}
static inline size_t c32rtomb(char *s, char32_t c32, mbstate_t *ps) {
  return wcrtomb(s, (wchar_t)c32, ps);
}
#endif
EOF

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

refresh_patch_build_tree() {
  local pkg="$1"
  local patch_dir="/work/ports/$pkg/patches"
  [ -d "$patch_dir" ] || return 0
  local work="build_work/iphoneos-arm64-rootless/1900/$pkg"
  local stage="build_stage/iphoneos-arm64-rootless/1900/$pkg"
  local fp_file="$work/.xios_patch_series.sha256"
  local new_fp old_fp
  new_fp="$(find "$patch_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  old_fp="$(cat "$fp_file" 2>/dev/null || true)"
  if [ -d "$work" ] && [ "$new_fp" != "$old_fp" ]; then
    echo "==> wiping stale $pkg build after patch changes"
    rm -rf "$work" "$stage"
  fi
}

record_patch_fingerprint() {
  local pkg="$1"
  local patch_dir="/work/ports/$pkg/patches"
  local work="build_work/iphoneos-arm64-rootless/1900/$pkg"
  [ -d "$patch_dir" ] && [ -d "$work" ] || return 0
  find "$patch_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}' > "$work/.xios_patch_series.sha256"
}

ensure_gtk3_wayland_build() {
  target_needs_gtk3_wayland || return 0

  local hdr="$BB/usr/include/gtk-3.0/gdk/gdkwayland.h"
  local pc="$BB/usr/lib/pkgconfig/gdk-wayland-3.0.pc"
  if [ -f "$hdr" ] && [ -f "$pc" ]; then
    return 0
  fi

  echo "==> stale gtk+3.0 cache lacks Wayland backend; rebuilding gtk+3.0"
  echo "    missing: $hdr or $pc"
  rm -rf \
    build_work/iphoneos-arm64-rootless/1900/gtk+3.0 \
    build_stage/iphoneos-arm64-rootless/1900/gtk+3.0 \
    build_dist/iphoneos-arm64-rootless/1900/libgtk-3-0 \
    build_dist/iphoneos-arm64-rootless/1900/libgtk-3-dev \
    build_dist/iphoneos-arm64-rootless/1900/gtk-3-bin
}

scrub_waybar_fallback_deps() {
  target_requests waybar || return 0

  echo "==> scrubbing stale waybar fallback deps from build_base"
  rm -f \
    "$BB/usr/lib/pkgconfig/fmt.pc" \
    "$BB/usr/lib/pkgconfig/spdlog.pc" \
    "$BB/usr/lib/pkgconfig/jsoncpp.pc" \
    "$BB/usr/lib/libfmt.a" \
    "$BB/usr/lib/libspdlog.a" \
    "$BB/usr/lib/libjsoncpp.a"
  rm -rf \
    "$BB/usr/include/fmt" \
    "$BB/usr/include/spdlog" \
    "$BB/usr/include/json"
}

for pkg in swaybg tofi swayimg waybar transmission libsigcplusplus; do
  target_requests "$pkg" && refresh_patch_build_tree "$pkg"
done
ensure_gtk3_wayland_build
scrub_waybar_fallback_deps

for t in $TARGETS; do
  echo "==> make $t"
  make "$t" $COMMON -j"$(nproc)"
done
for pkg in swaybg tofi swayimg waybar transmission libsigcplusplus; do
  target_requests "$pkg" && record_patch_fingerprint "$pkg"
done

echo "==> collect debs -> /out"
mkdir -p /out
OUT_STAGING="$(mktemp -d /tmp/xios-wayland-extra-out.XXXXXX)"
trap 'rm -rf "$OUT_STAGING"' EXIT
for spec in \
  swaybg:swaybg \
  tofi:tofi \
  swayimg:swayimg \
  waybar:waybar \
  yad:yad \
  nwg-look:nwg-look \
  geary:geary \
  webkitgtk:webkitgtk \
  gnumeric:gnumeric \
  transmission:transmission \
  libgsf:libgsf \
  libxslt:libxslt \
  libgoffice:goffice \
  luajit:luajit \
  libsigc++:libsigcplusplus \
  libglibmm:glibmm \
  libcairomm:cairomm \
  libpangomm:pangomm \
  libatkmm:atkmm \
  libgtkmm:gtkmm3 \
  libgtk-3-0:gtk+3.0 \
  libgtk-3-dev:gtk+3.0 \
  gtk-3-bin:gtk+3.0 \
  libgtkintl:gtk+3.0 \
  libgtk-layer-shell:gtk-layer-shell \
  libstemmer:libstemmer \
  libytnef:libytnef \
  libgmime:gmime \
  libgspell:gspell \
  libpeas:libpeas; do
  pat="${spec%%:*}"
  req="${spec#*:}"
  target_requests "$req" || continue
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} "$OUT_STAGING"/ \; 2>/dev/null || true
done

if [ -f /work/recipes/relink-gtkintl.sh ]; then
  echo "==> shared libgtkintl relink pass for collected debs"
  bash /work/recipes/relink-gtkintl.sh "$OUT_STAGING" || true
fi

cp -v "$OUT_STAGING"/*.deb /out/ 2>/dev/null || true

echo "==> done"
