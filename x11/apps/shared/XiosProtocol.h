/*
 * XiosProtocol.h — the single private host/compositor wire contract.
 *
 * There are no released third-party consumers, so every in-tree endpoint speaks
 * exactly this version. A mismatch is fatal; there are no compatibility modes.
 */
#ifndef XIOS_PROTOCOL_H
#define XIOS_PROTOCOL_H

#include <stdint.h>

#define XIOS_PROTOCOL_VERSION 1u
#define XIOS_MSG_MAGIC 0x584D5331u /* 'XMS1' */
#define XIOS_GPU_FENCE_TOKEN_SIZE 32u

typedef struct {
    uint32_t magic;
    uint32_t type;
    uint32_t window_id;
    uint32_t length;
    int32_t a, b, c, d;
} xios_msg;

#ifdef __cplusplus
static_assert(sizeof(xios_msg) == 32, "xios_msg wire size changed");
#else
_Static_assert(sizeof(xios_msg) == 32, "xios_msg wire size changed");
#endif

enum {
    XIOS_MSG_HELLO = 0x01,
    XIOS_MSG_DIRTY = 0x02,
    XIOS_MSG_CURSOR = 0x03,
    XIOS_MSG_CLIPBOARD = 0x04,
    XIOS_MSG_PRESENTED = 0x05,

    XIOS_MSG_BIND = 0x40,
    XIOS_MSG_RESIZE = 0x41,
    XIOS_MSG_ACTIVATE = 0x42,
    XIOS_MSG_CLOSED = 0x43,
    XIOS_MSG_WINDOW_NEW = 0x50,
    XIOS_MSG_WINDOW_GEOM = 0x51,
    XIOS_MSG_WINDOW_TITLE = 0x52,
    XIOS_MSG_WINDOW_GONE = 0x53,
    XIOS_MSG_NATIVE_FRAME = 0x54,
};

#define XIOS_DIRTY_FENCE_BROKER_TOKEN 1u
#define IOSC_NATIVE_SOCK "/var/jb/tmp/iosc-native.sock"

typedef struct {
    uint32_t w, h;
    int32_t hot_x, hot_y;
} xios_cursor_bitmap;

enum {
    XIOS_CLIP_KIND_NONE = 0,
    XIOS_CLIP_KIND_TEXT = 1,
    XIOS_CLIP_KIND_URI = 2,
    XIOS_CLIP_KIND_PNG = 3,
    XIOS_CLIP_KIND_HTML = 4,
};
#define XIOS_CLIP_ITEM_MAX (16u * 1024u * 1024u)

#define XIOS_NWIN_MAXIMIZED 0x1u
#define XIOS_NWIN_FULLSCREEN 0x2u

#endif
