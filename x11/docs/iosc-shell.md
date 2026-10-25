# iosc desktop shell — panel, launcher, overview, window management

**Status (2026-10-25): built and shipped** as `iosc-shell 0.9.14`, the `iosc`
preset of `xios-session`. The split-surface design in §0 is what exists:
`ioscbar`, `ioscdock`, `ioscoverview` and `ioscbg`, all layer-shell clients drawn
with cairo/pango. iosc has implemented layer-shell, foreign-toplevel and
screencopy since 0.9.0. Not built: server-side decorations (§5.5), the
`iosc_shell_v1` control protocol (§5.4), and the window-management polish in §6.
Current state and gotchas: `handoff/iosc-shell.md`; file map and build:
`apps/iosc-shell/README.md`.

This is **our own** shell for the `iosc` Wayland
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

## 0. Design vision: a hybrid tablet DE (mobile OS × desktop OS)

**Mandate (Max, 2026-07-01):** *"Think carefully about what a good tablet/phone
desktop environment is like — a MIX of a mobile OS and a desktop OS."* The north
star is NOT "a GNOME panel, smaller." It is a genuine synthesis: the touch-first,
glanceable, gesture-driven feel of iPadOS fused with the real windows,
multitasking and launchers of a desktop. The first shell (a top bar with
launchers + a taskbar + a status cluster) was a shrunk desktop; this section is
the rethink that should drive everything below.

### 0.1 What each side does well (and what we take)

| From mobile (iPadOS, Plasma Mobile, good launchers) | From desktop (GNOME, Plasma, elementary, macOS) |
|---|---|
| Big thumb-reachable targets; no hover-only affordances | Real overlapping/resizable windows; multitasking |
| A **dock** of favorites + running apps, always one thumb away | A **taskbar/switcher** for many windows |
| **Control Center**: swipe-down grid of big toggles + sliders | A system status area + settings |
| A **home/idle state** (wallpaper + dock) you always return to | Persistent launchers + a searchable app list |
| **Gestures**: swipe up = home/switcher, swipe down = control | Keyboard/pointer precision when a trackpad is attached |
| Translucency, depth, generous spacing, motion | Information density when you want it |

The synthesis: **touch-first, pointer-enhanced.** Every target is finger-sized
(≥44pt) and reachable; a mouse/trackpad (iPad supports both) adds hover states
and precise resize, but nothing REQUIRES a pointer. This is the opposite of the
old top-bar, whose 22px close-× and hover-only pills were pointer-only.

### 0.2 The core surfaces (what replaces the single top bar)

Four surfaces, each doing one job, instead of one bar doing four badly:

1. **Slim status bar (top, ~36 logical px, always visible).** Glanceable only:
   clock (center or left), and a right **status cluster** (battery, Wi-Fi, and
   indicators). It is the *pull-down handle* for Control Center and the exclusive
   zone that keeps windows from opening under it. NO launchers, NO taskbar here —
   those move to the dock. Think iPadOS status bar fused with GNOME's top bar,
   stripped to pure status.

2. **The dock (bottom, floating, the heart of the shell).** A centered, rounded,
   translucent pill: **favorites** (pinned launchers) · a divider · **running
   apps** (each a big icon with a running-dot; this is the "taskbar," but as a
   dock, tap-to-raise/tap-to-launch) · a divider · the **apps/overview button**.
   Big icons (≥48pt), generous spacing, hover-magnify with a pointer. This fuses
   the mac/iPadOS dock with the desktop taskbar — the one surface that is both
   your launcher and your window switcher. Auto-hides when a window is fullscreen
   (reveal by swiping up from the bottom edge / a mouse to the edge); always
   shown on the home/overview.

3. **Control Center (swipe down from the top-right, or tap the status cluster).**
   The quick-settings card, reframed as iPadOS Control Center: a grid of big
   rounded **toggle tiles** (Wi-Fi, Bluetooth, Rotation Lock, Dark Mode, Airplane,
   Screenshot) + **sliders** (Brightness, Volume) + a battery readout + (later) a
   media widget. Everything tappable, glanceable, no menus.

4. **Overview / Home (swipe up from the bottom, the apps button, or the idle
   state).** The full-screen home + switcher: a big **search** field, **open
   window cards** (live-ish thumbnails, tap to raise, swipe up to close), and the
   **app grid** below. This is GNOME Activities fused with the iPadOS App
   Switcher and Home Screen. When no window is focused, this (or just
   wallpaper+dock) is where you rest — a real home state, not a blank desktop.

### 0.3 The window model (mobile default, desktop on demand)

Tablet-native, escalating to desktop power:

- **Fullscreen-first.** One app fills the work area by default (mobile mental
  model). The dock + status bar frame it; the home indicator returns you home.
- **Split view.** Drag a window (or a dock icon) to a screen edge → it takes half,
  the other half offers the switcher (iPadOS Split View / desktop snap). iosc
  already has interactive move + clamp + maximize + `work_area()` — snap is a
  small addition (see §5.5).
- **Floating / Stage.** Power users get overlapping, resizable windows with the
  touch chrome from §5.5 (grab-handle + one big close, NO mac traffic lights).
  A "stage strip" of other window groups can live at the left edge (Stage Manager
  pattern) — future.
- The **overview** is the switcher between all of these.

### 0.4 Gestures + the home indicator

The gesture grammar (touch), each with a pointer/keyboard equivalent:

| Gesture | Action | Pointer/keys |
|---|---|---|
| Swipe **up** from bottom edge | Home / overview; reveal dock in fullscreen | Apps button; Super |
| Swipe **down** from top-right | Control Center | Tap status cluster |
| Swipe **down** from top-left | Notifications (later) | — |
| Swipe up **and hold** | App switcher (overview, window cards focused) | Super+Tab |
| A thin **home-indicator** pill at the bottom center | affordance for "swipe up"; drag it left/right to switch apps | — |

Gestures ride iosc's existing touch wire (`wl_touch`, type 6) + the AXIS/gesture
work (touch-scroll task); edge-swipes are the shell recognizing touch that starts
in an edge band. No new protocol for the basics.

### 0.5 Idle/home state + how shell and windows coexist

- **Idle/home:** wallpaper + dock + slim status bar. No window = you see home. A
  clock/date could sit large on the wallpaper (lock-screen-like) — optional.
- **In an app:** status bar always visible (thin, glanceable, exclusive). Dock
  auto-hides in fullscreen, one swipe away; always present in split/float/overview.
- **Translucency everywhere** (iosc's layer blend is live): the status bar, dock,
  and Control Center float as frosted glass over the wallpaper/windows, giving the
  depth that reads "modern tablet," not "opaque desktop panel."

### 0.6 What this means for the code (surfaces → clients)

Each surface is its own layer-shell client (the §1 architecture already supports
this cleanly):

| Surface | Client | Layer | Notes |
|---|---|---|---|
| Slim status bar | `ioscbar` | TOP, anchor top, exclusive | glanceable + CC handle |
| Dock | `ioscdock` (NEW) | TOP, anchor bottom, exclusive-or-autohide | favorites + running + apps btn |
| Control Center | spawned by the bar (as QS is today) | OVERLAY, anchor top-right | toggle grid + sliders |
| Overview / Home | `ioscoverview` (exists; reframe) | OVERLAY, fullscreen | search + cards + grid |
| Wallpaper | `ioscbg` (exists) | BACKGROUND | unchanged |

Implementation is split-shell: `ioscbar` owns status + Control Center,
`ioscdock` owns launchers + running apps, and `ioscbg`/`ioscoverview` keep their
single-purpose surfaces. The scale-invariance work (ui = logical_w / reference)
applies unchanged to every surface.

This is how it was built; the mockups are `apps/iosc-shell/design/vision-*.png`
and the real-layout renders are `design/preview-*.png`.

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

## 2. The shell clients (as built)

The first panel was one top bar (launchers, taskbar, clock) drawn with wl_shm and
an embedded 5x7 bitmap font, linking only libwayland-client. It proved the
layer-shell path end to end and was then replaced by the §0 split shell:

- `ioscbar` (`iosc-shell.c` run as `ioscbar`): TOP layer, anchored top,
  exclusive zone. Focused app name (with a Minimize/Maximize/Close menu through
  foreign-toplevel), clock, battery/wifi, and the Control Center trigger.
- `ioscdock` (same source, run as `ioscdock`): TOP layer, anchored bottom.
  Favorites, running windows with dots (tap to activate), the apps button.
- `ioscoverview`: OVERLAY layer, full output, on-demand keyboard. Search field,
  open-window chips and the app grid over a blurred screencopy backdrop.
- `ioscbg`: BACKGROUND layer. Wallpaper plus storage/memory/load/uptime cards and
  desktop pins.

Drawing is cairo/pango on wl_shm (`panel-render.h`, tokens in `shell-theme.h`),
scale-invariant against a 1440-wide reference. Launches `fork+exec` the
`.desktop` `Exec` line as `mobile` on a shared session bus; the shell does not
round-trip through ioscd for its own launches.

## 3. The app overview

A full-screen Activities-style grid: installed apps (from `.desktop`, the same
scan as the panel) plus thumbnails/buttons for running windows (from
foreign-toplevel). Summoned by a panel button, a hot-corner, or a gesture;
dismissed on launch/activate/Escape.

- **As a layer-shell client** on the `overlay` layer, full-output size,
  `keyboard_interactivity = on_demand` (so it can take type-to-search focus and
  be dismissed). Launch = `fork+exec` (apps) or `activate` (running windows).
- **Toolkit (as built):** cairo/pango on wl_shm, sharing the panel renderer, with
  real icons through GdkPixbuf/librsvg. GTK4 + gtk4-layer-shell stays available
  if a richer overview is ever wanted (§4).
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
| cairo/pango on wl_shm | all four shipped clients | shipped |
| wl_shm + embedded bitmap font | the first panel | retired |
| gtk4-layer-shell | a GTK4 overview, richer chrome, settings popovers | published as `gtk4-layer-shell 1.3.0+ios1`, not used by the shell |

gtk4-layer-shell 1.3.0 is shim-based (`src/libwayland-shim.c` +
`xdg-surface-server.c`): it intercepts libwayland-client and translates xdg-shell
to layer-shell, so it needs no private GTK headers and is not pinned to a GTK
micro version. Recipe: `linux-build/recipes/gtk4-layer-shell.mk`. Introspection,
vapi, examples, tests and smoke-tests are off (smoke-tests run example binaries,
which a cross build cannot do).

---

## 5. Compositor protocol hand-off (for the iosc maintainer)

> **Status:** §5.1 to §5.3 landed in iosc 0.9.0 (layer-shell v4,
> foreign-toplevel v3, screencopy v1, the work area and layer bands), so their
> step-by-step specs were removed. §5.4 and §5.5 are not built. The function
> names below still exist in `wayland/iosc.c`; the 2026-06-30 line numbers were
> dropped because they no longer match.

iosc already has the hard parts: a z-order list (`g_mapped[]`/`g_nmapped`,
, `surface_raise`, `keyboard_set_focus`,
`surface_at` hit-test, interactive move/resize
(`interactive_begin`/`_update`/`_end`,, per-commit GPU
recomposite (`recomposite_all`,, and the `wl_global_create` +
`*_bind` pattern (globals registered. The additions slot into
these.

### 5.1 to 5.3: layer-shell, foreign-toplevel, work area (landed)

What iosc implements for the shell:

- `zwlr_layer_shell_v1` + `zwlr_layer_surface_v1`: anchored surfaces on the
  background/bottom/top/overlay layers, exclusive zones that shrink the work area,
  keyboard interactivity none/exclusive/on-demand. Layer surfaces are blended
  with their alpha (that is what makes the bar and dock translucent) and get
  pointer and touch through the same role-agnostic pick as toplevels.
- `zwlr_foreign_toplevel_management_v1`: title, app id and state for every
  toplevel, plus activate, close, minimize and maximize requests.
- `zwlr_screencopy_v1` (software), used for the frosted backdrops because iosc
  does not blur.
- Work area and bands: cascade placement and interactive move/resize clamp to the
  work area; `surface_map` and `surface_raise` keep toplevels inside their band so
  shell layers stay above or below them; focus skips `keyboard_interactivity =
  none` layers.

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

**Status (2026-10-25): approved as direction, not built.** iosc still answers
every xdg-decoration request with client-side mode. The plan is a separate
`iosc_decoration.c` module, like the other pieces split out of `iosc.c`. This section is the build-to
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
| Floating windows, cascade | **Already exists**: `g_mapped[]` + cascade in `surface_map` | iosc.c |
| Title-bar drag → move | **Already exists**: `xdg_toplevel.move` → `interactive_begin(MOVE)` (header-bar drag from the toolkit, or server-side chrome) | iosc.c |
| Resize grip → resize | **Already exists**: `xdg_toplevel.resize` → `interactive_begin(RESIZE)` + `toplevel_send_configure` reflow | iosc.c |
| Tap/drag → bring to front | **Already exists**: `handle_button` → `surface_raise` + focus | iosc.c |
| **Drag-to-edge snapping + live preview** | Add snap-zone detection to `interactive_update` MOVE: when the cursor enters a left/right/top edge band, draw a translucent preview quad (a new pass in `recomposite_all`) at the target rect; on `interactive_end` animate `dx,dy,configure` to the zone rect. Zone rects use the **work area** (§5.1). This is carplayhost's `snapZoneForPoint`/`rectForZone`, server-side. | new, iosc.c |
| **Tile-4 / halves / quadrants** | An `iosc_shell_v1.tile(layout)` (§5.4), or a key or gesture, arranges the top N toplevels into a grid: set each `dx,dy` + `toplevel_send_configure(w,h)` (clients reflow exactly as carplayhost's `deliverSceneSize` did). | §5.4 + iosc.c |
| **Active/inactive focus dimming** | In `composite_one` draw non-`g_kbd_focus` toplevels with a slight dim overlay; brighten the focused one. carplayhost's `updateFocusStates`. | new, iosc.c |
| **macOS title bar + traffic lights** | Two options. (a) **Client-side** (default today): iosc advertises `zxdg_decoration` and configures client-side; GTK draws its own header bar, looks native to the toolkit. (b) **Server-side native chrome**: switch decoration mode to server-side and have iosc draw a title bar + ×/−/+ as GPU quads above each toplevel with hit regions → the exact carplayhost look, app-agnostic. (b) is a larger feature; recommend (a) first. | iosc.c |
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

Done: layer-shell and foreign-toplevel in iosc, the split shell (bar, dock,
overview, wallpaper with widgets), gtk4-layer-shell packaged.

Next, in rough order:

1. Server-side decorations, the touch title bar in §5.5 (also split snap, which
   can land on its own).
2. `iosc_shell_v1` (§5.4) for gesture-summoned overview, tiling and thumbnails.
3. Window-management polish from §6: drag-to-edge snapping with preview, tile-4,
   focus dimming.
4. Live window thumbnails in the overview, sampling each toplevel's IOSurface.
