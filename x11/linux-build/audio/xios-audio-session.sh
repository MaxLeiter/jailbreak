#!/var/jb/bin/sh
export XIOS_AUDIO_SERVER="${XIOS_AUDIO_SERVER:-/var/jb/tmp/xios-audio.sock}"
# PulseAudio owns PULSE_SERVER. This XIOA socket is reserved for xios-audiod and
# module-xios-sink, plus the local xios-audio-play smoke test.
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
