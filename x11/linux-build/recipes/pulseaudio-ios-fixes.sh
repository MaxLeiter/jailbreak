#!/usr/bin/env bash
# pulseaudio-ios-fixes.sh <extracted pulseaudio tree> <audio source dir>
#
# iOS surgery for the PulseAudio 17 DAEMON build (client libs needed none):
#
# 1. The upstream darwin module block is macOS-only in practice:
#    module-coreaudio-detect/-device speak the CoreAudio HAL (AudioHardware.h),
#    which does not exist in the iOS SDK, and module-bonjour-publish is useless
#    here. On iOS the RemoteIO output is owned by the fakesigned xios-audiod
#    daemon (the only process with the audio entitlement story), so PulseAudio
#    must NOT try to open the device itself.
#
# 2. In its place: module-xios-sink, a timer-clocked sink that forwards the
#    rendered/mixed/volume-applied stream to xios-audiod's Unix socket using
#    the XIOA protocol (source lives in linux-build/audio/, shared with the
#    xios-audiod daemon and smoke-test client).
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
set -euo pipefail

TREE="${1:?usage: pulseaudio-ios-fixes.sh <pulseaudio tree> <audio dir>}"
AUDIO="${2:?usage: pulseaudio-ios-fixes.sh <pulseaudio tree> <audio dir>}"
MESON="$TREE/src/modules/meson.build"
CORE_MESON="$TREE/src/pulsecore/meson.build"

[ -f "$MESON" ] || { echo "pulseaudio-ios-fixes: $MESON not found"; exit 1; }

if grep -q "if cc.has_header('linux/input.h')" "$MESON"; then
  echo "==> pulseaudio-ios-fixes: disabling the linux/input.h (evdev) module gate"
  sed -i "s|if cc.has_header('linux/input.h')|if false # iOS: sysroot has only a stub linux/input.h (mutter shim), no evdev|" "$MESON"
fi

if grep -q "mix_neon.c" "$CORE_MESON"; then
  echo "==> pulseaudio-ios-fixes: dropping armv7-only NEON simd variant"
  sed -i "/{ 'neon' : \['remap_neon.c', 'sconv_neon.c', 'mix_neon.c'\] },/d" "$CORE_MESON"
  grep -q "mix_neon.c" "$CORE_MESON" && { echo "pulseaudio-ios-fixes: neon removal failed"; exit 1; }
fi

echo "==> pulseaudio-ios-fixes: injecting module-xios-sink"
mkdir -p "$TREE/src/modules/xios"
cp -v "$AUDIO/module-xios-sink.c" "$AUDIO/xios_audio_protocol.h" "$TREE/src/modules/xios/"

if grep -q "module-xios-sink" "$MESON"; then
  echo "==> pulseaudio-ios-fixes: meson.build already patched"
  exit 0
fi

python3 - "$MESON" <<'EOF'
import re, sys

path = sys.argv[1]
src = open(path).read()

# Replace the whole upstream darwin module block (bonjour + CoreAudio HAL)
# with the iOS sink. Anchored on the unique bonjour_dep line.
block = re.compile(
    r"if host_machine\.system\(\) == 'darwin'\n"
    r"  bonjour_dep = .*?\nendif\n",
    re.S)

replacement = """if host_machine.system() == 'darwin'
  # iOS: no CoreAudio HAL (AudioHardware.h) and no Bonjour. RemoteIO output is
  # owned by xios-audiod; module-xios-sink forwards the mixed stream to it.
  all_modules += [
    [ 'module-xios-sink', 'xios/module-xios-sink.c', ['xios/xios_audio_protocol.h'] ],
  ]
endif
"""

new, n = block.subn(replacement, src)
if n != 1:
    sys.exit("pulseaudio-ios-fixes: darwin module block not found (found %d)" % n)
open(path, "w").write(new)
print("==> pulseaudio-ios-fixes: src/modules/meson.build patched")
EOF
