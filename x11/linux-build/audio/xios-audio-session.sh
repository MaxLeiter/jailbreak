#!/var/jb/bin/sh
export XIOS_AUDIO_SERVER="${XIOS_AUDIO_SERVER:-/var/jb/tmp/xios-audio.sock}"
# Correct only for the legacy pa_simple shim (libpulse-simple-xios0), which
# spoke XIOA at this socket. When the real PulseAudio daemon is installed,
# profile.d/xios-pulse.sh (sourced after this file) overrides PULSE_SERVER to
# the PA native socket; real libpulse clients cannot speak XIOA.
export PULSE_SERVER="${PULSE_SERVER:-unix:${XIOS_AUDIO_SERVER}}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-coreaudio}"

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

