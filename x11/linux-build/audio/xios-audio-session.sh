#!/var/jb/bin/sh
export XIOS_AUDIO_SERVER="${XIOS_AUDIO_SERVER:-/var/jb/tmp/xios-audio.sock}"
# PulseAudio owns PULSE_SERVER. This XIOA socket is reserved for xios-audiod and
# module-xios-sink, plus the local xios-audio-play smoke test.
# No SDL_AUDIODRIVER default: every login shell, and so every app the session
# launches through bash -lc, inherits whatever this exports. xios-sdl2 and SDL3
# have no coreaudio driver, and Procursus's UIKit SDL2 picks coreaudio unaided,
# so each SDL wrapper names its own driver.

xios_audio_start() {
    # No pgrep on the device (ps|grep is the working idiom); a failed check
    # here must not unlink a live socket out from under a running daemon.
    if [ -S "$XIOS_AUDIO_SERVER" ] && \
       ps aux 2>/dev/null | grep -v grep | grep -q "xios-audiod"; then
        return 0
    fi
    rm -f "$XIOS_AUDIO_SERVER" 2>/dev/null
    if command -v xios-audiod >/dev/null 2>&1; then
        nohup xios-audiod --socket "$XIOS_AUDIO_SERVER" \
            >/var/jb/tmp/xios-audiod.log 2>&1 &
        sleep 1
    fi
}
