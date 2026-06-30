# Xios compositor — Stage 3 implementation spec

Status: spec only (no code built). Companion to `compositor-design.md`; that doc is the
architecture, this is the implementable detail. Same constraints: docs only, read-only on
code, no builds.

Scope: the three things that make Stage 3a implementable the moment the IOSurface DDX lands:
- **A.** `xios_compositor.c` API + in-server window-table layout (Composite Manual redirect,
  per-window IOSurface-backed pixmaps, per-window Damage).
- **B.** Protocol v2 (`XIO2`) message structs, XID-keyed, `msgh_id = XID`, ready to drop into
  `xios_surface.h` (server) + `XSurface.c` (app) via a shared `xios_proto.h`.
- **C.** An ordered Stage-3a task breakdown, each task scoped for one subagent.

Grounded in the current sources: `linux-build/patches/xios/{InitOutput.c,xios_surface.c,
xios_surface.h,Makefile.am}`, `apps/Xios/Sources/{XScreen.swift,XSurface.c,XInput.c}`,
`linux-build/build.sh` (the `tigervnc_xios` drop-in), `xios-ent.xml`.

> **Two server-internal details — CONFIRMED against the unpacked xserver 1.20.11 tree**
> (the tigervnc recipe unpacks it; it is not kept in `build_work`). Both are pinned, so the
> spec is build-complete:
> 1. **Backing-pixmap detection — confirmed.** The hint is
>    `CREATE_PIXMAP_USAGE_BACKING_PIXMAP` = **value 2**. It is the *only* `CreatePixmap` call
>    in `composite/compalloc.c`, inside `compNewPixmap()` (~line 535). Full enum
>    (`include/scrnintstr.h`): `SCRATCH=1`, **`BACKING_PIXMAP=2`**, `GLYPH_PICTURE=3`,
>    `SHARED=4`. So the `CreatePixmap` wrap (§A.5 option 1) detects backing pixmaps by
>    `usage_hint == CREATE_PIXMAP_USAGE_BACKING_PIXMAP` — this is *the* path. (Value 2 is not
>    *exclusively* composite in principle, but nothing else in this tree allocates with it;
>    the hint-independent `SetWindowPixmap` repoint, §A.5 option 2, is now a footnote fallback
>    only.)
> 2. **Redirect signature — confirmed.**
>    `int compRedirectSubwindows(ClientPtr pClient, WindowPtr pWin, int update)` (returns X
>    status; `update = CompositeRedirectManual` for us), in `composite/compalloc.c`. Sibling
>    for per-window redirect of override-redirect popups:
>    `int compRedirectWindow(ClientPtr, WindowPtr, int update)`.

---

## A. In-server compositor — `xios_compositor.c` / `.h`

### A.1 File structure & the header firewall

`xios_surface.c` deliberately includes **no X server headers** (so IOSurface/CoreFoundation/
mach can't collide with dix macros). Preserve that. Split responsibilities:

- **`xios_surface.c` (Apple-only, extended):** all IOSurface + mach + socket code. Today it
  manages one static surface; generalise it to *N* surfaces behind opaque handles, plus the
  protocol-v2 framing. Exposes only plain-C types (ints, `uint32_t`, opaque `void*`). New API
  in §A.2.
- **`xios_compositor.c` (X-only, new):** includes the X server headers (`windowstr.h`,
  `pixmapstr.h`, `scrnintstr.h` (the `CREATE_PIXMAP_USAGE_*` enum lives here),
  `compositeext.h`/composite internals, `damage.h`) **and**
  `xios_surface.h` (pure C). Owns the window table, screen-proc wrapping, Composite redirect,
  per-window Damage, and the translation from X lifecycle → `xios_surface.c` protocol calls.
  Never touches IOSurface/mach directly.
- **`xios_compositor.h`:** the handful of entry points `InitOutput.c` calls.

Build wiring (mirror how `xios_surface.c` is added): in `patches/xios/Makefile.am` add
`xios_compositor.c` to `SRCS`; in `build.sh` `tigervnc_xios()` add the `cp -f
$(BUILD_ROOT)/build_patch/xios/xios_compositor.{c,h} hw/vfb/` lines and add the file to the
`cp` list near `xios_surface.c`. No new `-framework` (Apple code stays in `xios_surface.c`,
which already links `-framework IOSurface -framework CoreFoundation`). Composite/Damage are
in-server (xserver libs), no extra link flags.

### A.2 `xios_surface.c` extended API (Apple side, opaque handles)

```c
/* xios_surface.h — additions. Opaque per-window surface handle. */
typedef struct xios_surface xios_surface_t;   /* opaque; owns IOSurfaceRef + meta */

/* Allocate a BGRA8 IOSurface sized w*h. *base = IOSurfaceGetBaseAddress (the fb/pixmap
 * draws here), *stride = aligned bytesPerRow. NULL on failure. Generation is assigned by
 * the caller (compositor) and echoed back to the app to match resize swaps. */
xios_surface_t *xios_surface_alloc(int w, int h, int *stride, void **base);
void            xios_surface_free(xios_surface_t *s);   /* CFRelease the IOSurface */
int             xios_surface_stride(xios_surface_t *s);

/* Protocol v2 emit (server -> app). Framed on the AF_UNIX stream to every client; the
 * surface variant additionally mach_msg's the IOSurface send right (msgh_id=xid, with xid+
 * generation inline) to each client's receive port. Non-blocking; a backed-up app is never
 * allowed to stall the server (same discipline as today's xios_notify_dirty). */
void xios_emit_win_create   (uint32_t xid, int x, int y, int w, int h, uint32_t flags, uint32_t parent);
void xios_emit_win_map      (uint32_t xid);
void xios_emit_win_unmap    (uint32_t xid);
void xios_emit_win_configure(uint32_t xid, int x, int y, int w, int h, int atlas_x, int atlas_y, uint32_t above);
void xios_emit_win_restack  (uint32_t xid, uint32_t above);
void xios_emit_win_surface  (uint32_t xid, xios_surface_t *s, uint32_t generation); /* socket + mach */
void xios_emit_win_damage   (uint32_t xid, int x, int y, int w, int h);
void xios_emit_win_title    (uint32_t xid, const char *utf8, int len);
void xios_emit_win_hints    (uint32_t xid, uint32_t type, int min_w, int min_h, int max_w, int max_h,
                             uint32_t resizable, uint32_t transient_for);
void xios_emit_win_destroy  (uint32_t xid);

/* Protocol v2 receive (app -> server). The accept/reader thread parses frames and pushes
 * them onto a main-thread input ring (see §A.7); these callbacks fire on the SERVER MAIN
 * THREAD from the WakeupHandler. The compositor registers them at init. */
typedef struct {
    void (*pointer)(uint32_t xid, int lx, int ly, uint32_t buttons);
    void (*scroll )(uint32_t xid, int lx, int ly, int dx, int dy);
    void (*key    )(uint32_t keycode_or_keysym, int is_keysym, int down, uint32_t mods);
    void (*focus  )(uint32_t xid);
    void (*configure_request)(uint32_t xid, int w, int h);
    void (*close  )(uint32_t xid);
    void (*surface_released)(uint32_t xid, uint32_t generation);
} xios_app_callbacks;
void xios_set_app_callbacks(const xios_app_callbacks *cb);
void xios_drain_app_messages(void);   /* call from WakeupHandler on the main thread */
```

The existing `xios_server_start`, peer-pid validation, chmod-to-`mobile`, JSON handshake, and
the `task_for_pid`+`mach_port_extract_right`+`IOSurfaceCreateMachPort`+`mach_msg` hand-off are
reused verbatim; `xios_emit_win_surface` is that same hand-off run once per window with the
xid/generation carried inline (§B.4). The single-surface `xios_surface_create` path stays as
the Stage-2 fallback (whole-screen mirror) — selected when redirect is disabled.

### A.3 The in-server window table

Track top-level (and override-redirect) windows. Store the record on the `WindowPtr`
devPrivates for O(1) `pWin → record`, plus a small `XID → record` map for app messages that
name an XID.

```c
/* xios_compositor.c */
typedef enum {
    XW_OVERRIDE_REDIRECT = 1u<<0,   /* menus/tooltips/popups */
    XW_INPUT_ONLY        = 1u<<1,   /* no surface */
    XW_MAPPED            = 1u<<2,
    XW_HAS_SURFACE       = 1u<<3,
} XiosWinFlags;

typedef struct XiosWindow {
    Window          xid;
    WindowPtr       pWin;
    PixmapPtr       pPixmap;     /* IOSurface-backed backing pixmap (NULL until mapped) */
    xios_surface_t *surface;     /* opaque Apple-side handle (NULL until mapped) */
    DamagePtr       damage;      /* per-window damage tracker */
    int             x, y, w, h;  /* current window geometry (content size) */
    int             atlas_x, atlas_y;  /* fixed non-overlapping origin in the virtual root */
    uint32_t        generation;  /* ++ on every surface (re)alloc; echoed to the app */
    uint32_t        flags;
    Bool            dirty;       /* set by the damage report fn, flushed in the block handler */
} XiosWindow;

static DevPrivateKeyRec xiosWinPrivKey;           /* pWin -> XiosWindow* */
#define XIOS_WIN(pWin) ((XiosWindow*) dixLookupPrivate(&(pWin)->devPrivates, &xiosWinPrivKey))

/* XID -> XiosWindow* : a small open-addressed table or the resource db; needed for the
 * app->server messages that arrive by XID off the socket thread's drained queue. */
XiosWindow *xios_win_by_xid(Window xid);
```

`dixRegisterPrivateKey(&xiosWinPrivKey, PRIVATE_WINDOW, 0)` in init.

### A.4 Entry points (`xios_compositor.h`) and init sequence

```c
Bool xios_compositor_init(ScreenPtr pScreen, vfbScreenInfoPtr pvfb);  /* called from vfbScreenInit, replaces xiosSetup when redirect mode is on */
void xios_compositor_block_handler(ScreenPtr pScreen);  /* flush per-window damage + drain app msgs */
void xios_compositor_fini(ScreenPtr pScreen);           /* teardown (ddxGiveUp / CloseScreen) */
```

`xios_compositor_init` (called from `vfbScreenInit`, screen 0, when a new `-composite` arg or
`-iosurface` + redirect is set):

1. `dixRegisterPrivateKey(&xiosWinPrivKey, PRIVATE_WINDOW, 0)`.
2. `DamageSetup(pScreen)` (as today).
3. Wrap the screen procs (§A.5), saving the originals.
4. `compRedirectSubwindows(serverClient, pScreen->root, CompositeRedirectManual)` (confirmed
   signature, `composite/compalloc.c`). Manual = the server stops auto-painting redirected
   windows to the root (the root is never displayed).
5. Become the window manager: `pScreen->root` event mask gets
   `SubstructureRedirectMask | SubstructureNotifyMask` (server-side `ChangeWindowAttributes`
   / set `pWin->eventMask` for `serverClient`) so client `MapRequest`/`ConfigureRequest`/
   `CirculateRequest` come to us and we place windows into the atlas instead of letting them
   self-position. No external WM (`fluxbox` dropped from `xios-server.sh` in this mode).
6. `RegisterBlockAndWakeupHandlers(xiosBlockWrap, xiosWakeupWrap, pScreen)` — the block
   handler flushes per-window damage; the wakeup handler calls `xios_drain_app_messages()`
   (§A.7).
7. `PropertyStateCallback` registration for title/hints (§A.6).
8. `xios_server_start(...)` (unchanged) + `xios_set_app_callbacks(...)`.

### A.5 Per-window IOSurface-backed pixmaps (the core mechanism)

`fb` pixmaps are linear blobs with a known stride — identical in shape to the screen fb,
which already works as an IOSurface. So back each window's Composite pixmap with a
window-sized IOSurface.

**Hooks wrapped:** `CreateWindow`, `DestroyWindow`, `RealizeWindow`, `UnrealizeWindow`,
`PositionWindow`, `ClipNotify`, `SetWindowPixmap`, `CreatePixmap`, `DestroyPixmap`,
`SetShape` (Stage 3b).

**Option 1 — wrap `CreatePixmap` (THE path; hint = `CREATE_PIXMAP_USAGE_BACKING_PIXMAP`,
value 2, confirmed the only `CreatePixmap` call in `composite/compalloc.c:compNewPixmap`):**

```c
static PixmapPtr
xiosCreatePixmap(ScreenPtr pScreen, int w, int h, int depth, unsigned usage)
{
    if (usage == CREATE_PIXMAP_USAGE_BACKING_PIXMAP && w > 0 && h > 0) {
        int stride; void *base;
        xios_surface_t *s = xios_surface_alloc(w, h, &stride, &base);
        if (s) {
            /* header-only fb pixmap, then attach external IOSurface storage */
            PixmapPtr p = nextCreatePixmap(pScreen, 0, 0, depth, usage);
            (*pScreen->ModifyPixmapHeader)(p, w, h, depth, BitsPerPixel(depth), stride, base);
            xios_pixmap_bind(p, s);   /* side table: pixmap -> surface, for destroy/lookup */
            return p;
        }
    }
    return nextCreatePixmap(pScreen, w, h, depth, usage);
}
```

**Option 2 — wrap `SetWindowPixmap` (footnote fallback, hint-independent):** not needed for
1.20.11 (option 1 is confirmed), kept only as a defensive alternative if a future xserver
changes the backing-pixmap usage hint. When Composite binds a fresh backing pixmap to a
window, replace that pixmap's storage with an IOSurface in place: free the fb-allocated bits,
`ModifyPixmapHeader` to the surface base/stride, bind in the side table.

**Ownership hazard (must handle either way):** `fbDestroyPixmap` will `free(pPixmap->
devPrivate.ptr)` — which would free the IOSurface base. Guard it:

```c
static Bool
xiosDestroyPixmap(PixmapPtr p)
{
    xios_surface_t *s = xios_pixmap_surface(p);   /* side-table lookup, NULL if not ours */
    if (s) {
        p->devPrivate.ptr = NULL;                 /* so fbDestroyPixmap won't free surface mem */
        xios_pixmap_unbind(p);
        xios_surface_free(s);                     /* CFRelease the IOSurface */
    }
    return nextDestroyPixmap(p);
}
```

**Binding a surface to a window + driving WIN_SURFACE on resize:** wrap `SetWindowPixmap`.
It is called whenever Composite (re)points a window at a backing pixmap — i.e. on first map
and on every resize. That is the precise place to emit `WIN_SURFACE` with a bumped generation:

```c
static void
xiosSetWindowPixmap(WindowPtr pWin, PixmapPtr pPix)
{
    nextSetWindowPixmap(pWin, pPix);
    XiosWindow *xw = XIOS_WIN(pWin);
    if (!xw) return;
    xios_surface_t *s = xios_pixmap_surface(pPix);
    if (s && s != xw->surface) {
        xw->surface = s;
        xw->pPixmap = pPix;
        xw->generation++;
        if (!xw->damage) {                        /* first bind: register per-window damage */
            xw->damage = DamageCreate(xiosDamageReport, NULL, DamageReportNonEmpty,
                                      FALSE, pWin->drawable.pScreen, xw);
            DamageRegister(&pWin->drawable, xw->damage);
        }
        if (xw->flags & XW_MAPPED)
            xios_emit_win_surface(xw->xid, s, xw->generation);  /* socket + mach hand-off */
    }
}
```

Map/unmap/geometry/stack wrappers translate straight to emits:

- `xiosRealizeWindow` → set `XW_MAPPED`; ensure surface bound (force a `MapWindow`-time
  Composite alloc if needed); `xios_emit_win_map(xid)`; `xios_emit_win_surface` if not yet
  sent.
- `xiosUnrealizeWindow` → clear `XW_MAPPED`; `xios_emit_win_unmap(xid)`.
- `xiosPositionWindow` / config → update `x,y,w,h`; on size change the Composite pixmap is
  reallocated (→ new surface via CreatePixmap → new bind via SetWindowPixmap → new
  WIN_SURFACE); always emit `xios_emit_win_configure(...)` carrying the atlas origin.
- `xiosClipNotify` → `xios_emit_win_restack(xid, above)`.
- `xiosCreateWindow` → if InputOutput && (parent==root || override-redirect): allocate the
  record, assign an atlas slot (§A.8), `xios_emit_win_create(...)`.
- `xiosDestroyWindow` → `xios_emit_win_destroy(xid)`; free record (surface freed via
  DestroyPixmap path); release the atlas slot.

### A.6 Title / hints / type (server-side property watch)

Register on the server's `PropertyStateCallback` (CallbackListPtr; fires on every property
change with the `WindowPtr` + `Atom`). Watch `WM_NAME`, `_NET_WM_NAME`,
`_NET_WM_WINDOW_TYPE`, `WM_NORMAL_HINTS`, `WM_TRANSIENT_FOR`; read with
`dixLookupProperty(&pProp, pWin, atom, serverClient, DixReadAccess)` and emit `WIN_TITLE` /
`WIN_HINTS`. Atoms via `MakeAtom("_NET_WM_NAME", ...)` cached at init. `_NET_WM_WINDOW_TYPE`
maps to the `xios_win_type` enum (§B.3) the app uses to pick chrome.

### A.7 Per-window damage flush + app-message drain (threading)

- **Damage report fn** (`xiosDamageReport`) runs on the main thread when a window is drawn;
  it sets `xw->dirty = TRUE` (cheap). The **block handler** iterates the window table and for
  each dirty window calls `xios_emit_win_damage(xid, bbox)` (bbox from `DamageRegion`) then
  `DamageEmpty`. This generalises today's single-root flush in `xiosBlockHandler`.
- **App → server messages** arrive on the `xios_surface.c` accept/reader thread, which must
  **not** touch dix from off-thread. It parses frames and pushes them onto a mutex-guarded
  ring. The **wakeup handler** (main thread) calls `xios_drain_app_messages()`, which pops the
  ring and invokes the registered `xios_app_callbacks` — now safely on the main thread, where
  they call dix/XTEST-equivalent injection (§A.7 input) and `XSetInputFocus`/`ConfigureWindow`.
- **Input injection.** Stage 3a keeps the app's XTEST client (no server input code needed —
  the app warps to the atlas slot and injects). Stage 3c moves it in-server: the `pointer`/
  `key`/`focus` callbacks call `GetPointerEvents`/`GetKeyboardEvents` + `mieqEnqueue` against
  the core devices the stock `hw/vfb/InitInput.c` already registers, warping the core pointer
  to `(xw->atlas_x+lx, xw->atlas_y+ly)` before the button transition, and `SetInputFocus` on
  `focus`. This is the only place that needs the main-thread hop, hence the ring.

### A.8 Atlas placement (input routing model)

Give the virtual root a large size (e.g. `-screen 0 8192x8192x24`, or grow `RRScreenSetSize`
dynamically). Assign each top-level window a fixed **non-overlapping** slot:
`atlas_x = col*SLOT_W, atlas_y = row*SLOT_H` from a free-list of grid cells (SLOT = max
expected window size, e.g. 2160×1620; or pack tighter by actual size with a simple shelf
allocator). Park the X window there server-side via `ConfigureWindow`
(`x=atlas_x,y=atlas_y`) so its X geometry matches the slot. Because slots never overlap,
screen-absolute pointer injection at `(atlas_x+lx, atlas_y+ly)` routes to exactly that window
(and its own sub-windows) regardless of how the app overlaps layers on screen. Stacking in X
is irrelevant to input here (no overlap), so iOS z-order need not be mirrored into X — only
keyboard focus is mirrored (`FOCUS` → `XSetInputFocus`). Release the slot on destroy.

---

## B. Protocol v2 (`XIO2`) — shared `xios_proto.h`

Put these definitions in a new **`xios_proto.h`** included by both sides: the server copy in
`linux-build/patches/xios/xios_proto.h` (included by `xios_surface.c`), the app copy in
`apps/Xios/Sources/xios_proto.h` (included by `XSurface.c`, exposed to Swift via the bridging
header). Native little-endian, fixed-size, both peers arm64 (same discipline as today).

### B.1 Constants & framing

```c
#ifndef XIOS_PROTO_H
#define XIOS_PROTO_H
#include <stdint.h>

#define XIOS_MAGIC      0x58494F32u   /* 'XIO2' — bumped from 'XIO1' */
#define XIOS_FMT_BGRA   0x42475241u   /* 'BGRA' */

/* message types — server -> app (1..63) */
enum {
    XIOS_WIN_CREATE    = 1,
    XIOS_WIN_MAP       = 2,
    XIOS_WIN_UNMAP     = 3,
    XIOS_WIN_CONFIGURE = 4,
    XIOS_WIN_RESTACK   = 5,
    XIOS_WIN_SURFACE   = 6,   /* socket announce; IOSurface port follows on the mach channel */
    XIOS_WIN_DAMAGE    = 7,
    XIOS_WIN_TITLE     = 8,   /* variable-length utf8 tail */
    XIOS_WIN_HINTS     = 9,
    XIOS_WIN_DESTROY   = 10,
    XIOS_CURSOR        = 11,
};
/* message types — app -> server (128..) */
enum {
    XIOS_C_POINTER          = 128,
    XIOS_C_SCROLL           = 129,
    XIOS_C_KEY              = 130,
    XIOS_C_FOCUS            = 131,
    XIOS_C_CONFIGURE_REQ    = 132,
    XIOS_C_CLOSE            = 133,
    XIOS_C_SURFACE_RELEASED = 134,
};

/* every framed message on the AF_UNIX stream starts with this header.
 * len = number of payload bytes that follow the header (0 for fixed bodies that fit the
 * union below; >0 only for variable tails like WIN_TITLE). */
typedef struct { uint32_t magic; uint32_t type; uint32_t len; } xios_hdr;
```

### B.2 Server → app bodies

```c
typedef struct { uint32_t xid, parent; int32_t x, y, w, h; uint32_t flags; } xios_win_create;
typedef struct { uint32_t xid; } xios_win_map;       /* also UNMAP, DESTROY */
typedef struct { uint32_t xid;
                 int32_t  x, y, w, h;                 /* content geometry */
                 int32_t  atlas_x, atlas_y;           /* slot origin (XTEST-era app warps here) */
                 uint32_t above; } xios_win_configure;/* above = XID below this one, or 0 */
typedef struct { uint32_t xid, above; } xios_win_restack;
typedef struct { uint32_t xid, width, height, stride, format, generation; } xios_win_surface;
typedef struct { uint32_t xid; int32_t x, y, w, h; } xios_win_damage;  /* bbox; present==redraw */
typedef struct { uint32_t xid; uint32_t type;        /* xios_win_type */
                 int32_t  min_w, min_h, max_w, max_h;
                 uint32_t resizable; uint32_t transient_for; } xios_win_hints;
/* WIN_TITLE: header(len=N) + N bytes utf8 (no NUL needed; len is authoritative) */
typedef struct { uint32_t serial, hot_x, hot_y, width, height; } xios_cursor; /* image via mach */
```

`flags` in `xios_win_create` = `XiosWinFlags` (override-redirect, input-only, mapped).

### B.3 Window-type enum (drives native chrome)

```c
typedef enum {
    XIOS_TYPE_NORMAL = 0,   /* full title bar + ✕ */
    XIOS_TYPE_DIALOG,       /* light chrome, parented to transient_for */
    XIOS_TYPE_UTILITY,
    XIOS_TYPE_TOOLBAR,
    XIOS_TYPE_SPLASH,
    XIOS_TYPE_MENU,         /* chromeless, app positions near owner */
    XIOS_TYPE_DROPDOWN,
    XIOS_TYPE_POPUP,
    XIOS_TYPE_TOOLTIP,
    XIOS_TYPE_COMBO,
    XIOS_TYPE_DND,
    XIOS_TYPE_DOCK,
} xios_win_type;
```

### B.4 The mach surface message (XID + generation inline, self-correlating)

Today `XSurface.c` does a one-shot mach receive correlated only by ordering. v2 makes the
mach message **self-describing** so socket/mach ordering races are impossible: carry the XID
and generation as inline data alongside the port descriptor, and set `msgh_id = xid` too.

```c
/* sent by the server's xios_emit_win_surface(); received by the app's persistent recv loop */
typedef struct {
    mach_msg_header_t          header;      /* msgh_id = xid */
    mach_msg_body_t            body;        /* descriptor_count = 1 */
    mach_msg_port_descriptor_t port;        /* IOSurface send right (COPY_SEND) */
    uint32_t                   xid;         /* inline, authoritative */
    uint32_t                   generation;  /* matches the WIN_SURFACE.generation */
} xios_surface_msg;
```

App receive: loop `mach_msg(MACH_RCV_MSG)` on the persistent receive port; for each message
read `xid`+`generation`, `IOSurfaceLookupFromMachPort(port.name)`, hand to the main thread to
(re)build that window's `MTLTexture`, then `SURFACE_RELEASED` acks the *previous* generation
so the server can `CFRelease` the old surface safely (resize GC).

### B.5 App → server bodies

```c
typedef struct { uint32_t xid; int32_t lx, ly; uint32_t buttons; } xios_c_pointer;
typedef struct { uint32_t xid; int32_t lx, ly, dx, dy; }           xios_c_scroll;
typedef struct { uint32_t code; uint32_t is_keysym; uint32_t down; uint32_t mods; } xios_c_key;
typedef struct { uint32_t xid; }                xios_c_focus;       /* also CLOSE */
typedef struct { uint32_t xid; int32_t w, h; }  xios_c_configure_req;
typedef struct { uint32_t xid; uint32_t generation; } xios_c_surface_released;
#endif /* XIOS_PROTO_H */
```

`buttons` = bitmask (bit0 = button 1, etc.); the server/XTEST layer diffs against the previous
mask to synth press/release. `mods` mirrors X modifier mask for keyboard composition.

### B.6 App-side runtime shape (what `XSurface.c` + `XScreen.swift` become)

`XSurface.c` grows from a one-shot connector into a small client runtime:

- one persistent **socket reader** (parses `xios_hdr` frames → typed callbacks into Swift),
- one persistent **mach receive loop** on a dedicated thread (`xios_surface_msg` → `(xid,
  generation, IOSurfaceRef)` → main thread),
- a **send** path for the app→server messages (§B.5).

`XScreen.swift` keeps a `[xid: WindowLayer]` dictionary. `WindowLayer` = a Metal-textured
`CALayer`/sublayer (zero-copy `makeTexture(descriptor:iosurface:)`, exactly today's path, per
window) + native chrome (title from `WIN_TITLE`, ✕). Event mapping:

- `WIN_CREATE`+`WIN_MAP`+`WIN_SURFACE` → create/show layer, build texture.
- `WIN_DAMAGE(xid)` → re-present only that layer.
- `WIN_CONFIGURE` (new generation) → swap texture; resize chrome.
- `WIN_HINTS.type` → choose chrome; `transient_for` → parent dialogs/menus.
- `WIN_DESTROY`/`WIN_UNMAP` → remove/hide layer; `C_SURFACE_RELEASED` acks old generations.
- touch on a layer's content → `C_POINTER` (XTEST warp to `atlas_x/atlas_y` in 3a); chrome/
  gesture touches consumed by the app (drag/resize/snap, the carplayhost engine); tap-to-front
  → raise layer + `C_FOCUS`.

---

## C. Stage-3a task breakdown (ordered, one subagent each)

Each task: files touched · depends on · **done when**. 3a = "X apps appear as independent
movable native windows you can type into"; 3b/3c polish (resize/menus/in-server input) follow.

**3a-0 · Shared proto header.** Create `xios_proto.h` (§B) in `patches/xios/` and a mirror in
`apps/Xios/Sources/`; expose to Swift via `Xios-Bridging-Header.h`. · deps: none ·
**done when** both trees compile-include it; struct sizes assert-match across a tiny host test.

**3a-1 · `xios_surface.c` → multi-surface + protocol v2 (Apple side).** Add
`xios_surface_alloc/free/stride`, the `xios_emit_*` framers, the `xios_surface_msg`
hand-off (generalise today's single hand-off, `msgh_id=xid` + inline xid/gen), the app-message
reader thread + ring + `xios_drain_app_messages` + `xios_set_app_callbacks`. Keep
`xios_surface_create` as the Stage-2 fallback. · deps: 3a-0 · **done when** a host stub can
alloc N surfaces and round-trip a framed message; no X headers leak in.

**3a-2 · `xios_compositor.{c,h}` skeleton + screen-proc wrapping + window table.** Wrap
Create/Destroy/Realize/Unrealize/Position/ClipNotify/SetWindowPixmap/Create/DestroyPixmap;
register `xiosWinPrivKey`; build the XID↔record maps; `xios_compositor_init/fini`. No
surfaces yet — just track windows and log lifecycle. · deps: 3a-1 · **done when** Xios with
the new init logs correct create/map/configure/destroy as `xterm`/`xeyes` come and go.

**3a-3 · Composite Manual redirect + per-window IOSurface pixmaps.** Add the redirect call
(`compRedirectSubwindows(serverClient, root, CompositeRedirectManual)` — confirmed sig),
`xiosCreatePixmap` (detect `usage == CREATE_PIXMAP_USAGE_BACKING_PIXMAP`, value 2 — confirmed),
`xiosDestroyPixmap` (the ownership guard), `xiosSetWindowPixmap` (bind + generation + emit
`WIN_SURFACE`). · deps: 3a-2 · **done when** each mapped window gets its own IOSurface and the
app receives a distinct `WIN_SURFACE`/mach port per window.

**3a-4 · Per-window Damage + block-handler flush.** `DamageCreate`/`DamageRegister` per window
at first bind; `xiosDamageReport` sets dirty; block handler flushes `WIN_DAMAGE` per dirty
window. · deps: 3a-3 · **done when** drawing in one window damages only that window's layer.

**3a-5 · Protocol-v2 emit wiring + property watch.** Hook the lifecycle wrappers to the
`xios_emit_*` calls; add `PropertyStateCallback` for `WIN_TITLE`/`WIN_HINTS`/type/transient.
· deps: 3a-3 · **done when** the app receives full lifecycle + titles + hints for every window.

**3a-6 · Atlas placement + WM role.** `SubstructureRedirect` on root; slot allocator; park
windows at slots via `ConfigureWindow`; carry `atlas_x/atlas_y` in `WIN_CONFIGURE`; handle
`MapRequest`/`ConfigureRequest`. · deps: 3a-2 · **done when** windows occupy non-overlapping X
slots and the app gets correct atlas origins.

**3a-7 · Build wiring.** `Makefile.am` `SRCS += xios_compositor.c`; `build.sh` `tigervnc_xios`
`cp` lines for `xios_compositor.{c,h}` + `xios_proto.h`; confirm Composite is built into the
Xvfb/Xios binary. · deps: 3a-2 · **done when** `bash linux-build/run.sh` produces a signed
`Xios` carrying the new module (entitlements unchanged from `xios-ent.xml`).

**3a-8 · App client runtime (`XSurface.c` + Swift bridge).** Persistent socket reader +
mach receive loop + send path; surface their callbacks to `XScreen.swift`. · deps: 3a-0,3a-1 ·
**done when** the app logs per-window create/map/surface/damage off a live Xios.

**3a-9 · Per-window layers (`XScreen.swift`).** `[xid: WindowLayer]`, zero-copy texture per
window, native title-bar chrome from `WIN_TITLE`, present-on-`WIN_DAMAGE`, configure/destroy.
· deps: 3a-8 · **done when** `xterm` + `xeyes` + `xclock` show as three separate native
windows at retina, each updating independently.

**3a-10 · Input routing.** Touch on a layer's content → `C_POINTER` → XTEST warp to the
window's atlas slot; tap-to-front → raise + `C_FOCUS` → `XSetInputFocus`. Reuse `XInput.c`. ·
deps: 3a-9,3a-6 · **done when** tapping inside a window clicks the right widget and the right
window has X focus.

**3a-11 · Native keyboard.** `pressesBegan/Ended` (hardware `UIKey`) + a hidden `UIKeyInput`
first responder (soft kbd) → keysym → `xinput_keycode_for_keysym` → XTEST to the focused
window, with modifier composition. (Converges with team task #2.) · deps: 3a-10 · **done
when** typing into the focused X window works for letters, modifiers, and on-screen input.

**3a-12 · On-device integration pass.** `Xios :3 -screen 0 8192x8192x24 -iosurface` (+ the
compositor flag) + `xterm`/`xeyes`/`xclock`; verify independent movable windows, focus, type,
no leaks across window churn (watch mach-port + IOSurface counts). · deps: all · **done when**
Max confirms the multi-window shell on the iPad.

### Risk hotspots (carry into implementation)

- **Backing-pixmap free guard** (3a-3): detection is settled (hint value 2, confirmed); the
  live hazard is the `devPrivate.ptr = NULL`-before-destroy guard so the IOSurface base is
  never `free()`d by `fbDestroyPixmap`. Prototype on one window first.
- **Resize generation handshake** (3b, but design in now): `WIN_SURFACE.generation` ↔
  `C_SURFACE_RELEASED` so an old IOSurface is `CFRelease`d only after the app drops its
  texture — no cross-process use-after-free during a resize storm.
- **Off-thread → main-thread hop** (3a-1/3c): all dix/XTEST/focus work happens on the server
  main thread via the wakeup-handler drain; the socket thread only parses + enqueues.
- **Mach-port / IOSurface leaks on churn** (3a-12): every `WIN_DESTROY`/unmap/client-drop must
  `xios_surface_free` + `mach_port_deallocate`; the existing swap-remove client cleanup
  generalises.
- **Memory** : per-window surfaces are window-sized (cheap), but cap concurrent windows and
  reclaim aggressively on unmap.
```
