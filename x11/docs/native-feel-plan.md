# Native-feel bundle: rotation, volume, dark-match, haptics

Small system-integration features that make the desktop feel like it belongs on
the iPad. Wire types 10-13 are registered in `wayland/xios_input_socket.h`
(committed). Already landed, no owner action needed:

- `wayland/xios-sysintd.c` + `build-sysintd.sh` + `out/xios-sysintd` — session
  daemon: VOLUME -> `pactl set-sink-volume xios N%`, APPEARANCE ->
  `gsettings color-scheme` (+ gtk-theme Adwaita/Adwaita-dark for GTK3, opt-out
  `XIOS_SYSINT_NO_GTK3=1`). Socket `/var/jb/tmp/xios-sysint.sock`.
- `wayland/iosc_gl.{c,h}` — `iosc_gl_resize()` rebinds the output render target
  (context/program/client-texture cache survive; failure -> CPU fallback).
- `apps/Xios/Sources/SysIntClient.{c,h}` + `SystemIntegration.swift` — app-side
  detection + senders, fully self-contained new files (own sockets, own
  reconnect + state replay; `@_silgen_name`, so no bridging-header edit).

What remains is one hunk set per owner, below. Everything is additive; record
types unknown to old readers pass through untouched, and a stock Xios app never
sends OUTPUT, so iosc without the app patch (and vice versa) keeps working.

## How rotation works (one paragraph)

UIKit rotates the app's scene, so the drawable is always upright; rotation for
the desktop is therefore a *resize plus metadata*. The app mirrors the new
interface orientation over the input socket (`XIOS_IN_OUTPUT`, transform 0/1/3;
both landscapes are "normal" because the launch shape is landscape). iosc swaps
its launch logical size on quarter-turns, reallocates the output IOSurface
(`xios_surface_resize`), rebinds GL (`iosc_gl_resize`), re-advertises
wl_output/xdg_output, re-lays-out layer chrome + toplevels, and drops present
clients — the app's existing `teardownIOSurface()`/reconnect path then adopts
the new surface, and `framebufferPoint()` remaps input from the new
`fbWidth/fbHeight` automatically. No compositor-side pixel rotation anywhere.

wl_output semantics (wlroots-style): with transform advertised, `mode` stays the
UNtransformed (natural landscape) pixels and clients derive logical by applying
transform + scale; xdg_output sends the post-transform logical directly. Escape
hatch `IOSC_NO_OUTPUT_TRANSFORM=1` advertises NORMAL with mode = actual buffer
dims (pure resize) in case some client starts pre-rotating buffers via
`set_buffer_transform` (iosc ignores those; none of GTK/Qt/SDL do this).

## Hunk kit A — linux-build/patches/xios/xios_surface.{c,h} (owner: iosc-protocols)

Additive; the DDX never calls the new symbol. Three parts.

**xios_surface.h** — after the `xios_surface_create` declaration:

```c
/* Replace the output IOSurface with a new width x height one (device rotation).
 * The new surface is created first — on failure the old stays live and NULL is
 * returned. On success the module geometry + the xios.json handshake file are
 * updated, every attached client is disconnected (the app re-runs the
 * rendezvous and adopts the new surface + geometry), and the NEW framebuffer
 * base is returned (same contract as xios_surface_create). */
void *xios_surface_resize(int width, int height, int *stride, int *alloc_size);
```

**xios_surface.c state** — next to `s_compositor_id`:

```c
static unsigned s_generation;        /* bumped by resize; stale handshakes closed */
static char s_sock_path_kept[256];   /* for the resize-time xios.json rewrite */
static char s_json_path_kept[256];
```

`xios_server_start()` stashes both paths (`snprintf` into the kept buffers) and
moves its json `fprintf` into a small `write_json(json_path, w, h, stride,
sock_path)` helper so resize can rewrite it.

**Factor allocation out of `xios_surface_create`** — the body from the
`IOSurfaceAlignProperty` call through the zeroing becomes

```c
static IOSurfaceRef make_surface(int width, int height, int *stride, int *alloc_size);
```

returning a zeroed surface (NULL on failure) WITHOUT touching `s_*`;
`xios_surface_create` calls it and then assigns `s_surface/s_width/s_height/
s_stride` exactly as today.

**Handshake race fix in `handle_client()`** — resize swaps the surface from the
compositor thread while the accept thread may be mid-handshake. Snapshot under
the lock and hand the surface to the delivery explicitly:

```c
pthread_mutex_lock(&s_lock);
IOSurfaceRef surf = s_surface ? (IOSurfaceRef)CFRetain(s_surface) : NULL;
int w = s_width, h = s_height, st = s_stride;
unsigned gen = s_generation;
pthread_mutex_unlock(&s_lock);
```

`deliver_surface_port(int pid, unsigned portname, IOSurfaceRef surf)` grows the
surface parameter (one call site); the reply + in-band HELLO use `w/h/st`;
`CFRelease(surf)` before return. `add_client(fd, typed, gen)` closes instead of
adding when `gen != s_generation` (the app just retries and gets the new
surface — without this a client that handshook during the swap would present a
dead surface forever).

**The resize itself:**

```c
void *xios_surface_resize(int width, int height, int *stride, int *alloc_size)
{
    int st = 0, alloc = 0;
    IOSurfaceRef ns = make_surface(width, height, &st, &alloc);
    if (!ns) return NULL;
    void *base = IOSurfaceGetBaseAddress(ns);

    pthread_mutex_lock(&s_lock);
    IOSurfaceRef old = s_surface;
    s_surface = ns;
    s_width = width; s_height = height; s_stride = st;
    s_generation++;
    for (int i = 0; i < s_nclients; i++) close(s_clients[i]);
    s_nclients = 0;              /* app re-handshakes -> new port + geometry */
    pthread_mutex_unlock(&s_lock);

    if (old) CFRelease(old);     /* ANGLE's pbuffer still retains it until
                                  * iosc_gl_resize() runs — call order matters */
    if (s_json_path_kept[0])
        write_json(s_json_path_kept, width, height, st, s_sock_path_kept);
    if (stride) *stride = st;
    if (alloc_size) *alloc_size = alloc;
    fprintf(stderr, "xios: output resized to %dx%d (clients dropped)\n", width, height);
    return base;
}
```

## Hunk kit B — wayland/iosc.c (owner: iosc-protocols)

Six pieces, all keyed to stable anchors.

**B1. Globals** (next to `g_width`/`g_height`):

```c
static int g_output_transform;         /* wl_output transform: 0/1/2/3 = 0/90/180/270 */
static int g_natural_lw, g_natural_lh; /* launch logical size = the transform-0 shape */
static int g_advertise_transform = 1;  /* IOSC_NO_OUTPUT_TRANSFORM=1 -> pure resize */
```

In `main()` after the `-logical` resolution block:

```c
g_natural_lw = output_logical_width();
g_natural_lh = output_logical_height();
if (getenv("IOSC_NO_OUTPUT_TRANSFORM")) g_advertise_transform = 0;
```

**B2. Track bound output resources** (today `output_bind` / `get_xdg_output`
are fire-and-forget, so there is nothing to resend state on). Mirror the
`g_kbd[]` pattern:

```c
#define IOSC_MAX_OUTPUT_RES 32
static struct wl_resource *g_output_res[IOSC_MAX_OUTPUT_RES];     static int g_noutput_res;
static struct wl_resource *g_xdg_output_res[IOSC_MAX_OUTPUT_RES]; static int g_nxdg_output_res;
```

with swap-remove destructors installed via the `wl_resource_set_implementation`
destroy slot (currently NULL) in `output_bind()` and
`xdg_output_manager_get()`, and an append (bounds-checked) at bind time.

**B3. `output_send_state()`** — transform-aware advertisement:

```c
int mode_w = g_width, mode_h = g_height;
int32_t tr = WL_OUTPUT_TRANSFORM_NORMAL;
if (g_advertise_transform) {
    tr = g_output_transform;
    if (g_output_transform & 1) { mode_w = g_height; mode_h = g_width; }
}
wl_output_send_geometry(r, 0, 0, output_px_to_mm(mode_w), output_px_to_mm(mode_h),
                        WL_OUTPUT_SUBPIXEL_UNKNOWN, "iosc", "IOSurface", tr);
wl_output_send_mode(r, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
                    mode_w, mode_h, 60000);
```

(rest unchanged — scale/name/description/done).

**B4. `output_reconfigure()`** — place after `xdg_output_manager_bind()`;
forward-declare next to the other file-top decls if anything complains:

```c
/* Reconfigure the output for a device rotation (XIOS_IN_OUTPUT): reallocate the
 * output IOSurface, rebind the GPU target, re-advertise wl_output/xdg_output,
 * re-lay-out chrome + windows; present clients were dropped by the resize and
 * the app reconnects to adopt the new surface. */
static void output_reconfigure(int lw, int lh, int transform)
{
    if (lw <= 0 || lh <= 0) return;
    if (lw == output_logical_width() && lh == output_logical_height() &&
        transform == g_output_transform)
        return;                        /* also swallows the app's 1 Hz resend */

    int pw = lw * output_scale(), ph = lh * output_scale();
    int stride = 0;
    void *fb = xios_surface_resize(pw, ph, &stride, NULL);
    if (!fb) {
        fprintf(stderr, "iosc: output resize %dx%d failed; keeping %dx%d\n",
                pw, ph, g_width, g_height);
        return;
    }
    g_fb = fb;
    g_stride = stride;
    g_width = pw;
    g_height = ph;
    g_output_transform = transform;

    if (iosc_gl_ok() && iosc_gl_resize(xios_get_output_iosurface(), pw, ph) != 0)
        fprintf(stderr, "iosc: GPU rebind failed -> CPU fallback\n");

    g_cursor_x = clampi(g_cursor_x, 0, output_logical_width() - 1);
    g_cursor_y = clampi(g_cursor_y, 0, output_logical_height() - 1);

    /* xdg_output logical first, then full wl_output state (ends in done). */
    for (int i = 0; i < g_nxdg_output_res; i++) {
        zxdg_output_v1_send_logical_position(g_xdg_output_res[i], 0, 0);
        zxdg_output_v1_send_logical_size(g_xdg_output_res[i],
                                         output_logical_width(), output_logical_height());
        if (wl_resource_get_version(g_xdg_output_res[i]) < 3)
            zxdg_output_v1_send_done(g_xdg_output_res[i]);
    }
    for (int i = 0; i < g_noutput_res; i++)
        output_send_state(g_output_res[i]);

    /* Panels re-anchor, maximized/fullscreen refit, floating windows keep their
     * size when it fits and clamp into the new work area. */
    for (int i = 0; i < g_nmapped; i++) {
        struct iosc_surface *s = g_mapped[i];
        if (s->role == IOSC_ROLE_LAYER && s->layer) {
            layer_send_configure(s);
        } else if (s->role == IOSC_ROLE_TOPLEVEL) {
            if (s->toplevel_fullscreen || s->toplevel_maximized) {
                toplevel_reconfigure_state(s);
            } else {
                int w = 0, h = 0, wx, wy, ww, wh;
                surface_display_size(s, &w, &h);
                work_area(&wx, &wy, &ww, &wh);
                int cw = (w > 0 && w <= ww) ? w : ww;
                int ch = (h > 0 && h <= wh) ? h : wh;
                if (w > ww || h > wh) toplevel_send_configure(s, cw, ch);
                s->dx = clampi(s->dx, wx, wx + ww - cw);
                s->dy = clampi(s->dy, wy, wy + wh - ch);
            }
        }
    }
    recomposite_all();
    wl_display_flush_clients(g_display);
    fprintf(stderr, "iosc: output now %dx%d logical, transform %d (%dx%d px)\n",
            output_logical_width(), output_logical_height(), transform, pw, ph);
}
```

**B5. Dispatch** — new case in `iosc_input_record()`:

```c
case XIOS_IN_OUTPUT: {
    int tr = (int)(m->code & 3u);
    int lw = m->x > 0 ? m->x : ((tr & 1) ? g_natural_lh : g_natural_lw);
    int lh = m->y > 0 ? m->y : ((tr & 1) ? g_natural_lw : g_natural_lh);
    output_reconfigure(lw, lh, tr);
    break;
}
```

(Note: `physical_to_logical()` is applied to `m->x/m->y` at the top of that
function for pointer types — OUTPUT carries logical sizes already, so the case
must read `m->x/m->y` raw, like the KEY case ignores them.)

**B6. Haptic broadcast** — next to `input_clients_send_traits()`:

```c
/* Shell chrome feels physical: a press landing on a layer surface (panel /
 * launcher / overview) fires a light impact in the app. Toplevels stay silent —
 * per-widget haptics inside apps would be noise. */
static void input_clients_send_haptic(uint32_t style)
{
    struct xios_in_msg msg = { .type = XIOS_IN_HAPTIC, .code = style };
    xios_input_socket_broadcast(g_input_sock, &msg, sizeof(msg));
}
```

plus a forward declaration above `handle_button()`, and two firing sites:

- `handle_button()`, inside `if (down && g_ptr_focus)`:
  `if (g_ptr_focus->role == IOSC_ROLE_LAYER) input_clients_send_haptic(0);`
- `handle_touch()` DOWN branch, after `hit` resolves:
  `if (hit && hit->role == IOSC_ROLE_LAYER) input_clients_send_haptic(0);`

## Hunk kit C — apps/Xios (owner: xios-app)

New files are committed and compile-checked; they are inert until hooked:

1. `XScreenView.start()` — one line (anywhere after `loadConfig()`):
   `SystemIntegration.shared.install(on: self)`
2. `project.yml` — allow all four orientations
   (`UISupportedInterfaceOrientations~ipad`: add Portrait +
   PortraitUpsideDown). To keep the pure-X/Xvfb backend landscape-locked
   (fixed-aspect letterbox is why portrait was banned), gate at runtime in
   `XServerViewController`:

   ```swift
   override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
       (view as? XScreenView)?.allowsAllOrientations == true ? .all : .landscape
   }
   ```

   with `var allowsAllOrientations: Bool { usingIosc }` exposed on XScreenView
   and `setNeedsUpdateOfSupportedInterfaceOrientations()` called when
   `loadConfig()` changes the input backend.
3. Optional, gesture track: call `SystemIntegration.shared.rightClickHaptic()`
   where the deferred long-press promotes to a right-click.

No present/input remap work: rotation reuses `teardownIOSurface()` reconnect,
and `framebufferPoint()` picks up the new `fbWidth/fbHeight` on adopt.

## Session + packaging (owners: gnome-session, audio-desktop, theme)

- gnome-session: autostart `xios-sysintd` inside the session (after the
  profile.d PULSE_SERVER export), e.g. in the xios.session wrapper next to
  xios-hwbridged. With it, hardware volume buttons move the PA sink -> gvc UI
  tracks them; gsd media-keys can STAY dropped (task #24).
- audio-desktop: sysintd defaults to sink `xios` (override `XIOS_SYSINT_SINK`);
  it shells out to `pactl` (pulseaudio-utils) and inherits PULSE_SERVER. Note:
  system volume still scales the RemoteIO output, so mirroring gives an
  effective v^2 curve — acceptable for v1, revisit if it feels steep.
- xios-desktop-theme: appearance flip writes `color-scheme`
  (prefer-dark/default) and, unless `XIOS_SYSINT_NO_GTK3=1`, `gtk-theme`
  Adwaita/Adwaita-dark (overridable via `XIOS_SYSINT_GTK3_LIGHT/_DARK`). Both
  are user-level dconf writes, so they win over the packaged gschema override
  exactly like a user toggle would.
- Packaging suggestion: ship `xios-sysintd` at `/var/jb/usr/libexec/` in the
  xios-desktop-defaults deb (it is flavor-neutral).

## Validation checklist (on device)

1. Rotate to portrait: desktop re-lays-out 1080x1440 logical, panel re-anchors,
   maximized kgx refits; `wayland-info` shows transform 1 + swapped logical.
   Touch accuracy after rotation (tap panel clock corner) — remap comes free
   from adopt, verify anyway.
2. Rotate back; repeat fast x5 (resize storm: no leak — watch iosc RSS; no
   stuck present client).
3. Volume buttons: `pactl get-sink-volume xios` tracks; gvc slider moves live.
4. iOS Settings dark toggle: GTK4 app flips (libadwaita), GTK3 app flips theme.
5. Panel tap: light impact. Long-press right-click: medium impact.
6. `IOSC_NO_OUTPUT_TRANSFORM=1` smoke run if any client renders sideways.
