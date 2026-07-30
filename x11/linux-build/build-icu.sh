#!/usr/bin/env bash
# Build ICU (libicu74 / libicu-dev / icu-devtools) for rootless iOS via the Procursus/Docker
# pipeline. Companion to build-gnome.sh — same preamble (recipes + build_info install, the
# cc-nounused clang wrappers) but only the icu4c target. ICU is the native-then-cross double
# build (see recipes/icu4c.mk); the native half needs the image's REAL host g++, which the
# recipe re-pins explicitly, so this driver can keep passing the darwin CC/CXX like every
# other track. Run on the GTK/GNOME volume so EDS/tracker can later link ICU from BUILD_BASE:
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/build-icu.sh:/work/build-icu.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-icu.sh
# (the image's ENTRYPOINT is /bin/bash, so the bare script path runs under bash;
#  --entrypoint sh would run it under dash and break set -o pipefail)
set -euo pipefail
# ICU_VERSION=<x.y> builds a version other than the recipe default. It must go on
# the make COMMAND LINE: recipes/icu4c.mk assigns ICU_VERSION with :=, which an
# environment variable cannot override. Qt pins 74.2 because ICU bakes its major
# version into every symbol name, while Ladybird pins 78 -- so both get built and
# coexist in out/.
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

echo "==> installing our recipes into makefiles/ (icu4c.mk replaces upstream 69.1)"
cp -v /work/recipes/*.mk makefiles/
cp -v /work/recipes/gtkintl_shim.c build_tools/ 2>/dev/null || true

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

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

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

echo "==> make icu4c-package"
make icu4c-package $COMMON ${ICU_VERSION:+ICU_VERSION="$ICU_VERSION"} -j"${JOBS:-$(nproc)}"

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libicu icu-devtools; do
  find . -name "${pat}*_*_$XIOS_DEB_ARCH.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> done"
