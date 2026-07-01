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
#     -v "$PWD/patches:/work/patches:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-session.sh
set -euo pipefail
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

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

# dconf (settings persistence; glib-only), the session manager, libnotify (gsd's one extra
# dep), then the minimal gnome-settings-daemon.
TARGETS="${TARGETS:-\
  dconf-package \
  gnome-session-package \
  libnotify-package \
  gnome-settings-daemon-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in dconf gnome-session libnotify gnome-settings-daemon; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl pass: anything that linked GTK's bundled proxy-libintl gets relinked
# onto the libgtkintl shim + Depends: libgtkintl (idempotent; skips clean debs).
echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out || true

echo "==> done"
