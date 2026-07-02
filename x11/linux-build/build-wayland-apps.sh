#!/usr/bin/env bash
# Build Wayland-native apps (foot terminal, imv image viewer) + foot's small deps (tllist, fcft)
# for rootless iOS via the Procursus/Docker pipeline, on the procursus-vol-wayland volume (which
# already has wayland/wayland-protocols/libxkbcommon/pixman/freetype/fontconfig-cascade built).
# These recipes don't exist in Procursus, so we drop ours (recipes/*.mk) into the clone
# (the main Makefile globs makefiles/*.mk); dep recipes that DO exist (harfbuzz/utf8proc/
# freetype/fontconfig/cairo/pango/...) cascade.
#
# Run in the container with procursus-vol-wayland mounted at /work/Procursus, recipes at
# /work/recipes, out at /out. Select targets via TARGETS env (default: full dependency order):
#   docker run -e TARGETS="tllist-package fcft-package" ... /work/build-wayland-apps.sh
set -euo pipefail
cd /work/Procursus

BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
BBINC="$BB/usr/include"

# Host build tools missing from this image:
#  - libwayland-bin: NATIVE wayland-scanner (protocol codegen); foot/imv run it at build time.
#  - ncurses-bin: `tic`, the terminfo compiler foot invokes to build its terminfo entries.
#  - linux-libc-dev: source of linux/input-event-codes.h (BTN_*/KEY_* codes foot/imv reference).
#  - gtk-doc-tools + libglib2.0-dev-bin/-bin: fcft's HarfBuzz (run-shaping) dep cascades
#    glib -> cairo -> harfbuzz; cairo's autoreconf runs `gtkdocize`, and the meson glib
#    consumers need native glib-mkenums/genmarshal. (imv's pangocairo needs them too.)
if ! command -v wayland-scanner >/dev/null 2>&1 || ! command -v tic >/dev/null 2>&1 \
   || ! command -v gtkdocize >/dev/null 2>&1 || ! command -v glib-mkenums >/dev/null 2>&1; then
  echo "==> installing host build tools (wayland-scanner + tic + gtk-doc + glib codegen)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      libwayland-bin ncurses-bin linux-libc-dev python3 wget \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/tllist.mk /work/recipes/fcft.mk /work/recipes/foot.mk /work/recipes/imv.mk \
      /work/recipes/libgrapheme.mk \
      /work/recipes/wayland.mk /work/recipes/wayland-protocols.mk /work/recipes/libxkbcommon.mk \
      /work/recipes/libpixman.mk makefiles/ 2>/dev/null || true

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/libtllist-dev.control \
        /work/build_info/libfcft4.control /work/build_info/libfcft-dev.control \
        /work/build_info/foot.control /work/build_info/foot-compat.h /work/build_info/imv.control \
        /work/build_info/imv-compat.h /work/build_info/libgrapheme-dev.control \
        /work/build_info/iosc-gpu-client-ent.xml build_info/ 2>/dev/null || true
fi

# The Procursus clang wrapper unconditionally injects -Wl,-adhoc_codesign. meson's compile-only
# probes add -Werror=unused-command-line-argument, so every cc.sizeof()/cc.has_header() fails
# ("'linker' input unused") and meson aborts. Route the compiler through a thin wrapper that
# appends -Wno-unused-command-line-argument (last flag wins). Same shim build-gtk.sh uses.
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

# foot/imv reference the Linux input button/key codes (BTN_LEFT/KEY_*) that the compositor sends
# via wl_pointer/wl_keyboard. The real linux/input.h drags in the linux/types.h UAPI chain, but
# they only need the code #defines, so ship the lightweight input-event-codes.h + a 1-line
# input.h shim into build_base (same approach as build-gtk.sh for the GTK4 Wayland backend).
echo "==> installing linux/input-event-codes.h shim into build_base"
mkdir -p "$BBINC/linux"
cp /usr/include/linux/input-event-codes.h "$BBINC/linux/" 2>/dev/null || true
echo '#include <linux/input-event-codes.h>' > "$BBINC/linux/input.h"

# fcft.c includes glibc's <byteswap.h> (bswap_16/32/64), absent on Darwin. Provide a shim
# mapping to the clang builtins.
if true; then
  echo "==> installing byteswap.h shim into build_base"
  cat > "$BBINC/byteswap.h" <<'EOF'
#ifndef _XIOS_BYTESWAP_H
#define _XIOS_BYTESWAP_H
#include <stdint.h>
#define bswap_16(x) __builtin_bswap16((uint16_t)(x))
#define bswap_32(x) __builtin_bswap32((uint32_t)(x))
#define bswap_64(x) __builtin_bswap64((uint64_t)(x))
#endif
EOF
fi

# The iOS 16.5 SDK ships no C11 <threads.h>; fcft and foot use the mtx_/cnd_/thrd_ subset.
# Provide a header-only shim backed by pthreads (covers exactly what they reference: no
# tss_/call_once). thrd_create needs a trampoline since C11 start fns return int, pthread void*.
if true; then
  echo "==> installing C11 threads.h shim (pthread-backed) into build_base"
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
static inline int  mtx_init(mtx_t *m, int type) {
    if (type & mtx_recursive) {
        pthread_mutexattr_t a; pthread_mutexattr_init(&a);
        pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
        int r = pthread_mutex_init(m, &a); pthread_mutexattr_destroy(&a);
        return r == 0 ? thrd_success : thrd_error;
    }
    return pthread_mutex_init(m, NULL) == 0 ? thrd_success : thrd_error;
}
static inline int  mtx_lock(mtx_t *m)    { return pthread_mutex_lock(m) == 0 ? thrd_success : thrd_error; }
static inline int  mtx_trylock(mtx_t *m) { return pthread_mutex_trylock(m) == 0 ? thrd_success : thrd_busy; }
static inline int  mtx_unlock(mtx_t *m)  { return pthread_mutex_unlock(m) == 0 ? thrd_success : thrd_error; }
static inline void mtx_destroy(mtx_t *m) { pthread_mutex_destroy(m); }
static inline int  cnd_init(cnd_t *c)               { return pthread_cond_init(c, NULL) == 0 ? thrd_success : thrd_error; }
static inline int  cnd_wait(cnd_t *c, mtx_t *m)     { return pthread_cond_wait(c, m) == 0 ? thrd_success : thrd_error; }
static inline int  cnd_signal(cnd_t *c)             { return pthread_cond_signal(c) == 0 ? thrd_success : thrd_error; }
static inline int  cnd_broadcast(cnd_t *c)          { return pthread_cond_broadcast(c) == 0 ? thrd_success : thrd_error; }
static inline void cnd_destroy(cnd_t *c)            { pthread_cond_destroy(c); }
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
static inline int  thrd_join(thrd_t t, int *res) {
    void *r; if (pthread_join(t, &r) != 0) return thrd_error;
    if (res) *res = (int)(intptr_t)r; return thrd_success;
}
static inline thrd_t thrd_current(void) { return pthread_self(); }
static inline int  thrd_equal(thrd_t a, thrd_t b) { return pthread_equal(a, b); }
static inline void thrd_exit(int res) { pthread_exit((void *)(intptr_t)res); }
#endif
EOF
fi

# The iOS SDK ships no C11 <uchar.h>; foot's char32.h needs the char16_t/char32_t typedefs
# (it operates on them via wchar_t casts, so no mbrtoc32 needed). Provide the typedefs.
if true; then
  echo "==> installing uchar.h shim into build_base"
  cat > "$BBINC/uchar.h" <<'EOF'
#ifndef _XIOS_UCHAR_H
#define _XIOS_UCHAR_H
#include <stdint.h>
#include <wchar.h>
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
/* Darwin's wchar_t is 32-bit and its multibyte conversions honour the current (UTF-8)
 * LC_CTYPE locale, so char32<->multibyte maps directly onto mbrtowc/wcrtomb. */
static inline size_t mbrtoc32(char32_t *pc32, const char *s, size_t n, mbstate_t *ps) {
    return mbrtowc((wchar_t *)pc32, s, n, ps);
}
static inline size_t c32rtomb(char *s, char32_t c32, mbstate_t *ps) {
    return wcrtomb(s, (wchar_t)c32, ps);
}
#endif
EOF
fi

# wayland-protocols was previously built at 1.38; foot 1.27 needs >=1.41. Our recipe now pins
# 1.44 — force a rebuild if the installed .pc is still older (EXTRACT_TAR won't re-extract while
# the old work dir exists, so nuke it + the stage + marker).
WP_PC="$BB/usr/share/pkgconfig/wayland-protocols.pc"
WP_VER=$(sed -n 's/^Version: //p' "$WP_PC" 2>/dev/null || true)
if [ "$WP_VER" != "1.44" ]; then
  echo "==> forcing wayland-protocols rebuild (installed='$WP_VER', want 1.44)"
  rm -rf build_work/iphoneos-arm64-rootless/1900/wayland-protocols \
         build_stage/iphoneos-arm64-rootless/1900/wayland-protocols 2>/dev/null || true
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
# Dependency order: wayland-protocols (bump) -> tllist -> fcft -> foot -> imv.
TARGETS="${TARGETS:-wayland-protocols-package tllist-package fcft-package foot-package imv-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libtllist libfcft foot imv libgrapheme wayland-protocols \
           libharfbuzz libutf8proc libfontconfig libfreetype libpixman \
           libcairo libpango libfribidi libglib2.0 libpng libjpeg; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> done"
