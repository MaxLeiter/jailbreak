#!/bin/bash
# Build upstream google/angle (GLES-via-Metal) for arm64 iOS as plain dylibs.
# Reconstructed 2026-07-01 from the live /private/tmp/angle-ios-build tree that produced
# angle_2.1.0+git20260630.a32d31d (args.gn + local diff + build.log captured verbatim);
# previously this build existed only as prose in docs/hwgl-plan.md.
#
# Produces out/ios-arm64/libEGL.framework/libEGL + libGLESv2.framework/libGLESv2
# (gn insists on the framework layout; packaging flattens them to plain dylibs).
# Then run package-angle-es3.sh to stage + build the deb into linux-build/out/.
#
# Runs on the Mac (needs Xcode + network). ~10GB of Chromium tooling on first sync.
set -euo pipefail

PORTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ANGLE_ROOT:-/private/tmp/angle-ios-build}"
# The commit the shipped deb was built from; bump deliberately, then re-check the
# patches still apply and re-version the deb (2.1.0+git<date>.<shortrev>).
ANGLE_REV=a32d31d2f1230711f398ff4cbfc272bdcca72a5e

mkdir -p "$ROOT"
cd "$ROOT"

# 1. depot_tools (gclient/gn/autoninja live here)
if [ ! -d depot_tools ]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$ROOT/depot_tools:$PATH"

# 2. angle checkout, pinned
if [ ! -d angle/.git ]; then
  mkdir -p angle
  git -C angle init
  git -C angle remote add origin https://chromium.googlesource.com/angle/angle
fi
git -C angle fetch origin "$ANGLE_REV"
git -C angle checkout --force "$ANGLE_REV"

cd angle

# 3. bootstrap + gclient sync (the long part: pulls build/, third_party clang/rust,
#    flex/bison, dsymutil via hooks — see build.log in the original tree)
python3 scripts/bootstrap.py
gclient sync -r "$ANGLE_REV"

# 4. iOS patches (tracked in ports/angle/patches/):
#    - framework->dylib dispatch: BUILD.gn ANGLE_DISPATCH_LIBRARY gets a literal
#      ".dylib" name; system_utils.cpp takes concrete .dylib names verbatim (skips
#      the iOS .framework/name mangling); system_utils_posix.cpp resolves ModuleDir
#      from /var/jb/lib/angle (ANGLE_FRAMEWORK_PATH overrides) instead of
#      <exe>/Frameworks — CLI/daemon consumers have no app bundle.
#    - metal-es3-apple3: DisplayMtl getMaxSupportedESVersion admits Apple GPU
#      Family 3 (A10) to ES3 so GDK 4.14's GL renderer gets an ES3 config.
git checkout -- BUILD.gn src/common src/libANGLE 2>/dev/null || true
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  set -- $line
  [ "$#" -gt 0 ] || continue
  p="$PORTDIR/patches/$1"
  [ -f "$p" ] || { echo "ERROR: ANGLE series entry is missing: $p" >&2; exit 1; }
  echo "== applying $(basename "$p")"
  git apply "$p"
done < "$PORTDIR/patches/series"

# 5. gn args — byte-for-byte what built the shipped deb. GOTCHAS baked in:
#    is_component_build=false (BUILDCONFIG.gn hard-asserts on iOS),
#    ios_enable_code_signing=false (we ldid-sign at packaging),
#    Metal-only backend set, tests off.
mkdir -p out/ios-arm64
cat > out/ios-arm64/args.gn <<'EOF'
target_os = "ios"
target_environment = "device"
target_cpu = "arm64"
ios_deployment_target = "15.0"
ios_enable_code_signing = false
is_debug = false
is_component_build = false
angle_enable_metal = true
angle_enable_vulkan = false
angle_enable_gl = false
angle_enable_d3d11 = false
angle_enable_null = false
angle_enable_swiftshader = false
angle_enable_essl = true
angle_enable_glsl = true
angle_build_tests = false
treat_warnings_as_errors = false
EOF

gn gen out/ios-arm64
autoninja -C out/ios-arm64 libEGL libGLESv2

echo "== built:"
ls -la out/ios-arm64/libEGL.framework/libEGL out/ios-arm64/libGLESv2.framework/libGLESv2
echo "== now package: $PORTDIR/package-angle-es3.sh"
