/*
 * XiosProtocol.h — the single private host/compositor wire contract.
 *
 * There are no released third-party consumers, so every in-tree endpoint speaks
 * exactly this version. A version mismatch is fatal. Presentation extensions
 * are capability-negotiated inside that version so fixed-output producers can
 * retain the original one-surface contract while iosc uses stream-v2.
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
    /* app->compositor: a,b = displayed DIRTY seq lo/hi.
     * c = microseconds between the frame's REAL presentation time
     *     (MTLDrawable.addPresentedHandler) and the moment this ack was sent,
     *     i.e. "presented this long ago".
     * d = flags; bit0 set means c is a measured present time rather than 0. The
     *     compositor forwards a measured value to wp_presentation and otherwise
     *     falls back to timing its own repaint. */
    XIOS_MSG_PRESENTED = 0x05,
    /* app->compositor: the app's DISPLAY clock, so the compositor's coalesced
     * repaint can be vblank-paced rather than event-loop-paced (P0.4).
     *   window_id = 0
     *   a = microseconds from the moment this record was SENT until the display
     *       link's targetTimestamp — the deadline for the frame being built.
     *       May be negative when the app is already late for it.
     *   b = the display's refresh interval in microseconds
     *       (targetTimestamp - timestamp).
     *   c = the minimum frame rate the app asked CoreAnimation for, in fps*1000.
     *   d = the maximum, same units. Together they are the CAFrameRateRange
     *       CoreAnimation may settle inside, which the thermal track clamps.
     *
     * Both records carry DELTAS from send time, never timestamps: CADisplayLink
     * works in CACurrentMediaTime()'s domain and the compositor in
     * CLOCK_MONOTONIC. Those are different clocks that diverge across sleep, and
     * a delta needs no shared epoch — the receiver stamps its own clock on
     * arrival. */
    XIOS_MSG_PACING = 0x06,
    /* Server -> app stream extensions negotiated by XIOS_HELLO_CAP_STREAM_V2:
     *
     * STREAM_INFO follows the server HELLO. `a` is the output-buffer count and
     * the payload is the compositor-owned release MTLSharedEvent broker token.
     *
     * SURFACE is preceded by one IOSurface Mach-port message on the HELLO reply
     * port. window_id is a stream-local surface id; a/b/c are width/height/stride
     * and d is XIOS_SURFACE_FLAG_*.
     *
     * SURFACE_DROP retires a dynamically exported surface id.
     *
     * RELEASED is app -> compositor after the app has committed a Metal command
     * buffer which signals the release timeline at the DIRTY sequence in a/b.
     * The compositor may immediately enqueue a GPU wait for that value; neither
     * CPU blocks on the other GPU queue. */
    XIOS_MSG_SURFACE = 0x07,
    XIOS_MSG_SURFACE_DROP = 0x08,
    XIOS_MSG_RELEASED = 0x09,
    XIOS_MSG_STREAM_INFO = 0x0a,
    /* Server -> app: the pixels of a client-supplied cursor, so the app's
     * overlay layer can act as a real cursor PLANE.
     *
     * A cursor composited into the output buffer is what forfeits direct
     * scanout: it dirties the shared framebuffer, so the compositor can no
     * longer hand the client's own IOSurface straight through. This is the same
     * reason KMS compositors put the cursor on its own plane. CURSOR keeps
     * carrying position/visibility every move; this record carries CONTENT and
     * is sent only when the cursor image itself changes.
     *
     *   a/b    = width/height in pixels
     *   c/d    = hotspot x/y, in the same pixels
     *   length = a * b * 4, the payload that follows: tightly packed
     *            premultiplied BGRA, stride = width * 4.
     *
     * A zero-size record means the client withdrew its cursor image and the app
     * should fall back to the named shape in CURSOR. */
    XIOS_MSG_CURSOR_IMAGE = 0x0b,

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
#define XIOS_HELLO_CAP_STREAM_V2      (1u << 0)
#define XIOS_SURFACE_FLAG_FLIP_Y      (1u << 0)
#define XIOS_PRIMARY_SURFACE_ID       1u
#define XIOS_DYNAMIC_SURFACE_ID_BASE  0x100u
/* Largest cursor edge the CURSOR_IMAGE payload will carry (128*128*4 = 64 KiB).
 * A 64 px cap was too small in practice: KDE runs at a fractional output scale
 * (2.75), so a nominally 24-32 px theme cursor is rendered well above 64 px and
 * was refused, which silently dropped the whole session back to compositing.
 * Anything past this is not a cursor. */
#define XIOS_CURSOR_IMAGE_MAX         128
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
