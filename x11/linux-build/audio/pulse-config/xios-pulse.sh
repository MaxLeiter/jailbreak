#!/var/jb/bin/sh
# Profile snippet shipped by the pulseaudio deb. The PA daemon is the one true
# libpulse endpoint; xios-audiod's XIOA socket stays reserved for module-xios-sink
# and local debug clients.
export PULSE_SERVER="unix:/var/jb/tmp/pulse/native"
# PulseAudio chmods its runtime dir to 0700 on every start (0755 only in
# --system mode, which needs a 'pulse' user iOS lacks) and leaves the socket
# 0777 for that directory to guard. So the daemon gets its own private runtime
# dir (pid file, on-demand cli socket), and the native socket lives in
# /var/jb/tmp/pulse, kept 0755 so mobile clients (apps launched from the Home
# Screen) can reach it. auth-anonymous=1 in default.pa is what admits them.
# Not ${...:-}: launchers still pass PULSE_RUNTIME_PATH=/var/jb/tmp/pulse to
# clients, and a root pacmd run with that would re-lock the socket dir.
export PULSE_RUNTIME_PATH=/var/jb/tmp/pulse-daemon

# Session launchers call this after xios_audio_start/xios_media_start (all are
# safe to call unconditionally; each is a no-op when its daemon is already up).
# No pgrep on device, hence ps|grep.
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

    # The capture half: module-xios-source reconnects on its own, but starting
    # xios-mediad here makes PulseAudio expose a live default source without
    # requiring apps to know about the Xios media socket.
    if command -v xios-mediad >/dev/null 2>&1; then
        if ! ps aux 2>/dev/null | grep -v grep | grep -q "xios-mediad"; then
            rm -f "${XIOS_MEDIA_MIC_SERVER:-/var/jb/tmp/xios-media-mic.sock}" 2>/dev/null
            xios-mediad >/var/jb/tmp/xios-mediad.log 2>&1 &
            sleep 1
        fi
    fi

    # Before the already-running check, so this also reopens a socket dir that
    # a daemon from an older xios-pulse.sh locked as its runtime dir.
    mkdir -p /var/jb/tmp/pulse && chmod 0755 /var/jb/tmp/pulse 2>/dev/null
    if ps aux 2>/dev/null | grep -v grep | grep -q "[p]ulseaudio"; then
        return 0
    fi
    ( PULSE_RUNTIME_PATH=/var/jb/tmp/pulse-daemon pulseaudio --daemonize=no \
        --log-target=file:/var/jb/tmp/pulseaudio.log \
        >/dev/null 2>&1 & )
}
