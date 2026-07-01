#!/bin/bash
# Compile-check: validate ioscpanel.c + generated protocol code cross-compile to
# an iOS arm64 object. Run INSIDE procursus-xbuild with /work = this dir.
set -e
CC=/root/cctools/bin/aarch64-apple-darwin-clang
SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
cd /work

echo "### installing wayland-scanner + headers (apt) ###"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq libwayland-bin libwayland-dev wayland-protocols >/dev/null
echo "wayland-scanner: $(wayland-scanner --version 2>&1)"
echo "libwayland-dev: $(dpkg -query -W -f='${Version}' libwayland-dev 2>/dev/null || dpkg -s libwayland-dev | grep ^Version)"

echo "### wayland-scanner codegen ###"
mkdir -p gen
wayland-scanner client-header protocols/wlr-layer-shell-unstable-v1.xml \
    gen/wlr-layer-shell-unstable-v1-client-protocol.h
wayland-scanner private-code  protocols/wlr-layer-shell-unstable-v1.xml \
    gen/wlr-layer-shell-unstable-v1-protocol.c
wayland-scanner client-header protocols/wlr-foreign-toplevel-management-unstable-v1.xml \
    gen/wlr-foreign-toplevel-management-unstable-v1-client-protocol.h
wayland-scanner private-code  protocols/wlr-foreign-toplevel-management-unstable-v1.xml \
    gen/wlr-foreign-toplevel-management-unstable-v1-protocol.c
# xdg-shell client header is needed because layer-shell references xdg_popup
wayland-scanner client-header protocols/xdg-shell.xml gen/xdg-shell-client-protocol.h
wayland-scanner private-code  protocols/xdg-shell.xml gen/xdg-shell-protocol.c
echo "generated:"; ls -1 gen/

echo "### isolate wayland headers (don't pull Linux glibc /usr/include) ###"
mkdir -p gen/wlinc
cp /usr/include/wayland-*.h gen/wlinc/
ls gen/wlinc/

echo "### cross-compile to iOS arm64 objects ###"
# -Igen/wlinc gives the wayland headers; libc/sys headers come from the iOS SDK.
CFLAGS="-arch arm64 -isysroot $SDK -Igen -Igen/wlinc -Wall -Wextra -O2 -std=gnu11"
# (the generated protocol .c are plain C; compile each, then the client)
$CC $CFLAGS -c gen/wlr-layer-shell-unstable-v1-protocol.c -o gen/layer.o
$CC $CFLAGS -c gen/wlr-foreign-toplevel-management-unstable-v1-protocol.c -o gen/ftm.o
$CC $CFLAGS -c gen/xdg-shell-protocol.c -o gen/xdg.o
$CC $CFLAGS -c ioscpanel.c    -o gen/ioscpanel.o      # uses shell-draw.h
$CC $CFLAGS -c ioscoverview.c -o gen/ioscoverview.o   # uses shell-draw.h
echo "### OK: objects built (both clients) ###"
ls -la gen/*.o
echo
echo "### symbol sanity (unresolved wl_* are expected; resolved at link w/ W0 libwayland-client) ###"
/root/cctools/bin/aarch64-apple-darwin-nm gen/ioscpanel.o 2>/dev/null | grep -E "U _wl_|U _zwlr" | head -8 || true
echo "### note: final LINK needs the W0 libwayland-client.dylib (iOS), not apt's Linux .so ###"
