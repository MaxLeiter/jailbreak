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
    union { uint32_t window_id, state; };
    uint32_t length;
    union { int32_t a, x; };
    union { int32_t b, y; };
    union { int32_t c; uint32_t code; };
    union { int32_t d; uint32_t mods; };
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

/*
 * Every private stream begins with one exact-version record:
 *   magic=XIOS_MSG_MAGIC, type=XIOS_MSG_HELLO,
 *   window_id=XIOS_PROTOCOL_VERSION.
 * Each endpoint defines only the remaining fields needed by its one current
 * contract. A second HELLO, another version, or an unknown message is fatal.
 */
#define XIOS_DIRTY_FENCE_BROKER_TOKEN 1u
#define IOSC_NATIVE_SOCK "/var/jb/tmp/iosc-native.sock"

/*
 * Input and system-integration messages share this envelope and one registry.
 * For XIOS_IN_* records:
 *   a=x, b=y, c=code, window_id=state, d=mods, length=payload bytes.
 * Only XIOS_IN_TEXT has a payload; its c and length both contain the byte count.
 * XIOS_IN_BIND carries the bound native window in c.
 */
enum {
    XIOS_IN_MOTION     = 0x100,
    XIOS_IN_BUTTON     = 0x101,
    XIOS_IN_KEY        = 0x102,
    XIOS_IN_TEXT       = 0x103,
    XIOS_IN_TRAITS     = 0x104,
    XIOS_IN_TOUCH      = 0x105,
    XIOS_IN_TABLET     = 0x106,
    XIOS_IN_BIND       = 0x107,
    XIOS_IN_AXIS       = 0x108,
    XIOS_IN_OUTPUT     = 0x109,
    XIOS_IN_HAPTIC     = 0x10a,
    XIOS_IN_VOLUME     = 0x10b,
    XIOS_IN_APPEARANCE = 0x10c,
    XIOS_IN_GESTURE    = 0x10d,
    XIOS_IN_BRIGHTNESS = 0x10e,
    XIOS_IN_IMPROXY    = 0x10f,
};

#define XIOS_VOLUME_STATE_TO_DEVICE 1u
#define XIOS_BRIGHTNESS_STATE_TO_DEVICE 1u
#define XIOS_GESTURE_SWIPE  1u
#define XIOS_GESTURE_PINCH  2u
#define XIOS_GESTURE_HOLD   3u
#define XIOS_GESTURE_BEGIN  0u
#define XIOS_GESTURE_UPDATE 1u
#define XIOS_GESTURE_END    2u
#define XIOS_GESTURE_CANCEL 3u

static inline xios_msg
xios_protocol_hello(void)
{
    xios_msg m = {0};
    m.magic = XIOS_MSG_MAGIC;
    m.type = XIOS_MSG_HELLO;
    m.window_id = XIOS_PROTOCOL_VERSION;
    return m;
}

static inline int
xios_protocol_is_exact_hello(const xios_msg *m)
{
    return m &&
           m->magic == XIOS_MSG_MAGIC &&
           m->type == XIOS_MSG_HELLO &&
           m->window_id == XIOS_PROTOCOL_VERSION &&
           m->length == 0 &&
           m->a == 0 && m->b == 0 && m->c == 0 && m->d == 0;
}

static inline xios_msg
xios_input_message(uint32_t type, int32_t x, int32_t y, uint32_t code,
                   uint32_t state, uint32_t mods)
{
    xios_msg m = {0};
    m.magic = XIOS_MSG_MAGIC;
    m.type = type;
    m.window_id = state;
    m.a = x;
    m.b = y;
    m.c = (int32_t)code;
    m.d = (int32_t)mods;
    return m;
}

#define XIOS_INPUT_X(m)     ((m)->a)
#define XIOS_INPUT_Y(m)     ((m)->b)
#define XIOS_INPUT_CODE(m)  ((uint32_t)(m)->c)
#define XIOS_INPUT_STATE(m) ((m)->window_id)
#define XIOS_INPUT_MODS(m)  ((uint32_t)(m)->d)

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
