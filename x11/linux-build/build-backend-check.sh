#!/usr/bin/env bash
# OFF-DEVICE compile check for the MetaBackendIOS pieces (src/backends/ios/*.c). Not wired into
# meson yet; flags/includes are harvested from ninja's real compile command for
# meta-monitor-manager-dummy.c.o so a clean .o actually proves ABI compatibility.
#
#   docker run --rm --platform linux/arm64 -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/../wayland:/src:ro" procursus-xbuild:bookworm-arm64 \
#     -c 'bash /src/../linux-build/build-backend-check.sh meta-monitor-manager-ios.c'
#
# Args: one or more source basenames (in /src). Headers in /src are staged alongside.
set -euo pipefail

M=/work/Procursus/build_work/iphoneos-arm64-rootless/1900/mutter
B=$M/build
SRCDIR=${SRCDIR:-/src}
STAGE=/tmp/ios-check/backends/ios
REF_OBJ='src/libmutter-14.0.dylib.p/backends_meta-monitor-manager-dummy.c.o'
REF_SRC='../src/backends/meta-monitor-manager-dummy.c'

[ -d "$B" ] || { echo "FAIL: mutter build tree not at $B"; exit 2; }

# Stage the flat wayland/ sources into the eventual in-tree layout so that the in-tree
# include paths ("backends/ios/...") resolve against them.
rm -rf /tmp/ios-check && mkdir -p "$STAGE"
cp "$SRCDIR"/*.h "$STAGE"/ 2>/dev/null || true
if [ -f "$SRCDIR/out/xios-glue-include/xios_surface.h" ]; then
  cp "$SRCDIR/out/xios-glue-include/xios_surface.h" "$STAGE/"
fi
if [ -f "$SRCDIR/out/xios-glue-include/XiosProtocol.h" ]; then
  cp "$SRCDIR/out/xios-glue-include/XiosProtocol.h" "$STAGE/"
fi
if [ -f "$SRCDIR/out/xios-glue-include/xios_metal_sync.h" ]; then
  cp "$SRCDIR/out/xios-glue-include/xios_metal_sync.h" "$STAGE/"
fi

# The MetaBackendIOS files intentionally compile against xios-glue-stub.h, while
# libxios_glue ships canonical headers. Catch contract drift before compiling so a
# stale stub cannot quietly type-check against a different API.
python3 - "$STAGE" <<'PY'
import pathlib
import re
import sys

stage = pathlib.Path(sys.argv[1])
stub_path = stage / "xios-glue-stub.h"
input_path = stage / "xios_input_socket.h"
egl_path = stage / "xios_egl.h"
surface_path = stage / "xios_surface.h"
metal_sync_path = stage / "xios_metal_sync.h"

if not stub_path.exists():
    raise SystemExit("FAIL: xios-glue-stub.h was not staged")

stub = stub_path.read_text()

def read_optional(path):
    return path.read_text() if path.exists() else ""

def prototype_map(text, names):
    collapsed = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    collapsed = re.sub(r"\s+", " ", collapsed)
    out = {}
    for name in names:
        m = re.search(r"([A-Za-z_][A-Za-z0-9_\s\*]*\b" + re.escape(name) +
                      r"\s*\([^;]*\));", collapsed)
        if m:
            proto = re.sub(r"\s+", " ", m.group(1)).strip()
            proto = proto.replace(" *", "*").replace("* ", "*")
            proto = re.sub(r"\s+\(", "(", proto)
            out[name] = proto
    return out

errors = []

if input_path.exists():
    input_text = input_path.read_text()
    names = [
        "xios_input_socket_new",
        "xios_input_socket_fd",
        "xios_input_socket_dispatch",
        "xios_input_socket_broadcast",
        "xios_input_socket_client_count",
        "xios_input_socket_free",
    ]
    if prototype_map(stub, names) != prototype_map(input_text, names):
        errors.append("xios_input_socket_* prototypes differ between stub and canonical header")

egl_text = read_optional(egl_path)
if egl_text:
    names = [
        "xios_egl_display",
        "xios_egl_config",
        "xios_egl_create_iosurface_pbuffer",
        "xios_egl_image_from_iosurface",
        "xios_egl_destroy_image",
        "xios_output_geometry",
        "xios_output_scale",
    ]
    missing = sorted(set(prototype_map(egl_text, names)) - set(prototype_map(stub, names)))
    if missing:
        errors.append("xios-glue-stub.h is missing canonical xios_egl.h prototypes: " + ", ".join(missing))

surface_text = read_optional(surface_path)
if surface_text:
    names = [
        "xios_surface_create",
        "xios_surface_resize",
        "xios_server_start",
        "xios_server_stop",
        "xios_set_clipboard_socket",
        "xios_get_output_iosurface",
        "xios_notify_dirty_with_fence",
    ]
    missing = sorted(set(prototype_map(surface_text, names)) - set(prototype_map(stub, names)))
    if missing:
        errors.append("xios-glue-stub.h is missing canonical xios_surface.h prototypes: " + ", ".join(missing))

metal_sync_text = read_optional(metal_sync_path)
if metal_sync_text:
    names = [
        "xios_metal_sync_signal",
        "xios_metal_sync_import_event",
        "xios_metal_sync_release_event",
        "xios_metal_sync_wait",
    ]
    missing = sorted(set(prototype_map(metal_sync_text, names)) - set(prototype_map(stub, names)))
    if missing:
        errors.append("xios-glue-stub.h is missing canonical xios_metal_sync.h prototypes: " + ", ".join(missing))

if errors:
    print("FAIL: xios glue contract drift detected", file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    raise SystemExit(1)

print("==> xios glue contract check: OK")
PY

# Generate wayland server-protocol headers from any real protocol .xml in /src (skip the
# codesign entitlement plists that share the .xml extension). Uses the native (Linux) scanner
# the W0 wayland track built into the volume.
NATIVE_SCANNER=/work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland/native-root/bin/wayland-scanner
for xml in "$SRCDIR"/*.xml; do
  [ -f "$xml" ] || continue
  grep -q "<protocol" "$xml" || continue
  base=$(basename "${xml%.xml}")
  if [ -x "$NATIVE_SCANNER" ] && "$NATIVE_SCANNER" server-header "$xml" \
       "$STAGE/$base-server-protocol.h" 2>/dev/null; then
    echo "==> scanned $base-server-protocol.h"
  fi
done

# Harvest mutter's own compile command for a backend object (exact flags + includes).
cd "$B"
BASECMD=$(ninja -t commands "$REF_OBJ" 2>/dev/null | tail -1)
[ -n "$BASECMD" ] || { echo "FAIL: could not harvest compile command from ninja"; exit 2; }

rc=0
for src in "$@"; do
  cp "$SRCDIR/$src" "$STAGE/$src"
  obj="/tmp/ios-check/${src%.c}.o"
  cmd=$(printf '%s' "$BASECMD" \
        | sed "s#$REF_OBJ#$obj#g; s#$REF_SRC#$STAGE/$src#g")
  # Prepend the stage dir so backends/ios/*.h resolve; keep all real -I flags
  # after it. The copied Apple SDK headers are incomplete from Clang's
  # nullability/Swift-importer perspective and otherwise emit hundreds of
  # warnings per source, hiding useful backend diagnostics. Suppress only that
  # inherited SDK noise; Mutter's own strict warning/error flags remain intact.
  cmd=${cmd/ / -I/tmp/ios-check }
  cmd="$cmd -Wno-nullability-completeness -Wno-undef -Wno-expansion-to-defined"
  echo "==> compile-check: $src"
  if eval "$cmd" && [ -f "$obj" ]; then
    echo "    OK  -> $(basename "$obj") ($(wc -c < "$obj") bytes)"
  else
    echo "    FAIL: $src did not compile clean"
    rc=1
  fi
done

exit $rc
