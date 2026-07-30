#!/usr/bin/env bash
# Build one or more Procursus make targets for a selected Xios target descriptor.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
. "$HERE/target-lib.sh"

usage() {
  cat >&2 <<EOF
usage: $0 [target-id] [--dry-run] [--skip-image-build] make-target...

  target-id            Target descriptor from linux-build/targets/ (default: rootless-1900)
  make-target          Procursus make target, e.g. glib2.0-package
  --dry-run            Print the docker commands without running them
  --skip-image-build   Use an existing XIOS_PROC_IMAGE instead of running docker build
EOF
}

TARGET="${XIOS_TARGET:-rootless-1900}"
DRY_RUN=0
SKIP_IMAGE_BUILD="${XIOS_SKIP_IMAGE_BUILD:-0}"
MAKE_TARGETS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-image-build) SKIP_IMAGE_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; MAKE_TARGETS+=("$@"); break ;;
    -*)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ "${#MAKE_TARGETS[@]}" = 0 ] && [ "$1" != *-package ] && [ -f "$HERE/targets/$1.env" ]; then
        TARGET="$1"
      elif [ "${#MAKE_TARGETS[@]}" = 0 ] && [ -f "$HERE/targets/$1.env" ]; then
        TARGET="$1"
      else
        MAKE_TARGETS+=("$1")
      fi
      ;;
  esac
  shift
done

if [ "${#MAKE_TARGETS[@]}" = 0 ]; then
  echo "missing make target" >&2
  usage
  exit 2
fi

xios_load_target "$TARGET"

IMAGE="${XIOS_PROC_IMAGE:-procursus-xbuild:bookworm-arm64}"
VOLUME="${PROCURSUS_VOL:-procursus-vol}"
SDK_SRC="${SDK_SRC:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"
MACOS_SDK_SRC="${MACOS_SDK_SRC:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"

run_cmd() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

if [ "$DRY_RUN" != 1 ]; then
  command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
  docker info >/dev/null 2>&1 || { echo "Docker daemon not running; start Docker Desktop first." >&2; exit 1; }
  [ -d "$SDK_SRC" ] || { echo "iOS SDK not found at $SDK_SRC (set SDK_SRC=...)." >&2; exit 1; }
  [ -n "$MACOS_SDK_SRC" ] && [ -d "$MACOS_SDK_SRC" ] || {
    echo "macOS SDK not found (set MACOS_SDK_SRC=...)." >&2
    exit 1
  }
fi

echo "==> target: $XIOS_TARGET_ID ($XIOS_MEMO_TARGET / CFVER $XIOS_MEMO_CFVER)"
echo "==> make targets: ${MAKE_TARGETS[*]}"

if [ "$DRY_RUN" != 1 ]; then
  echo "==> staging SDK into build context"
  mkdir -p sdk out
  if [ ! -d sdk/iPhoneOS.sdk ]; then
    rsync -a --delete "$SDK_SRC/" sdk/iPhoneOS.sdk/
  fi
  if [ ! -d sdk/MacOSX.sdk ]; then
    rsync -a --delete "$MACOS_SDK_SRC/" sdk/MacOSX.sdk/
  fi

  if [ "$SKIP_IMAGE_BUILD" != 1 ]; then
    echo "==> ensuring toolchain image exists"
  else
    echo "==> skipping image build; using existing $IMAGE"
  fi
fi
if [ "$SKIP_IMAGE_BUILD" != 1 ]; then
  run_cmd docker build --platform linux/arm64 -t "$IMAGE" .
fi

run_cmd docker run --rm --platform linux/arm64 \
  -e XIOS_TARGET_ID \
  -e XIOS_MEMO_TARGET \
  -e XIOS_MEMO_CFVER \
  -e XIOS_PREFIX \
  -e XIOS_SUBPREFIX \
  -e PATH="/root/cctools/bin:/work/Procursus/build_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e LD_LIBRARY_PATH="/root/cctools/lib" \
  -v "$VOLUME:/work/Procursus" \
  -v "$HERE/target-env.sh:/work/target-env.sh:ro" \
  -v "$HERE/out:/out" \
  --entrypoint bash "$IMAGE" -lc '
set -euo pipefail
cd /work/Procursus
rm -f /usr/local/bin/aarch64-apple-darwin-clang /usr/local/bin/aarch64-apple-darwin-clang++
find /root/cctools/bin -maxdepth 1 -type f -name "aarch64-apple-darwin-*" \
  ! -name "aarch64-apple-darwin-clang" \
  -exec ln -sf {} /usr/local/bin/ \;
cat >/usr/local/bin/aarch64-apple-darwin-clang <<SH
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
  case "\$arg" in
    -Werror=unused-command-line-argument|-Werror=ignored-optimization-argument)
      ;;
    *)
      args+=("\$arg")
      ;;
  esac
done
exec /root/cctools/bin/aarch64-apple-darwin-clang "\${args[@]}"
SH
chmod +x /usr/local/bin/aarch64-apple-darwin-clang
ln -sf /usr/local/bin/aarch64-apple-darwin-clang /usr/local/bin/aarch64-apple-darwin-clang++
ln -sf /root/cctools/bin/ldid /usr/local/bin/ldid 2>/dev/null || true
ln -sf /root/cctools/bin/lipo /usr/local/bin/lipo 2>/dev/null || true
python3 - <<PY
from pathlib import Path

path = Path("makefiles/pcre2.mk")
lines = path.read_text().splitlines(True)
needle = "\t\t--enable-pcre2grep-libbz2 " + chr(92) + "\n"
for i, line in enumerate(lines):
    if line == needle:
        lines[i] = "\t\t--enable-pcre2grep-libbz2\n"
        path.write_text("".join(lines))
        print("patched makefiles/pcre2.mk")
        break
PY
make "$@" MEMO_TARGET="$XIOS_MEMO_TARGET" MEMO_CFVER="$XIOS_MEMO_CFVER" NO_PGP=1 -j"$(nproc)"
dest="/out/targets/$XIOS_TARGET_ID"
mkdir -p "$dest"
for target in "$@"; do
  project="${target%-package}"
  dir="build_dist/$XIOS_MEMO_TARGET/$XIOS_MEMO_CFVER/$project"
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -type f -name "*.deb" -exec cp -v {} "$dest/" \;
  fi
done
' bash "${MAKE_TARGETS[@]}"
