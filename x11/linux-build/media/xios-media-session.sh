#!/bin/sh

export XIOS_MEDIA_VIDEO_SERVER="${XIOS_MEDIA_VIDEO_SERVER:-/var/jb/tmp/xios-media-video.sock}"
export XIOS_MEDIA_MIC_SERVER="${XIOS_MEDIA_MIC_SERVER:-/var/jb/tmp/xios-media-mic.sock}"

xios_media_start() {
    if [ -S "$XIOS_MEDIA_VIDEO_SERVER" ] || [ -S "$XIOS_MEDIA_MIC_SERVER" ]; then
        return 0
    fi
    if command -v xios-mediad >/dev/null 2>&1; then
        xios-mediad --video-socket "$XIOS_MEDIA_VIDEO_SERVER" --mic-socket "$XIOS_MEDIA_MIC_SERVER"
    fi
}
