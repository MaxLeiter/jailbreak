#!/var/jb/bin/sh
# Profile snippet shipped by the pulseaudio deb. The PA daemon is the one true
# libpulse endpoint; xios-audiod's XIOA socket stays reserved for module-xios-sink
# and local debug clients.
export PULSE_SERVER="unix:/var/jb/tmp/pulse/native"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/var/jb/tmp/pulse}"

# Session launchers call this after xios_audio_start (both are safe to call
# unconditionally; each is a no-op when its daemon is already up). No pgrep on
# device, hence ps|grep.
xios_pulse_start() {
    # The hardware half first: module-xios-sink reconnects on its own, but
    # starting xios-audiod here makes one call sufficient for a full stack.
    if command -v xios-audiod >/dev/null 2>&1; then
        if ! ps aux 2>/dev/null | grep -v grep | grep -q "xios-audiod"; then
            rm -f "${XIOS_AUDIO_SERVER:-/var/jb/tmp/xios-audio.sock}" 2>/dev/null
            # xios-audiod self-daemonizes (fork+setsid), so this returns fast,
            # but background it anyway: any future --foreground default or a
            # pre-fork stall (session activation) must not block the session.
            xios-audiod >/var/jb/tmp/xios-audiod.log 2>&1 &
            sleep 1
        fi
    fi

    if ps aux 2>/dev/null | grep -v grep | grep -q "[p]ulseaudio"; then
        return 0
    fi
    mkdir -p /var/jb/tmp/pulse
    ( pulseaudio --daemonize=no \
        --log-target=file:/var/jb/tmp/pulseaudio.log \
        >/dev/null 2>&1 & )
}
