#!/usr/bin/env bash
# Build the PulseAudio DAEMON (+ module-xios-sink) for rootless iOS via the
# Procursus/Docker pipeline. Companion to build-shell.sh, which built the
# client-only pulseaudio for gvc; this flips the same recipe to -Ddaemon=true
# and packages pulseaudio + pulseaudio-utils next to rebuilt libpulse0/-dev.
#
# PRECONDITIONS: a Procursus volume where the glib chain is built
# (procursus-vol-shell is the reference: pulseaudio client + libsndfile + glib
# all have .build_complete). libtool (ltdl, the module loader) is pulled in as
# a normal Procursus subproject dependency.
#
#   docker run --rm --platform linux/arm64 --cpus=2 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/build-audio-server.sh:/work/build-audio-server.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/audio:/work/audio:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-audio-server.sh
set -euo pipefail
cd /work/Procursus

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

# Same clang wrapper the other build scripts use (meson sizeof probes vs the
# Procursus wrapper's -Wl,-adhoc_codesign + -Werror=unused-command-line-argument).
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

# The volume may hold a CLIENT-ONLY pulseaudio with .build_complete; the guard
# in the recipe would skip the daemon reconfigure. Wipe only in that case, so
# packaging-only reruns stay fast.
PW=build_work/iphoneos-arm64-rootless/1900/pulseaudio
PS=build_stage/iphoneos-arm64-rootless/1900/pulseaudio
if [ -d "$PW" ] && [ ! -f "$PW/build/src/daemon/pulseaudio" ]; then
  echo "==> wiping the client-only pulseaudio build tree"
  rm -rf "$PW" "$PS"
fi

# libltdl7 (the daemon's module loader) must ship as a deb, not just get
# staged: the pulseaudio deb Depends on it.
echo "==> make libtool-package (libltdl7) + pulseaudio-package (daemon + module-xios-sink)"
make libtool-package $COMMON -j"$(nproc)"
make pulseaudio-package $COMMON -j"$(nproc)"

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libltdl7 libpulse0 libpulse-dev pulseaudio pulseaudio-utils; do
  find . -name "${pat}_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Anything that linked GTK's bundled proxy-libintl gets relinked onto the
# libgtkintl shim + Depends: libgtkintl (idempotent; skips clean debs).
echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out

echo "==> done"
