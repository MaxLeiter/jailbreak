#!/usr/bin/env bash
# Build the XFCE 4.16 desktop package chain for rootless iOS.
#
# Run inside the Procursus cross-build image on the GTK-warmed volume:
#
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/linux-build/build-xfce.sh:/work/build-xfce.sh:ro" \
#     -v "$PWD/linux-build/recipes:/work/recipes:ro" \
#     -v "$PWD/linux-build/build_info:/work/build_info:ro" \
#     -v "$PWD/linux-build/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-xfce.sh
#
# Set TARGETS to probe a smaller prefix, for example:
#   TARGETS="dbus-package libxfce4util-package xfconf-package"
set -euo pipefail
cd /work/Procursus

if ! command -v intltoolize >/dev/null 2>&1 || ! command -v glib-mkenums >/dev/null 2>&1; then
  echo "==> installing XFCE host build tools"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
    autoconf automake libtool intltool gettext gtk-doc-tools \
    libglib2.0-dev libglib2.0-dev-bin libglib2.0-bin pkg-config \
    desktop-file-utils >/dev/null 2>&1 \
    || { echo "ERROR: could not install XFCE host build tools" >&2; exit 1; }
fi

echo "==> installing Xios recipes and package controls"
cp -v /work/recipes/*.mk makefiles/
cp -v /work/recipes/gtkintl_shim.c build_tools/ 2>/dev/null || true
if [ -d /work/build_info ] && compgen -G '/work/build_info/*' >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

TARGETS="${TARGETS:-\
  dbus-package \
  libxfce4util-package xfconf-package \
  libwnck3-package libxfce4ui-package exo-package garcon-package \
  thunar-package xfwm4-package xfdesktop-package xfce4-panel-package \
  xfce4-session-package xfce4-settings-package xfce4-appfinder-package}"

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused \
  CXX=/work/Procursus/build_tools/cxx-nounused"

for target in $TARGETS; do
  echo "==> make $target"
  make "$target" $COMMON -j"$(nproc)"
done

echo "==> collecting XFCE debs into /out"
mkdir -p /out
for package in \
  dbus libxfce4util7 xfconf libwnck-3-0 libxfce4ui-2-0 libexo-2-0 \
  libgarcon-1-0 thunar xfwm4 xfdesktop4 xfce4-panel xfce4-session \
  xfce4-settings xfce4-appfinder; do
  find . -name "${package}_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out || true
echo "==> XFCE build complete"
