#!/usr/bin/env bash
# Build LibreOffice's upstream-supported iOS static core and resource bundle.
#
# This is the engine foundation for a future Xios Writer/Calc frontend. Upstream
# intentionally omits the normal desktop GUI on iOS, so this script does not
# claim to produce a runnable LibreOffice desktop application.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/libreoffice-ios-work}"
SOURCE="${LIBREOFFICE_SOURCE:-$WORK/source}"
BUILD="${LIBREOFFICE_BUILD:-$WORK/build}"
TAG="${LIBREOFFICE_TAG:-libreoffice-25.8.7.3}"
REPOSITORY="${LIBREOFFICE_REPOSITORY:-https://git.libreoffice.org/core}"
JOBS="${JOBS:-4}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required host tool not found: $1" >&2
    exit 1
  }
}

need git
need xcrun
need shasum

GNU_MAKE="${GNU_MAKE:-/opt/homebrew/opt/make/libexec/gnubin/make}"
GPERF_DIR="${GPERF_DIR:-/opt/homebrew/opt/gperf/bin}"
PYTHON="${PYTHON:-/opt/homebrew/bin/python3.13}"
MESON_SITE="${MESON_SITE:-/opt/homebrew/lib/python3.14/site-packages}"
HOST_TOOLS="$WORK/host-tools"

[ -x "$GNU_MAKE" ] || {
  echo "ERROR: GNU Make 4 is required; install it with: brew install make" >&2
  exit 1
}
[ -x "$GPERF_DIR/gperf" ] || {
  echo "ERROR: gperf 3.1+ is required; install it with: brew install gperf" >&2
  exit 1
}
[ -x "$PYTHON" ] || {
  echo "ERROR: Homebrew Python is required: $PYTHON" >&2
  exit 1
}
[ -d "$MESON_SITE/mesonbuild" ] || {
  echo "ERROR: Meson is required; install it with: brew install meson" >&2
  exit 1
}
"$PYTHON" -c 'import xml.parsers.expat' >/dev/null || {
  echo "ERROR: $PYTHON has a broken expat module; use a working Python 3.13 build" >&2
  exit 1
}

mkdir -p "$WORK" "$OUT"
mkdir -p "$HOST_TOOLS"
cat > "$HOST_TOOLS/python3" <<EOF
#!/bin/sh
PYTHONPATH="$MESON_SITE\${PYTHONPATH:+:\$PYTHONPATH}" exec "$PYTHON" "\$@"
EOF
cat > "$HOST_TOOLS/meson" <<EOF
#!/bin/sh
PYTHONPATH="$MESON_SITE\${PYTHONPATH:+:\$PYTHONPATH}" exec "$PYTHON" -m mesonbuild.mesonmain "\$@"
EOF
chmod +x "$HOST_TOOLS/python3" "$HOST_TOOLS/meson"
MESON="$HOST_TOOLS/meson"
PYTHONPATH="$MESON_SITE${PYTHONPATH:+:$PYTHONPATH}"
export MESON PYTHONPATH
"$HOST_TOOLS/python3" -c 'import mesonbuild, xml.parsers.expat' >/dev/null || {
  echo "ERROR: the selected Python cannot load Meson and expat" >&2
  exit 1
}

if [ ! -d "$SOURCE/.git" ]; then
  git clone --filter=blob:none "$REPOSITORY" "$SOURCE"
fi
git -C "$SOURCE" fetch --quiet --tags origin "$TAG"
git -C "$SOURCE" checkout --quiet --detach "$TAG"
git -C "$SOURCE" reset --quiet --hard "$TAG"

rm -rf "$BUILD"
mkdir -p "$BUILD"

# Homebrew's pkgconf is valid here, but LibreOffice deliberately requires an
# explicit acknowledgement for unrecognized pkg-config builds. The nested
# build-platform configure needs the acknowledgement separately.
export PATH="$HOST_TOOLS:$GPERF_DIR:$(dirname "$GNU_MAKE"):$(dirname "$PYTHON"):$PATH"
export PYTHON
(
  cd "$BUILD"
  "$SOURCE/autogen.sh" \
    --with-distro=LibreOfficeiOS \
    --enable-bogus-pkg-config \
    '--with-build-platform-configure-options=--with-system-jpeg=no --enable-bogus-pkg-config'
)

if [ "${CONFIGURE_ONLY:-0}" = 1 ]; then
  echo "==> configured LibreOffice iOS in $BUILD"
  exit 0
fi

"$GNU_MAKE" -C "$BUILD" -j"$JOBS"

ARTIFACT="$OUT/libreoffice-ios-core-25.8.7.3.tar.xz"
(
  cd "$BUILD"
  tar -cJf "$ARTIFACT" \
    workdir/CustomTarget/ios \
    workdir/LinkTarget/StaticLibrary \
    instdir
)
shasum -a 256 "$ARTIFACT" > "$ARTIFACT.sha256"

echo "==> built LibreOffice iOS static core: $ARTIFACT"
echo "==> this artifact is an engine/resource foundation, not a desktop UI"
