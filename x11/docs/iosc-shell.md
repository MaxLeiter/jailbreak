# iosc desktop shell — panel, launcher, overview, window management

Status: design + a buildable first panel (cross-compiles for iOS; runs once iosc
ships `zwlr_layer_shell_v1`). This is **our own** shell for the `iosc` Wayland
compositor — the chrome that makes it feel like a desktop, not just floating app
windows. It is the in-desktop counterpart to `apps/iosc-desktop/`
(`docs/iosc-desktop-env.md`), which turns Linux apps into iOS Home Screen icons;
this builds the panel / launcher / overview you see *inside* the Xios display.

It deliberately does **not** depend on the gnome-shell / Mutter route
(`docs/mutter-on-iosc.md`). Both can target iosc; this one is lightweight, ours,
and ships now.

Code: `apps/iosc-shell/` (the panel client + build). Prior art reused as
*patterns, not coupling*: the carplayhost macOS-style iPad window manager (see
the `carplay-ipad-project` memory) — floating windows, drag-to-edge snapping,
tile-4, focus dimming, dock magnify.

---

## 1. The decision: layer-shell clients, not chrome baked into iosc

**Recommendation: iosc implements `zwlr_layer_shell_v1`, and every shell
component (panel, launcher, overview) is a separate Wayland client that binds it.
The shell is NOT drawn inside `iosc.c`.**

This is the standard wlroots desktop architecture — waybar, wofi, swaybg, mako
are all layer-shell clients of a compositor that implements the protocol. The
compositor stays a compositor; the shell is a replaceable set of programs.

| | **Layer-shell clients (recommended)** | **Built into `iosc.c`** |
|---|---|---|
| Coupling | Shell is separate processes; iosc only gains a well-defined protocol | Shell logic lives in the contended `iosc.c` |
| Replaceable | Swap the panel binary; try GTK4 vs custom; run none | Recompile iosc to change the clock |
| Drawing | A real toolkit (or cairo, or our wl_shm font) with text/layout/hit-testing for free | Raw GL quads in C — reinvent text + layout + input |
| Crash domain | A panel crash doesn't take down the compositor | A shell bug can wedge the whole display |
| iosc churn | iosc edits are isolated protocol impls (review once) | Every shell tweak touches the live file other agents commit |
| Cost | iosc must implement layer-shell (~250–350 lines) + foreign-toplevel (~200) | No new protocol, but a much larger, riskier `iosc.c` |

The one real argument for "built in" is that the compositor already has the
window list and z-order in-process, so a taskbar needs no IPC. But that is
exactly what `zwlr_foreign_toplevel_management_v1` standardises — the window list
*as a protocol* — so we get the taskbar without coupling. And note the carplayhost
precedent cuts the other way: it had to reimplement an entire WM only because
UIKit/SpringBoard gave it **no** window model. iosc already **is** the window
manager. We are not rebuilding that engine; we are exposing it over standard
protocols and adding a thin client on top.

**Net:** the shell is decoupled and replaceable, it reuses our proven
GTK4-on-iosc stack when we want rich UI, and — operationally important right now —
it keeps shell work out of `iosc.c`, which is a live, multi-agent file. iosc's
only additions are two isolated, well-specified protocol implementations (§5).

### What lives where

```
   ┌──────────────────────────────────────────────────────────────┐
   │ Xios.app  — presents iosc's output IOSurface via Metal        │
   └───────────────▲──────────────────────────────────────────────┘
                   │ output IOSurface (mach port)
   ┌───────────────┴──────────────────────────────────────────────┐
   │ iosc (compositor)                                             │
   │  • core WM it ALREADY has: z-order list, surface_raise,       │
   │    interactive move/resize, focus, GPU composite              │
   │  • NEW: zwlr_layer_shell_v1   (anchored shell surfaces)        │
   │  • NEW: zwlr_foreign_toplevel_management_v1  (window list)     │
   │  • LATER: server-side snap/tile + iosc_shell_v1 (overview/WM)  │
   └──▲───────────────▲───────────────▲───────────────▲────────────┘
      │ layer surface  │ layer surface  │ xdg_toplevel  │ foreign-toplevel
   ┌──┴─────┐   ┌──────┴──────┐   ┌─────┴──────┐  (the panel also binds this to
   │ panel  │   │  overview   │   │  apps      │   list/raise/close windows)
   │(ours)  │   │ (ours/GTK4) │   │ kgx, gtk4… │
   └────────┘   └─────────────┘   └────────────┘
```

The shell components are **layer-shell clients**; apps are ordinary
**xdg-shell** clients; the panel additionally binds **foreign-toplevel** to drive
the taskbar. Nothing in the shell reaches into iosc except through these
protocols.

---

## 2. The panel (`apps/iosc-shell/ioscpanel.c`)

A single anchored bar across the top edge:

```
[ launcher tiles … | taskbar: open windows … | HH:MM ]
```

- **Layer:** `top`, anchored `top|left|right`, `set_size(0, 44)` (width 0 = span
  the output), `set_exclusive_zone(44)` so maximized toplevels don't draw under
  it. `keyboard_interactivity = none` (a panel wants pointer, never keyboard).
- **Launcher tiles** (left): up to 8 quick-launch buttons scanned from
  `/var/jb/usr/share/applications/*.desktop` (`Name`, `Exec` with freedesktop
  field codes stripped, `NoDisplay` filtered). A tap `fork+exec`s the app under
  the same Wayland/dbus env `run-kgx.sh` proved good (`WAYLAND_DISPLAY`,
  `GDK_BACKEND=wayland`, `dbus-run-session`, `GSETTINGS_BACKEND=memory`, …). The
  panel runs outside the iOS app sandbox (started by `ioscd` / a run-script), so
  it can spawn directly — no `ioscd` round-trip needed for its own launches.
- **Taskbar** (center): one button per open toplevel via
  `zwlr_foreign_toplevel_management_v1`. Shows the title; a tap calls
  `zwlr_foreign_toplevel_handle_v1.activate(seat)` → iosc raises + focuses that
  window; the active window's button is marked. **Degrades gracefully:** if iosc
  doesn't advertise the foreign-toplevel global yet, this region is simply empty
  and the panel still shows launcher + clock.
- **Clock** (right): `HH:MM`, repainted on the minute boundary via a `poll()`
  timeout folded into the wl event loop (no `timerfd` — a pure wl_client needs
  only libwayland-client; `timerfd` is a Linux/epoll-shim API iosc needs but a
  client should not).

**Rendering is wl_shm + a tiny embedded 5x7 bitmap font — zero toolkit deps.**
This is deliberate for first light: the panel is small and static, so the CPU
path costs nothing and keeps the binary self-contained (it links *only*
libwayland-client). The "native and fast" north star (`x11-native-fast-priority`)
applies to the per-frame app path, not a 44px bar that repaints once a minute;
the GPU/IOSurface budget is better spent on the heavier **overview** (§3) and on
app windows. If we later want crisp anti-aliased panel text, the upgrade is
gtk4-layer-shell (§4), not hand-rolled GL.

The panel scales logical→physical by the output scale so it stays crisp on the
retina IOSurface (`IOSC_PANEL_SCALE`, default 2).

### Build status (done) and the gaps (flagged)

**Done:** `ioscpanel.c` + the generated protocol code **cross-compile to iOS
arm64** through the Procursus cctools toolchain (`aarch64-apple-darwin-clang`,
iPhoneOS SDK) — validated in `procursus-xbuild:bookworm-arm64`. `build-panel.sh`
runs the full pipeline (wayland-scanner codegen → compile → link →
`ldid -Spanel-ent.xml`). See `apps/iosc-shell/README.md` for the exact run.

**Gap 1 — the link needs the W0 iOS `libwayland-client.dylib.`** The compile
(source + headers, validated) is done; the final link resolves the `wl_*` /
`zwlr_*` symbols against the W0 wayland build (`wayland-w0-ios-build`).
`build-panel.sh` auto-extracts it from `libwayland-dev_*.deb` in the repo; point
`SYSROOT=` at an extracted tree otherwise. This is the same sysroot iosc links —
no new dependency, just wiring.

**Gap 2 — iosc must implement `zwlr_layer_shell_v1` before the panel can map.**
This is the real blocker: there is nothing for a layer surface to bind until
iosc ships §5.1. The panel exits with a clear message
(`compositor lacks zwlr_layer_shell_v1`) on a compositor that doesn't have it.

**Gap 3 — taskbar needs `zwlr_foreign_toplevel_management_v1` (§5.2)** for the
window list. Until then the taskbar is empty (graceful).

So the panel is **buildable today**; it becomes **runnable** the moment iosc
lands §5.1, and **fully featured** when §5.2 lands. Both are isolated, additive
iosc changes specified below.

---

## 3. The app overview

A full-screen Activities-style grid: installed apps (from `.desktop`, the same
scan as the panel) plus thumbnails/buttons for running windows (from
foreign-toplevel). Summoned by a panel button, a hot-corner, or a gesture;
dismissed on launch/activate/Escape.

- **As a layer-shell client** on the `overlay` layer, full-output size,
  `keyboard_interactivity = on_demand` (so it can take type-to-search focus and
  be dismissed). Launch = `fork+exec` (apps) or `activate` (running windows).
- **Toolkit:** for a first cut the same wl_shm + bitmap-font client can draw an
  icon grid (reusing the panel's renderer). For the richer version (real icons,
  search field, animations) the natural fit is **GTK4 + gtk4-layer-shell** — we
  already run GTK4 on iosc (M4/M6). That makes the overview a normal GTK4 app
  that happens to be a layer surface. See §4 for the gtk4-layer-shell gap.
- **Summon path:** the panel's launcher button can `fork+exec` the overview
  binary, OR — cleaner — a compositor gesture (four-finger-up / hot-corner) routed
  through the optional `iosc_shell_v1` control protocol (§5.4) toggles it. The
  decoupled v1 is "panel button spawns `iosc-overview`"; the polished version is
  a compositor gesture.

The overview is the natural home for the GPU/IOSurface budget: live window
thumbnails are just the toplevels' own IOSurfaces sampled as textures — iosc
already imports and composites client IOSurfaces zero-copy (M2/M3), so a
thumbnail grid is "draw each toplevel's texture into a cell," not a screenshot.
That is a compositor-side capability worth exposing later (a `thumbnail` request
on `iosc_shell_v1`), but it is **phase 2**; the decoupled icon-grid overview
ships first.

---

## 4. Toolkit choice for the shell clients

| Path | Use for | Status |
|---|---|---|
| **wl_shm + embedded bitmap font** (this repo) | the panel; a first icon-grid overview | **Working** — self-contained, links only libwayland-client, cross-compiles for iOS today |
| **gtk4-layer-shell** | the polished overview, a richer panel, settings popovers | **BUILT for iOS** — `gtk4-layer-shell_1.3.0_iphoneos-arm64.deb` in `linux-build/out/` |

**gtk4-layer-shell — built.** `gtk4-layer-shell` lets a GTK4 app become a layer
surface. v1.3.0 is **shim-based** (`src/libwayland-shim.c` + `xdg-surface-server.c`):
it intercepts libwayland-client and translates xdg-shell → layer-shell, so —
unlike the old `gtk-priv` approach — it needs **no** private GTK/GDK headers and
is **not** pinned to an exact GTK micro version. That removed the one real risk.
It is cross-compiled and packaged via the Procursus pipeline against our existing
GTK4 + Wayland stack: recipe `linux-build/recipes/gtk4-layer-shell.mk` +
`build_info/gtk4-layer-shell.control` + `build-gtk4-layer-shell.sh`, output
`linux-build/out/gtk4-layer-shell_1.3.0_iphoneos-arm64.deb` (ships
`libgtk4-layer-shell.0.dylib` + `liblayer-shell-preload.dylib` + headers + .pc;
`otool -L` confirms it links `@rpath/libgtk-4.1.dylib` + `libwayland-client.0`).
Build knobs: introspection/vapi OFF (the gnome module's g-ir-scanner is the
on-device scan path, not needed for the C API), examples/tests/docs/smoke-tests
OFF (smoke-tests *run* example binaries — impossible when cross-compiling).

So the rich path's library prerequisite is **done**. The remaining prerequisite
is the same one the wl_shm panel has: iosc must implement `zwlr_layer_shell_v1`
(§5.1). Building the protocol once unlocks both the lightweight and the GTK4
path. **Recommendation:** still ship the custom wl_shm panel first (proves the
protocol end-to-end with a tiny client), then build the overview as a GTK4 +
gtk4-layer-shell app — de-risks by separating "is iosc's layer-shell correct?"
from "does the heavy toolkit map?"

---

## 5. Compositor protocol hand-off (for the iosc maintainer)

> **This section is the precise, liftable spec of the iosc-side work.** Route to
> whoever owns `iosc.c` when it is free. Everything here is **additive** and does
> not rework the existing stacking/input/compositing. Line numbers are against
> `wayland/iosc.c` as read on 2026-06-30.

iosc already has the hard parts: a z-order list (`g_mapped[]`/`g_nmapped`,
iosc.c:204), `surface_raise` (iosc.c:2431), `keyboard_set_focus` (iosc.c:2276),
`surface_at` hit-test (iosc.c:1699), interactive move/resize
(`interactive_begin`/`_update`/`_end`, iosc.c:1399–1465), per-commit GPU
recomposite (`recomposite_all`, iosc.c:428), and the `wl_global_create` +
`*_bind` pattern (globals registered iosc.c:3388–3404). The additions slot into
these.

### 5.1 `zwlr_layer_shell_v1` + `zwlr_layer_surface_v1` (MUST — unblocks the panel)

Vendored protocol: `apps/iosc-shell/protocols/wlr-layer-shell-unstable-v1.xml`.
Generate the **server** header + private code with wayland-scanner (the same
1.21-scanner-vs-1.23-libs path the M1 build already uses) and add the global.
Implement **version 4** (panel needs anchor/size/exclusive-zone/margin/
keyboard-interactivity; v4 adds `on_demand` keyboard).

**State to add.** Extend `enum iosc_role` (iosc.c:114) with `IOSC_ROLE_LAYER`,
and add to `struct iosc_surface` (iosc.c:151):

```c
struct iosc_layer_state {                 /* allocated when role == LAYER */
    struct wl_resource *resource;         /* zwlr_layer_surface_v1 */
    uint32_t layer;                        /* 0 bg,1 bottom,2 top,3 overlay */
    uint32_t anchor;                       /* bitfield: top|bottom|left|right */
    int32_t  excl_zone;                    /* set_exclusive_zone */
    int32_t  margin_t, margin_r, margin_b, margin_l;
    uint32_t kbd_interactivity;            /* none/exclusive/on_demand */
    int32_t  req_w, req_h;                 /* set_size (0 = compositor decides) */
    int      acked, configured;
    char     namespace[64];
};
```

**Requests (zwlr_layer_surface_v1):** store `set_anchor` / `set_size` /
`set_exclusive_zone` / `set_margin` / `set_keyboard_interactivity` / `set_layer`
into the state (double-buffered: apply on `wl_surface.commit`, like the existing
pending/current buffer flow). `ack_configure` sets `acked`. `get_popup` may
no-op initially (panels don't need it; iosc already has xdg_popup). `destroy`
tears down.

**get_layer_surface + the initial-configure handshake.** Per protocol: the
client commits with **no buffer**; iosc replies `configure(serial, w, h)`; the
client acks and attaches a buffer to map. So:

1. `get_layer_surface(id, surface, output, layer, namespace)` → assign
   `IOSC_ROLE_LAYER`, allocate `iosc_layer_state`, create the resource.
2. On the first `wl_surface.commit` with no buffer, compute the size from anchor
   + `req_w/req_h` + output dims (see placement) and send
   `zwlr_layer_surface_v1_send_configure(res, serial, cw, ch)`.
3. On the next commit (buffer attached, after `acked`) → `surface_map(s)`.

**Placement (compute `s->dx,s->dy` and the served size).** Logical output is
`output_logical_width()/height()` (iosc.c:89). For anchor `A`, margins `m*`,
requested `req_w/req_h`:

- width: if `req_w>0` use it; else if anchored `left&right` span
  `output_logical_width() - m_l - m_r`; else center. Height symmetric.
- x: anchored `left` → `m_l`; `right` → `output_w - cw - m_r`; both/neither →
  centered. y symmetric.
- The panel case (`anchor=top|left|right`, `req=(0,44)`) → full width at y=0,
  height 44. Send `configure(serial, output_logical_width(), 44)`.

**Exclusive zone = the work area.** Maintain four accumulators
`g_excl_top/bottom/left/right` summed over mapped layer surfaces with
`excl_zone>0` on that edge. Expose a `work_area(x,y,w,h)` helper = the output
minus those edges. Then make existing toplevel geometry respect it (small,
localized edits):

- `surface_map` cascade origin (iosc.c:518) starts at `(g_excl_left+40,
  g_excl_top+40)` instead of `(40,40)` so new windows don't open under the panel.
- `interactive_update` MOVE/RESIZE clamps (iosc.c:1428–1446) use the work area
  instead of the full output, so dragging/maximize stops at the panel.
- maximize/fullscreen target rects use the work area (fullscreen may opt to
  ignore it; maximize should not).

**Z-order: bands.** Today `g_mapped` is one flat list, cascade-ordered, and
`surface_raise` moves a surface to the very top (iosc.c:2431–2438). Introduce a
**z-band key** so layers stack correctly:

```c
/* band: 0 background < 1 bottom < 2 normal toplevels < 3 top < 4 overlay */
static int surface_band(struct iosc_surface *s){
    if (s->role == IOSC_ROLE_LAYER)
        return s->layer->layer >= 2 ? (s->layer->layer == 3 ? 4 : 3)
                                    : (s->layer->layer == 1 ? 1 : 0);
    return 2; /* toplevels/popups */
}
```

Keep `g_mapped[]` sorted by `(band, insertion order)`:
- `surface_map` inserts at the **end of its band** (find the first index whose
  band is greater), not unconditionally at `g_nmapped`.
- `surface_raise` (iosc.c:2431) clamps to within-band: move `s` to the top of
  its band, i.e. just below the first higher-band surface, not to absolute top.
  (One-line change: compute the band's upper bound and move there.)
- `recomposite_all` (iosc.c:428) is unchanged — it already paints `g_mapped`
  back-to-front; correct banding makes background/bottom paint under toplevels
  and top/overlay (the panel) paint over them automatically.

**Input.** `surface_at` (iosc.c:1699) already returns the top-most surface at a
point — include layer surfaces so panel clicks hit the panel. Two guards in
`handle_button` (iosc.c:2440): (a) clicking a layer surface must **not** call
`surface_raise`/`keyboard_set_focus` if its `kbd_interactivity == none` (a panel
should never steal keyboard focus and never reorder out of band — the band clamp
already prevents reordering, but skip the focus call for `none`); (b) pointer
button/motion/enter/leave still forward to the layer client normally so it gets
its clicks. An `on_demand` layer (the overview) *does* take focus on click.

**Effort:** ~250–350 lines, isolated to a new block + the small banding/work-area
edits noted. No change to the IOSurface/GPU path.

### 5.2 `zwlr_foreign_toplevel_management_v1` (SHOULD — unblocks the taskbar)

Vendored: `apps/iosc-shell/protocols/wlr-foreign-toplevel-management-unstable-v1.xml`.
Implement **version 3**. This exposes the window list as a protocol so the panel
taskbar (and the overview) can enumerate, label, and act on toplevels.

**Prerequisite — store title + app_id (iosc.c:1470–1471).** Today
`xt_set_title` and `xt_set_app_id` only `fprintf` and discard. Store them on
`struct iosc_surface` (`char title[]`, `char app_id[]`; free on destroy). This is
the **same** storage the iosc-desktop-env doc §7 already requests for
raise-on-retap — one change serves both.

**Manager global.** `wl_global_create(&zwlr_foreign_toplevel_manager_v1_interface,
3, ...)`. Keep a list of bound managers. On bind, replay current state: for each
mapped toplevel send `manager.toplevel(new handle)` then the handle's
`app_id`/`title`/`state`/`output_enter`/`done`.

**Per-toplevel handle.** Store a `struct wl_resource *` list of handles per
toplevel (one per bound manager). Emit:
- on toplevel **map** (`surface_map` for a TOPLEVEL role) → new handle to every
  manager + `title`/`app_id`/`done`.
- on **title/app_id change** (the now-storing setters) → `title`/`app_id` +
  `done`.
- on **activation/maximize/minimize/fullscreen** change → `state` (a `wl_array`
  of state enums; set `ACTIVATED` when `s == g_kbd_focus`) + `done`. Hook the
  existing focus change in `keyboard_set_focus` (iosc.c:2276) and the
  maximize/fullscreen setters.
- on **unmap/destroy** → `closed` + destroy the handles.

**Handle requests (start with two, the panel only needs these):**
- `activate(seat)` → `surface_raise(s)` + `keyboard_set_focus(s)` +
  `recomposite_all()` (exactly what `handle_button` does on click, iosc.c:2447).
- `close()` → `xdg_toplevel_send_close(s->xdg_toplevel)`.
- `set_maximized`/`set_minimized`/`set_fullscreen`/`unset_*` → reuse the existing
  toplevel state setters (nice-to-have; not needed for v1 of the taskbar).

**Effort:** ~200 lines, additive; the only edit to existing code is the
title/app_id storage + firing `state` from the existing focus path.

### 5.3 The work-area + band changes are the only edits to existing behavior

To be explicit for review: outside the two new protocol blocks, the *only*
touches to current logic are (a) cascade origin uses the work area
(iosc.c:518), (b) interactive-move/resize clamp uses the work area
(iosc.c:1428–1446), (c) `surface_map` inserts within band, (d) `surface_raise`
clamps within band (iosc.c:2436), (e) `handle_button` skips focus for
`kbd none` layers (iosc.c:2447), (f) title/app_id are stored not discarded
(iosc.c:1470). Each is a few lines. The GPU compositor, IOSurface import, buffer
handling, and input transport are untouched.

### 5.4 `iosc_shell_v1` — optional custom control protocol (PHASE 2)

For shell-driven window management beyond what foreign-toplevel covers (tiling
layouts, overview toggle, live thumbnails), add a tiny custom protocol the shell
binds. This is **not** needed for the panel or a basic overview; it is the clean
home for the carplayhost-style features in §6 once we want them:

```
interface iosc_shell_v1 {
    request tile(uint layout)        // 0 none,1 LR-halves,2 grid4,3 left,4 right…
    request toggle_overview()
    request set_focus_follows(uint)  // focus model
    event   gesture(uint kind)       // e.g. 4-finger-up → overview (from iosc input)
    request thumbnail(toplevel_handle, new_id wl_buffer)  // live window preview
}
```

Prefer this over a control socket (the iosc-desktop-env `iosc-wm.sock` idea): the
shell is already a wl client, so a protocol is in-band, typed, and lifecycle-tied.
Keep it out of scope until §5.1/§5.2 are landed and the decoupled panel/overview
are real.

### 5.5 Server-side decorations: the tablet touch chrome (APPROVED, post-refactor)

**Status (2026-07-01):** approved as direction by the lead per Max's tablet-DE
guidance; **held until after the iosc.c refactor** (docs/refactor-plan.md) and
then lands as a fresh `iosc_decoration.c` module. This section is the build-to
spec so implementation needs no guessing. The rendered reference is
`mock_window()` in `apps/iosc-shell/preview-host.c` and
`design/preview-desktop.png`.

**Why SSD:** the title bar + traffic-light dots Max sees today are GTK's
client-side decorations — iosc replies `MODE_CLIENT_SIDE` to every
xdg-decoration request and draws no chrome. The touch chrome requires iosc to
reply `MODE_SERVER_SIDE` (GTK then drops its CSD), render the bar into the
composite, and hit-test it (close, drag-to-move).

All values in **logical px** on the 1440x1080 desktop (scale-2 buffers).
Conversion: 1 logical px = 0.75 iOS pt at the net-1.5 output, so the 44 iOS pt
touch minimum = 59 logical px (`TH_TOUCH` 60 in shell-theme.h).

| Element | Spec |
|---|---|
| Title bar | 56 tall; shares the body's 18 corner radius (square bottom edge); fill `0xFF2E2E32` (one dark chrome variant for all windows) |
| Grab handle | 48 x 5 pill, radius 2.5, horizontally centered, 9 from the bar's top edge; `0x40FFFFFF` |
| Title | Sans Medium 17 (SF on device), horizontally centered, vertical center at `bar_h - 21` (lower half, below the handle); `0xA6EBEBF5` |
| Close (visual) | 36-diameter circle centered at `(w - 32, bar_h/2)` — 14 inset from the right edge to the circle's edge; fill `0x2EFFFFFF`; centered "x" in Sans 17, `0xA6EBEBF5` |
| Close (hit) | the rightmost **60 x 56** of the bar (>= TH_TOUCH), NOT just the circle |
| Drag-to-move | every bar pixel outside the close hit zone |
| Unfocused state | same bar fill; dim the content: title + close glyph `0x59EBEBF5`, handle `0x26FFFFFF`, close circle fill `0x1FFFFFFFu` |
| Pressed close | circle fill brightens to `0x47FFFFFFu` (press feedback before destroy) |
| Shadow (mock) | rrect at +3/+7, radius 20, `0x59000000` — match iosc's existing shadow if one exists; non-critical |

**Split snap (self-contained; can land independently of SSD):** during an
interactive move, 32-px edge bands map to placement on release — left band →
tile to the left half of `work_area()`, right band → right half, top band →
maximize. Escape (or moving out of the band) cancels. Builds directly on the
existing interactive move + clamp + maximize + work-area machinery.

---

## 6. Mapping the carplayhost WM patterns onto iosc

The carplayhost macOS-style window manager (carplay-ipad-project memory) is the
design reference for *feel*. The crucial difference: **carplayhost had to build a
window model from nothing** (host a live app scene in a `UIWindow`, fake stacking,
catch SpringBoard asserts). **iosc already has the model** — independent Wayland
surfaces, a real z-order list, server-owned geometry, input routing. So each
carplayhost feature becomes *logic added to iosc's existing move/stack/configure
code*, not a from-scratch engine, and most of it is compositor-side (only the
compositor can move/stack/resize windows).

| carplayhost feature | iosc mapping | Where |
|---|---|---|
| Floating windows, cascade | **Already exists** — `g_mapped[]` + cascade in `surface_map` | iosc.c:512 |
| Title-bar drag → move | **Already exists** — `xdg_toplevel.move` → `interactive_begin(MOVE)` (header-bar drag from the toolkit, or server-side chrome) | iosc.c:1399 |
| Resize grip → resize | **Already exists** — `xdg_toplevel.resize` → `interactive_begin(RESIZE)` + `toplevel_send_configure` reflow | iosc.c:1413,1449 |
| Tap/drag → bring to front | **Already exists** — `handle_button` → `surface_raise` + focus | iosc.c:2447 |
| **Drag-to-edge snapping + live preview** | Add snap-zone detection to `interactive_update` MOVE (iosc.c:1425): when the cursor enters a left/right/top edge band, draw a translucent preview quad (a new pass in `recomposite_all`) at the target rect; on `interactive_end` animate `dx,dy,configure` to the zone rect. Zone rects use the **work area** (§5.1). This is carplayhost's `snapZoneForPoint`/`rectForZone`, server-side. | new, in iosc.c:1419 + 1453 |
| **Tile-4 / halves / quadrants** | An `iosc_shell_v1.tile(layout)` (§5.4) — or a key/gesture — arranges the top N toplevels into a grid: set each `dx,dy` + `toplevel_send_configure(w,h)` (clients reflow exactly as carplayhost's `deliverSceneSize` did). | §5.4 + iosc.c:1322 |
| **Active/inactive focus dimming** | In `composite_one` (iosc.c:398) draw non-`g_kbd_focus` toplevels with a slight dim overlay; brighten the focused one. carplayhost's `updateFocusStates`. | new, in iosc.c:398 |
| **macOS title bar + traffic lights** | Two options. (a) **Client-side** (default today): iosc advertises `zxdg_decoration` and configures client-side (iosc.c:959) — GTK draws its own header bar, looks native to the toolkit. (b) **Server-side native chrome**: switch decoration mode to server-side and have iosc draw a title bar + ×/−/+ as GPU quads above each toplevel with hit regions → the exact carplayhost look, app-agnostic. (b) is a larger feature; recommend (a) first. | iosc.c:959 |
| Minimize/restore (genie) | `set_minimized` via foreign-toplevel (§5.2) → remove from `g_mapped` (keep the surface), animate; restore re-inserts. | §5.2 |
| Dock magnify, running-dot | Panel/overview client-side polish (the taskbar already marks the active window; magnify is a panel render effect). | panel |
| System-UI coordinator (hide chrome under CC/switcher) | **N/A** — there is no SpringBoard here; iosc owns the whole surface. The entire class of carplayhost bugs (windows above Control Center, caught `BSAssert`s, passthrough hit-testing) simply does not exist. | — |

**Takeaway:** the snapping math, tile layouts, and focus dimming port over as
*algorithms*; the heavy carplayhost plumbing (scene hosting, assert-catching,
passthrough windows, the dock-mirror) is unnecessary because Wayland gives us real
windows. The window-management polish is a set of localized additions to iosc's
existing interactive-move and composite passes, gated behind §5.4 where it needs
shell triggers.

---

## 7. Roadmap

1. **iosc: `zwlr_layer_shell_v1`** (§5.1). Unblocks the panel + the overview +
   gtk4-layer-shell. *The one true prerequisite.*
2. **Panel runnable** — link against the W0 sysroot (§2 gap 1) + run on-device
   against the layer-shell-capable iosc. First visible shell chrome.
3. **iosc: `zwlr_foreign_toplevel_management_v1`** (§5.2). Taskbar lights up.
4. **Overview v1** — **built** (`apps/iosc-shell/ioscoverview.c`): icon grid +
   open-windows row as a full-screen wl_shm OVERLAY layer surface, sharing the
   panel's renderer (`shell-draw.h`); tap to launch/raise, Escape/background tap
   to dismiss. Panel button (or a gesture) spawns it. Runs once §5.1 lands.
5. **gtk4-layer-shell** (§4) — **built** (`linux-build/out/gtk4-layer-shell_1.3.0_iphoneos-arm64.deb`); ready for the richer GTK4 overview / chrome once §5.1 lands.
6. **Window-management polish** (§6) — `iosc_shell_v1` (§5.4), server-side
   drag-to-edge snapping, tile-4, focus dimming, optional native chrome.
7. **Live window thumbnails** in the overview (compositor samples each toplevel's
   IOSurface — the GPU budget's best use here).

Steps 1–4 give a real desktop: a panel with clock + launcher + working taskbar,
and an app overview — all decoupled layer-shell clients over two standard
protocols, with `iosc.c` gaining only isolated, additive code.
