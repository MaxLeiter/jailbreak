#!/usr/bin/env bash
# Reproducible cross-build of the fff fuzzy-file-finder native C-ABI library
# (libfff_c.dylib) for jailbroken iOS (rootless / palera1n, Procursus at /var/jb).
#
# opencode's file search prefers @ff-labs/fff-bun (fast fuzzy file + content
# search) over the ripgrep fallback, but only when fff-bun can dlopen its native
# Rust cdylib. Upstream ships only desktop artifacts; a macOS dylib will not load
# on iOS. This script builds the matching fff-c crate for aarch64-apple-ios so
# fff-bun's loader can resolve it on the A10 iPad.
#
# ABI: the exported C surface must match @ff-labs/fff-bun@0.9.4 (src/ffi.ts).
# We pin the fff source tag 0.9.4-nightly.6d5576e, whose crates/fff-c is version
# 0.9.4 and exports a superset of every symbol fff-bun 0.9.4 dlopens.
#
# The one wall is LMDB locking: heed -> lmdb-master-sys defaults to System V
# semaphores (semget/semop) on Apple targets, and iOS kills those syscalls with
# SIGSYS. We force LMDB onto POSIX named semaphores (sem_open, permitted on iOS)
# by injecting -DMDB_USE_POSIX_SEM=1 into the cc-crate C flags for the iOS
# target. notify's file watcher resolves to the kqueue backend on iOS (not the
# macOS-only FSEvents), so no CoreServices dependency is pulled in.
#
# Host-side cargo build with pinned versions is the standard here for native
# libs (no Docker). Produces out/fff-ios/libfff_c.dylib, fakesigned, with its
# install-name set to the on-device install path.
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/fff-ios-work}"

# Pins: fff tag 0.9.4-nightly.6d5576e (crates/fff-c version 0.9.4, ABI-matches
# @ff-labs/fff-bun@0.9.4). Rust target aarch64-apple-ios, ReleaseFast (the
# workspace `release` profile: opt-level 3, fat LTO, codegen-units 1).
FFF_REPO="${FFF_REPO:-https://github.com/dmtrKovalenko/fff.git}"
FFF_COMMIT="${FFF_COMMIT:-4803002d91a7f8c2f895b79fea7594e67ac5633a}"  # tag 0.9.4-nightly.6d5576e
RUST_TARGET="${RUST_TARGET:-aarch64-apple-ios}"
IOS_MIN="${IOS_MIN:-16.0}"                        # device is 17.6.1; 16.0 floor

# On-device install path; also stamped as the dylib install-name. fff-bun
# dlopens by absolute path (the opencode bundle aliases the fff-bin resolver to
# this string; see tools/opencode-ios-bundle.ts).
INSTALL_PATH="${FFF_INSTALL_PATH:-/var/jb/usr/libexec/opencode-js/libfff_c.dylib}"

need() { command -v "$1" >/dev/null || { echo "$1 not found" >&2; exit 1; }; }
need git
need cargo
need rustup
need xcrun
need otool
need install_name_tool

mkdir -p "$WORK" "$OUT/fff-ios"

# --- rust iOS target ---
rustup target list --installed | grep -qx "$RUST_TARGET" \
  || rustup target add "$RUST_TARGET"

# --- source ---
SRC="$WORK/fff"
if [ ! -d "$SRC/.git" ]; then
  git clone "$FFF_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$FFF_COMMIT" || git -C "$SRC" fetch --quiet --tags
git -C "$SRC" checkout --quiet "$FFF_COMMIT"
git -C "$SRC" reset --quiet --hard "$FFF_COMMIT"
git -C "$SRC" clean -fd --quiet

[ "$(grep '^version' "$SRC/crates/fff-c/Cargo.toml" | head -1)" = 'version = "0.9.4"' ] \
  || { echo "fff-c crate is not version 0.9.4 at $FFF_COMMIT (ABI pin drift)" >&2; exit 1; }

# --- SDK / flags ---
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN"
# Force LMDB (compiled by lmdb-master-sys via the cc crate) onto POSIX named
# semaphores instead of the SysV semaphores iOS forbids. The cc crate appends
# CFLAGS_<target> to every C TU it builds; the define is inert for the other C
# deps (git2/libgit2, blake3, mimalloc-sys). Both the hyphen and underscore
# spellings are set because the hyphenated env name is not a shell identifier.
export CFLAGS_aarch64_apple_ios="-DMDB_USE_POSIX_SEM=1"

echo "==> build libfff_c.dylib for $RUST_TARGET (iOS SDK: $SDKROOT)"
(
  cd "$SRC"
  env "CFLAGS_aarch64-apple-ios=-DMDB_USE_POSIX_SEM=1" \
    cargo build -p fff-c --release --target "$RUST_TARGET"
)

BUILT="$SRC/target/$RUST_TARGET/release/libfff_c.dylib"
[ -f "$BUILT" ] || { echo "expected artifact missing: $BUILT" >&2; exit 1; }

# --- verify Mach-O is arm64 iOS (LC_BUILD_VERSION platform 2 == IOS, min 16.0) ---
otool -l "$BUILT" | grep -A3 LC_BUILD_VERSION | grep -q "platform 2" \
  || { echo "artifact is not an iOS (platform 2) binary" >&2; exit 1; }
otool -l "$BUILT" | grep -A3 LC_BUILD_VERSION | grep -q "minos $IOS_MIN" \
  || { echo "artifact minos is not $IOS_MIN" >&2; exit 1; }

# LMDB must use POSIX named semaphores, never SysV semget (SIGSYS on iOS).
if otool -Iv "$BUILT" | grep -qE '\b_semget\b'; then
  echo "artifact imports semget (SysV sem) -- MDB_USE_POSIX_SEM did not take" >&2
  exit 1
fi

# Every symbol @ff-labs/fff-bun@0.9.4 dlopens must be exported. Read from the
# UNSIGNED binary (Apple's nm cannot parse the LINKEDIT layout ldid produces).
REQUIRED_SYMS="fff_create_instance2 fff_create_instance_with fff_destroy \
fff_search fff_glob fff_search_directories fff_search_mixed fff_live_grep \
fff_multi_grep fff_scan_files fff_is_scanning fff_get_base_path \
fff_get_scan_progress fff_wait_for_scan fff_restart_index fff_refresh_git_status \
fff_track_query fff_get_historical_query fff_health_check fff_free_search_result \
fff_search_result_get_item fff_search_result_get_score fff_free_dir_search_result \
fff_dir_search_result_get_item fff_dir_search_result_get_score \
fff_free_mixed_search_result fff_mixed_search_result_get_item \
fff_mixed_search_result_get_score fff_free_grep_result fff_grep_result_get_match \
fff_free_result fff_free_string fff_free_scan_progress"
EXPORTS="$(nm -gU "$BUILT")"
missing=""
for s in $REQUIRED_SYMS; do
  echo "$EXPORTS" | grep -q " _$s\$" || missing="$missing $s"
done
[ -z "$missing" ] || { echo "artifact is missing exported symbols:$missing" >&2; exit 1; }
SYMS="$(echo "$EXPORTS" | grep -c ' _fff_' || true)"

# --- install-name + fakesign ---
install_name_tool -id "$INSTALL_PATH" "$BUILT"
if command -v ldid >/dev/null; then
  xsign "$BUILT"
else
  echo "ldid not on host; sign on device after copy (ldid -S)" >&2
fi

cp "$BUILT" "$OUT/fff-ios/libfff_c.dylib"
echo "==> built $OUT/fff-ios/libfff_c.dylib"
echo "    install-name:     $(otool -D "$BUILT" | tail -1)"
echo "    exported fff_*:   $SYMS"
echo "    lmdb locking:     POSIX named semaphores (sem_open)"
