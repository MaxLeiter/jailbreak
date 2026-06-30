#!/var/jb/bin/sh
export XIOS_AUDIO_SERVER="${XIOS_AUDIO_SERVER:-/var/jb/tmp/xios-audio.sock}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${XIOS_AUDIO_SERVER}}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-coreaudio}"

xios_audio_start() {
    if [ -S "$XIOS_AUDIO_SERVER" ] && pgrep -f "xios-audiod" >/dev/null 2>&1; then
        return 0
    fi
    rm -f "$XIOS_AUDIO_SERVER" 2>/dev/null
    if command -v xios-audiod >/dev/null 2>&1; then
        nohup xios-audiod --socket "$XIOS_AUDIO_SERVER" \
            >/var/jb/tmp/xios-audiod.log 2>&1 &
        sleep 1
    fi
}

