#ifndef XIOS_AUDIO_PROTOCOL_H
#define XIOS_AUDIO_PROTOCOL_H

#include <stdint.h>

#define XIOS_AUDIO_MAGIC 0x414f4958u /* "XIOA", little-endian */
#define XIOS_AUDIO_VERSION 1u
#define XIOS_AUDIO_DEFAULT_SOCKET "/var/jb/tmp/xios-audio.sock"
#define XIOS_AUDIO_DEFAULT_RATE 48000u
#define XIOS_AUDIO_DEFAULT_CHANNELS 2u

enum {
    XIOS_AUDIO_MSG_OPEN = 1,
    XIOS_AUDIO_MSG_DATA = 2,
    XIOS_AUDIO_MSG_DRAIN = 3,
    XIOS_AUDIO_MSG_CLOSE = 4
};

enum {
    XIOS_AUDIO_FMT_S16LE = 1,
    XIOS_AUDIO_FMT_F32LE = 2
};

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t type;
    uint32_t size;
} xios_audio_msg;

typedef struct {
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t format;
    uint32_t flags;
} xios_audio_open;

#endif

