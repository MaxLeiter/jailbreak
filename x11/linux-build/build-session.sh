#!/usr/bin/env bash
# Build the GNOME SESSION layer for rootless iOS via the Procursus/Docker pipeline.
# Companion to build-shell.sh — same preamble, the session-manager + settings-daemon
# track that sits ABOVE gnome-shell:
#   dconf (GSettings persistence backend) ->
#   gnome-session (the session manager; owns org.gnome.SessionManager, starts gnome-shell) ->
#   gnome-settings-daemon (minimal; audited down to the plugins that make sense on iOS)
#
# PRECONDITIONS (same warm Procursus volume that built gnome-shell, e.g. procursus-vol-shell):
#   The GTK3/GTK4 + glib + gnome-desktop(-4) + json-glib stacks are already built there
#   (build-gtk.sh, build-gnome.sh, build-shell.sh have run). This driver only adds the
#   session layer, which shares that closure.
#
#   docker run --rm --platform linux/arm64 --cpus=2 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/build-session.sh:/work/build-session.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-session.sh
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

# Host build tools missing from the image (glib/gdk-pixbuf codegen + itstool + host glib).
if ! command -v glib-mkenums >/dev/null 2>&1 || ! pkg-config --exists glib-2.0 2>/dev/null; then
  echo "==> installing host build tools (glib codegen + itstool + HOST glib)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      pkg-config itstool desktop-file-utils gtk-update-icon-cache xsltproc docbook-xsl >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

# dconf (settings persistence; glib-only), the session manager, libnotify (gsd's one extra
# dep), the minimal gnome-settings-daemon, and libaccountsservice (client lib; gnome-shell
# imports gi://AccountsService at boot, so this is boot-critical).
TARGETS="${TARGETS:-\
  dconf-package \
  gnome-session-package \
  libnotify-package \
  gnome-settings-daemon-package \
  accountsservice-package \
  libgdm-package}"

if [[ " $TARGETS " == *" gnome-session"* ]]; then
  echo "==> staging gnome-session patch series"
  bash /work/recipes/stage-port-patches.sh gnome-session /work/ports build_patch
fi
if [[ " $TARGETS " == *" accountsservice"* ]]; then
  echo "==> staging accountsservice patch series"
  bash /work/recipes/stage-port-patches.sh accountsservice /work/ports build_patch
fi
if [[ " $TARGETS " == *" libgdm"* ]]; then
  echo "==> staging libgdm patch series"
  bash /work/recipes/stage-port-patches.sh libgdm /work/ports build_patch
fi
if [[ " $TARGETS " == *" gnome-settings-daemon"* ]]; then
  echo "==> staging gnome-settings-daemon patch series"
  bash /work/recipes/stage-port-patches.sh gnome-settings-daemon /work/ports build_patch
fi

echo "==> installing our control/maintainer-script templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

# Same clang wrapper build-gtk.sh/build-gnome.sh use (meson sizeof probes vs the Procursus
# wrapper's -Wl,-adhoc_codesign + -Werror=unused-command-line-argument).
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

GSESS_W=build_work/$XIOS_TRIPLE/gnome-session
GSESS_S=build_stage/$XIOS_TRIPLE/gnome-session
GSESS_F="$GSESS_W/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" gnome-session"* ]]; then
  GSESS_FP="$(sha256sum \
    /work/ports/gnome-session/patches/series \
    /work/ports/gnome-session/patches/*.patch | sha256sum | awk '{print $1}')"
  GSESS_OLD_FP="$(cat "$GSESS_F" 2>/dev/null || true)"
  if [ -d "$GSESS_W" ] && [ "$GSESS_FP" != "$GSESS_OLD_FP" ]; then
    echo "==> wiping stale gnome-session build after patch changes"
    rm -rf "$GSESS_W" "$GSESS_S"
  fi
fi

ACCTS_W=build_work/$XIOS_TRIPLE/accountsservice
ACCTS_S=build_stage/$XIOS_TRIPLE/accountsservice
ACCTS_F="$ACCTS_W/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" accountsservice"* ]]; then
  ACCTS_FP="$(sha256sum \
    /work/ports/accountsservice/patches/series \
    /work/ports/accountsservice/patches/*.patch | sha256sum | awk '{print $1}')"
  ACCTS_OLD_FP="$(cat "$ACCTS_F" 2>/dev/null || true)"
  if [ -d "$ACCTS_W" ] && [ "$ACCTS_FP" != "$ACCTS_OLD_FP" ]; then
    echo "==> wiping stale accountsservice build after patch changes"
    rm -rf "$ACCTS_W" "$ACCTS_S"
  fi
fi

LIBGDM_W=build_work/$XIOS_TRIPLE/libgdm
LIBGDM_S=build_stage/$XIOS_TRIPLE/libgdm
LIBGDM_F="$LIBGDM_W/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" libgdm"* ]]; then
  LIBGDM_FP="$(sha256sum \
    /work/ports/libgdm/patches/series \
    /work/ports/libgdm/patches/*.patch | sha256sum | awk '{print $1}')"
  LIBGDM_OLD_FP="$(cat "$LIBGDM_F" 2>/dev/null || true)"
  if [ -d "$LIBGDM_W" ] && [ "$LIBGDM_FP" != "$LIBGDM_OLD_FP" ]; then
    echo "==> wiping stale libgdm build after patch changes"
    rm -rf "$LIBGDM_W" "$LIBGDM_S"
  fi
fi

GSD_W=build_work/$XIOS_TRIPLE/gnome-settings-daemon
GSD_S=build_stage/$XIOS_TRIPLE/gnome-settings-daemon
GSD_F="$GSD_W/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" gnome-settings-daemon"* ]]; then
  GSD_FP="$(sha256sum \
    /work/ports/gnome-settings-daemon/patches/series \
    /work/ports/gnome-settings-daemon/patches/*.patch | sha256sum | awk '{print $1}')"
  GSD_OLD_FP="$(cat "$GSD_F" 2>/dev/null || true)"
  if [ -d "$GSD_W" ] && [ "$GSD_FP" != "$GSD_OLD_FP" ]; then
    echo "==> wiping stale gnome-settings-daemon build after patch changes"
    rm -rf "$GSD_W" "$GSD_S"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$GSESS_W" ] && [ -n "${GSESS_FP:-}" ]; then
  printf '%s\n' "$GSESS_FP" > "$GSESS_F"
fi
if [ -d "$ACCTS_W" ] && [ -n "${ACCTS_FP:-}" ]; then
  printf '%s\n' "$ACCTS_FP" > "$ACCTS_F"
fi
if [ -d "$LIBGDM_W" ] && [ -n "${LIBGDM_FP:-}" ]; then
  printf '%s\n' "$LIBGDM_FP" > "$LIBGDM_F"
fi
if [ -d "$GSD_W" ] && [ -n "${GSD_FP:-}" ]; then
  printf '%s\n' "$GSD_FP" > "$GSD_F"
fi

echo "==> collect debs -> /out"
mkdir -p /out
for pat in dconf gnome-session libnotify gnome-settings-daemon libaccountsservice libgdm; do
  find . -name "${pat}*_*_$XIOS_DEB_ARCH.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl pass: anything that linked GTK's bundled proxy-libintl gets relinked
# onto the libgtkintl shim + Depends: libgtkintl (idempotent; skips clean debs).
echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out || true

echo "==> done"
