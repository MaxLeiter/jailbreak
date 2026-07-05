#!/usr/bin/env bash
# pulseaudio-ios-fixes.sh <extracted pulseaudio tree> <audio source dir> [media source dir]
#
# Copy the local Xios PulseAudio module sources after the upstream source patch
# series has been applied.
#
# The patch series lives in ports/pulseaudio/patches and carries the upstream
# source-tree edits for the PulseAudio 17 DAEMON build:
#
# 1. The upstream Darwin module block is macOS-only in practice:
#    module-coreaudio-detect/-device speak the CoreAudio HAL (AudioHardware.h),
#    which does not exist in the iOS SDK, and module-bonjour-publish is useless
#    here. On iOS the RemoteIO output is owned by the fakesigned xios-audiod
#    daemon (the only process with the audio entitlement story), so PulseAudio
#    must NOT try to open the device itself.
#
# 2. In its place, module-xios-sink forwards the
#    rendered/mixed/volume-applied stream to xios-audiod's Unix socket using
#    the XIOA protocol (source lives in linux-build/audio/, shared with the
#    xios-audiod daemon and smoke-test client).
#
#    module-xios-source mirrors that for capture: it reads xios-mediad's mic
#    stream and exposes it as an ordinary PulseAudio source.
#
# 3. The shared sysroot carries a STUB linux/input.h (staged by the mutter
#    track's inert libei/dma-buf shim for keycode constants), so PA's
#    cc.has_header('linux/input.h') gate wrongly enables module-mmkbd-evdev,
#    which then fails on the missing struct input_event/ioctl bits. There is
#    no evdev on iOS; kill the gate.
#
# 4. PA's NEON simd sources are armv7-ONLY inline asm (q0/d4 register names).
#    Upstream aarch64 escapes them because gcc/clang reject -mfpu=neon so the
#    meson simd.check fails; Apple clang + our -Wno-unused-command-line-argument
#    wrapper accept it silently, the check passes, and mix_neon.c explodes with
#    "unknown register name 'q0'". Drop the neon variant outright.
#
# 5. pa_get_binary_name() (src/pulse/util.c) hangs the FIRST pa_log() call any
#    libpulse process makes on iOS, which is why every native-protocol CLIENT
#    (pactl/gvc/GTK apps) froze before it could connect while the daemon's own
#    render path worked. Upstream's OS_IS_DARWIN branch reads the executable
#    name via sysctl(KERN_PROCARGS); that OID returns ENOENT on iOS and its
#    length-probe leaves the size_t length UNINITIALIZED, so the following
#    pa_xmalloc(len) runs on stack garbage -> a giant allocation whose OOM path
#    re-enters pa_log() while the log's PA_ONCE init lock is held -> deadlock.
#    Replace that branch with _NSGetExecutablePath(), the documented Darwin way
#    to get the executable path, which works inside the iOS sandbox.
set -euo pipefail

TREE="${1:?usage: pulseaudio-ios-fixes.sh <pulseaudio tree> <audio dir> [media dir] }"
AUDIO="${2:?usage: pulseaudio-ios-fixes.sh <pulseaudio tree> <audio dir> [media dir] }"
MEDIA="${3:-$AUDIO}"
MESON="$TREE/src/modules/meson.build"

[ -f "$MESON" ] || { echo "pulseaudio-ios-fixes: $MESON not found"; exit 1; }
[ -f "$TREE/src/pulse/util.c" ] || { echo "pulseaudio-ios-fixes: src/pulse/util.c not found"; exit 1; }

grep -q "module-xios-source" "$MESON" || {
  echo "pulseaudio-ios-fixes: source patch series was not applied" >&2
  exit 1
}
grep -q "_NSGetExecutablePath" "$TREE/src/pulse/util.c" || {
  echo "pulseaudio-ios-fixes: util.c source patch was not applied" >&2
  exit 1
}

echo "==> pulseaudio-ios-fixes: injecting Xios PulseAudio modules"
mkdir -p "$TREE/src/modules/xios"
cp -v "$AUDIO/module-xios-sink.c" "$AUDIO/xios_audio_protocol.h" "$AUDIO/xios_sysint_protocol.h" "$TREE/src/modules/xios/"
cp -v "$AUDIO/module-xios-source.c" "$MEDIA/xios_media_protocol.h" "$TREE/src/modules/xios/"
