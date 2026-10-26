#!/usr/bin/env bash
# build-exiv2.sh - build libexiv2-28 + libexiv2-dev (recipes/exiv2.mk) on its own.
# build-kde-apps.sh also builds exiv2 but requires the Qt/KF6 stack in the volume; exiv2 itself
# needs only cmake + the base sysroot, so this driver works on any warmed Procursus volume
# (built on procursus-vol-gtk-calc). Run from x11/linux-build:
#
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-gtk-calc:/work/Procursus \
#     -v "$PWD/target-env.sh:/work/target-env.sh:ro" \
#     -v "$PWD/build-exiv2.sh:/work/build-exiv2.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" -v "$PWD/build_info:/work/build_info:ro" \
#     -v "$PWD/out:/out" procursus-xbuild:bookworm-arm64 /work/build-exiv2.sh
# scratch driver: exiv2 only (the KDE app driver needs Qt, absent on this volume)
set -euo pipefail
. /work/target-env.sh
cd /work/Procursus
cat > build_tools/cc-nounused <<'EOT'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOT
cat > build_tools/cxx-nounused <<'EOT'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOT
chmod +x build_tools/cc-nounused build_tools/cxx-nounused
cp -v /work/recipes/exiv2.mk makefiles/
cp -v /work/build_info/* build_info/ 2>/dev/null || true
mkdir -p build_misc/entitlements; cp /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true
COMMON="$XIOS_MEMO_ARGS NO_PGP=1 CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
make exiv2-package $COMMON -j"$(nproc)"
mkdir -p /out
find build_dist/$XIOS_TRIPLE/exiv2 -name '*.deb' -exec cp -v {} /out/ \;
