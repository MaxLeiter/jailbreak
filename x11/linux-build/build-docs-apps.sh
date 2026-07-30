#!/usr/bin/env bash
# Build the document-viewer stack (poppler + exempi + Papers) for rootless iOS
# via the Procursus/Docker pipeline. Companion to
# build-gnome.sh; shares its preamble (host codegen tools + the cc-nounused clang wrapper meson
# probes require). Runs on the GTK4-warmed volume (procursus-vol-gtk-calc).
#
# Papers remains opt-in because its Rust shell is large. The driver installs a
# pinned toolchain into the persistent Procursus volume and selects Rust's
# aarch64-apple-ios target.
#
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-gtk-calc:/work/Procursus \
#     -v "$PWD/build-docs-apps.sh:/work/build-docs-apps.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/tools:/xios-tools:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="poppler-package exempi-package" procursus-xbuild:bookworm-arm64 /work/build-docs-apps.sh
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

# Host build tools missing from the image (same set as build-gnome.sh — poppler-glib runs
# glib-mkenums, and Papers, if ever built, needs the full GNOME app codegen set).
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v gdk-pixbuf-pixdata >/dev/null 2>&1 \
   || ! command -v appstreamcli >/dev/null 2>&1 || ! command -v desktop-file-validate >/dev/null 2>&1; then
  echo "==> installing host build tools (glib/gdk-pixbuf codegen + appstream + desktop-file-utils)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      itstool desktop-file-utils appstream gtk-update-icon-cache >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

TARGETS="${TARGETS:-exempi-package poppler-package girara-package zathura-package zathura-pdf-poppler-package}"

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp -v /work/build_info/iosc-*.xml build_misc/entitlements/
fi

target_requests() {
  [[ " $TARGETS " == *" $1"* ]]
}

stage_required_patch_stack() {
  local pkg="$1"
  if [ ! -d "/work/ports/$pkg/patches" ]; then
    echo "ERROR: missing /work/ports/$pkg/patches; mount ports with -v \\$PWD/../ports:/work/ports:ro" >&2
    exit 1
  fi
  echo "==> staging $pkg source patches"
  bash /work/recipes/stage-port-patches.sh "$pkg" /work/ports build_patch
}

target_requests exempi && stage_required_patch_stack exempi
target_requests zathura && stage_required_patch_stack zathura
target_requests papers && stage_required_patch_stack papers

# Same clang wrapper build-gtk.sh/build-gnome.sh use: neutralise the
# -Werror=unused-command-line-argument that breaks meson's cc.sizeof() probes.
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

ensure_rust_ios_toolchain() {
  target_requests papers || return 0

  local rust_version=1.80.1
  export RUSTUP_HOME=/work/Procursus/build_tools/rustup
  export CARGO_HOME=/work/Procursus/build_tools/cargo
  export PATH="$CARGO_HOME/bin:$PATH"

  if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    echo "==> installing pinned Rust $rust_version host toolchain"
    local rustup_init=/work/Procursus/build_source/rustup-init-aarch64
    if [ ! -x "$rustup_init" ]; then
      wget -q https://static.rust-lang.org/rustup/dist/aarch64-unknown-linux-gnu/rustup-init -O "$rustup_init"
      chmod +x "$rustup_init"
    fi
    "$rustup_init" -y --profile minimal --default-toolchain "$rust_version" --no-modify-path
  fi

  rustup toolchain install "$rust_version" --profile minimal
  rustup default "$rust_version"
  rustup target add aarch64-apple-ios --toolchain "$rust_version"

  export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER=/work/Procursus/build_tools/cc-nounused
  export SDKROOT=/root/cctools/SDK/iPhoneOS16.5.sdk
  export PKG_CONFIG=/work/Procursus/build_tools/cross-pkg-config
  export PKG_CONFIG_ALLOW_CROSS=1
  # gettext-rs declares the unprefixed gettext() ABI directly, while GNU
  # libintl's Darwin dylib exports libintl_gettext(). libgtkintl >= 1.1 bridges
  # both that ABI and GTK's g_libintl_* ABI. Give gettext-sys a conventional
  # libintl linker name pointing at the shim.
  local gettext_root=/work/Procursus/build_tools/papers-gettext
  local gettext_deb
  gettext_deb="$(find /out /repo-debs -maxdepth 1 -type f -name 'libgtkintl_*_iphoneos-arm64.deb' \
    -printf '%f\t%p\n' 2>/dev/null | sort -V | tail -1 | cut -f2-)"
  if [ -z "$gettext_deb" ]; then
    echo "ERROR: Papers needs libgtkintl >= 1.1 in /out or /repo-debs" >&2
    exit 1
  fi
  rm -rf "$gettext_root"
  dpkg-deb -x "$gettext_deb" "$gettext_root"
  bash /xios-tools/stage-ios-gettext-sdk.sh \
    "$gettext_root$XIOS_PREFIX/usr" \
    /work/Procursus/build_tools/cc-nounused \
    "$SDKROOT" 16.0
  export GETTEXT_DIR="$gettext_root$XIOS_PREFIX/usr"
}

ensure_rust_ios_toolchain

# exempi (libexempi8) is Papers' unconditional XMP dep; poppler (libpoppler140 +
# libpoppler-glib8) is the PDF backend. The zathura stack remains an independent
# GTK3 viewer: girara -> zathura -> zathura-pdf-poppler.

PW=build_work/iphoneos-arm64-rootless/1900/papers
PS=build_stage/iphoneos-arm64-rootless/1900/papers
PF="$PW/.xios_patch_series.sha256"
if target_requests papers; then
  PAPERS_FP="$(find /work/ports/papers/patches -maxdepth 1 -type f -print0 |
    sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  PAPERS_OLD_FP="$(cat "$PF" 2>/dev/null || true)"
  if [ -d "$PW" ] && [ "$PAPERS_FP" != "$PAPERS_OLD_FP" ]; then
    echo "==> wiping stale Papers build after patch changes"
    rm -rf "$PW" "$PS"
  fi
fi

record_papers_patch_fingerprint() {
  if [ -n "${PAPERS_FP:-}" ] && [ -d "${PW:-}" ]; then
    printf '%s\n' "$PAPERS_FP" > "$PF"
  fi
}
trap record_papers_patch_fingerprint EXIT

EW=build_work/$XIOS_TRIPLE/exempi
ES=build_stage/$XIOS_TRIPLE/exempi
EF="$EW/.xios_patch_series.sha256"
if target_requests exempi; then
  EXEMPI_FP="$(sha256sum \
    /work/ports/exempi/patches/series \
    /work/ports/exempi/patches/*.patch | sha256sum | awk '{print $1}')"
  EXEMPI_OLD_FP="$(cat "$EF" 2>/dev/null || true)"
  if [ -d "$EW" ] && [ "$EXEMPI_FP" != "$EXEMPI_OLD_FP" ]; then
    echo "==> wiping stale exempi build after patch changes"
    rm -rf "$EW" "$ES"
  fi
fi

ZW=build_work/$XIOS_TRIPLE/zathura
ZS=build_stage/$XIOS_TRIPLE/zathura
ZF="$ZW/.xios_patch_series.sha256"
if target_requests zathura; then
  NEW_FP="$(sha256sum \
    /work/ports/zathura/patches/series \
    /work/ports/zathura/patches/*.patch | sha256sum | awk '{print $1}')"
  OLD_FP="$(cat "$ZF" 2>/dev/null || true)"
  if [ -d "$ZW" ] && [ "$NEW_FP" != "$OLD_FP" ]; then
    echo "==> wiping stale zathura build after patch changes"
    rm -rf "$ZW" "$ZS"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$ZW" ] && [ -n "${NEW_FP:-}" ]; then
  printf '%s\n' "$NEW_FP" > "$ZF"
fi
if [ -d "$EW" ] && [ -n "${EXEMPI_FP:-}" ]; then
  printf '%s\n' "$EXEMPI_FP" > "$EF"
fi
if [ -d "$PW" ] && [ -n "${PAPERS_FP:-}" ]; then
  printf '%s\n' "$PAPERS_FP" > "$PF"
fi

echo "==> collect debs -> /out"
mkdir -p /out
collect_dir="$(mktemp -d /tmp/xios-docs-out.XXXXXX)"
for spec in \
  "exempi:libexempi" \
  "poppler:libpoppler" \
  "papers:papers" \
  "girara:libgirara" \
  "zathura:zathura"; do
  target="${spec%%:*}"
  pattern="${spec#*:}"
  target_requests "$target" || continue
  find build_dist/$XIOS_TRIPLE -type f \
    -name "${pattern}*_*_$XIOS_DEB_ARCH.deb" \
    -exec cp -v {} "$collect_dir/" \; 2>/dev/null || true
done

# Shared libgtkintl relink pass (same as build-gnome.sh): poppler-glib imports the proxy
# libintl (g_libintl_*) and links @rpath/libintl.dylib, so it would dyld-abort exactly like
# the GTK debs. Relink onto the libgtkintl shim, re-sign, add Depends: libgtkintl. Idempotent
# and self-skipping for debs that don't import g_libintl_* (libpoppler140, libexempi8).
if [ -f /work/recipes/relink-gtkintl.sh ]; then
  echo "==> shared libgtkintl relink pass"
  bash /work/recipes/relink-gtkintl.sh "$collect_dir"
fi
cp -v "$collect_dir"/*.deb /out/

echo "==> done"
