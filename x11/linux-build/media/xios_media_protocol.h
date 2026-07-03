#ifndef XIOS_MEDIA_PROTOCOL_H
#define XIOS_MEDIA_PROTOCOL_H

#include <stdint.h>

#define XIOS_MEDIA_MAGIC 0x4d4f4958u /* "XIOM", little-endian */
#define XIOS_MEDIA_VERSION 1u

#define XIOS_MEDIA_DEFAULT_VIDEO_SOCKET "/var/jb/tmp/xios-media-video.sock"
#define XIOS_MEDIA_DEFAULT_MIC_SOCKET "/var/jb/tmp/xios-media-mic.sock"

#define XIOS_MEDIA_DEFAULT_AUDIO_RATE 48000u
#define XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS 1u

enum {
    XIOS_MEDIA_MSG_VIDEO_FRAME = 1,
    XIOS_MEDIA_MSG_MIC_FRAME = 2
};

enum {
    XIOS_MEDIA_VIDEO_FMT_BGRA32 = 1
};

enum {
    XIOS_MEDIA_AUDIO_FMT_F32LE = 1
};

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t type;
    uint32_t size;
} xios_media_msg;

typedef struct {
    uint64_t timestamp_ns;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t format;
    uint32_t frame_index;
    uint32_t flags;
} xios_media_video_frame;

typedef struct {
    uint64_t host_time;
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t format;
    uint32_t frames;
    uint32_t flags;
} xios_media_mic_frame;

#endif
