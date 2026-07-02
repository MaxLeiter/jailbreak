# Xios compositor — per-window forwarding shell (design)

Status: design only (no code here). Author: compositor-design research pass.
Targets the device in `SCOPE.md` — iPad7,12, iPadOS 17.6.1, palera1n rootless
(`/var/jb`), Procursus, A10 (arm64, **not** arm64e).

This document specifies how to evolve the current full-screen Xios X server app into a
**window-forwarding compositor** that is itself the tablet shell: individual X app
windows become movable/resizable native iPad layers, and (Stage 4) iOS app windows sit
alongside them, all managed by one iOS-side window manager.

It builds directly on the in-progress IOSurface DDX. Read these first; this design
generalises them rather than replacing them:

- Server DDX: `linux-build/patches/xios/InitOutput.c`, `xios_surface.c`, `xios_surface.h`
  (an Xvfb-derived `hw/vfb` DDX, built as `Xios`; `-iosurface` activates it).
- App: `apps/Xios/Sources/XScreen.swift` (Metal present loop), `XSurface.c` (the AF_UNIX +
  mach-port IOSurface client), `XInput.c`/`XInput.h` (XTEST input as a second Xlib client).
- Entitlements: `linux-build/out/xios-ent.xml`.
- iOS scene-hosting engine (Stage 4): the `carplayhost` SpringBoard tweak —
  `tweaks/_research/carplayhost` — already a floating-window manager (CPHPanel: per-app
  `UIWindow` attached to SpringBoard's foreground `UIWindowScene`, drag/resize/snap/tile-4).

---

## 0. Recommended architecture (summary)

1. **Compositing happens in the DDX, not in a separate X client.** Per-window IOSurfaces
   must be allocated by the process whose `fb` memory the X server renders into — that is
   the server itself (it holds the `iokit-user-client-class` entitlement; a client cannot
   make the server render into client memory). So the Composite redirect, the per-window
   IOSurface-backed pixmaps, per-window Damage, and the window table all live **inside the
   Xios DDX**, as a sibling module `xios_compositor.c` next to today's `xios_surface.c`.
   There is **no `xcompmgr`-style helper client**.

2. **The iOS app is the real window manager.** The X "screen" is never displayed; it is a
   headless backing-store + coordinate host. Each top-level X window is redirected to its
   own IOSurface; the app draws one zero-copy Metal layer per window and owns all on-screen
   geometry, stacking, chrome (title bars), focus, drag/resize/snap/tile. This is a strict
   generalisation of today's single-surface app.

3. **One transport, keyed by XID.** Extend the existing AF_UNIX stream + per-app mach
   channel (`xios-ddx.sock` + `IOSurfaceCreateMachPort` hand-off) from one surface to *N*
   surfaces. Window lifecycle (create/map/configure/damage/restack/destroy/title/hints) and
   input/layout commands are framed messages on the socket; per-window IOSurface send
   rights are delivered over the same mach channel with **`msgh_id = XID`** for correlation.

4. **Input: X geometry is an "atlas", not a mirror.** Place each top-level X window at a
   fixed, **non-overlapping** origin in a large virtual X screen. The app sends
   `(XID, local_x, local_y, buttons)`; the server warps the core pointer into that window's
   atlas slot and enqueues — so X routes to the correct window regardless of how the app
   overlaps layers on screen. Keyboard goes to the X input-focus window, set from the app's
   `FOCUS` message. Stage 3 keeps today's XTEST path (works now); the end state injects
   directly into the server input queue (`QueuePointer/KeyboardEvents` + `mieqEnqueue`),
   removing the second Xlib client.

5. **Native iOS keyboard + gestures are the shell UX.** `pressesBegan/Ended` (hardware +
   on-screen `UIKey`) → keysym → X keycode → injected to the focused window. This beats a
   Linux OSK (onboard/squeekboard): no llvmpipe-rendered X window stealing screen space and
   focus; the iPad's system keyboard (predictive, globe/emoji, hardware, dictation). Stage 4
   moves the whole compositor into the `carplayhost` SpringBoard tweak so iOS app scenes
   (CPHPanel) and X windows (Metal/IOSurface panels) share one window space — the shell.

---

## 1. Where Stage 2 ends (the primitive Stage 3 generalises)

Today (`-iosurface`, single screen 0):

- `xios_surface_create()` makes one screen-sized BGRA8 IOSurface; `fb` draws straight into
  `IOSurfaceGetBaseAddress` (zero-copy). `vfbAllocateIOSurfaceFramebuffer()` points
  `pvfb->pfbMemory` at it and honours the surface's aligned `bytesPerRow`.
- One screen-wide `DamageCreate` on `pScreen->root`; the block handler `xiosBlockHandler`
  calls `xios_notify_dirty()` → writes one typed DIRTY record to every app client.
- `xios_server_start()` runs an AF_UNIX accept loop. Per client: read `xios_hello`
  `{magic,pid,portname}`, validate the peer via `LOCAL_PEERPID`, `task_for_pid` the app,
  `mach_port_extract_right` its receive port, `IOSurfaceCreateMachPort`, `mach_msg` the
  surface send right across, then reply `xios_reply{w,h,stride,format,status}`.
- App (`XSurface.c`): publishes a receive port, gets the surface port back (5 s timeout,
  one-shot), `IOSurfaceLookupFromMachPort`, builds a `bgra8Unorm` `MTLTexture` with
  `makeTexture(descriptor:iosurface:)`, presents aspect-fit, re-presents on `xsurface_drain`.
- Input (`XInput.c`): a **second** Xlib client; touch → fb coords → `XTestFakeMotionEvent` /
  `XTestFakeButtonEvent`. `xinput_key` + `xinput_keycode_for_keysym` already exist (unused).

**Everything above is reused.** Stage 3 keeps the socket server, peer-pid validation,
chmod-to-`mobile`, JSON handshake, mach-port hand-off, and damage→dirty block handler, and
turns each from "one screen" into "one per window, keyed by XID".

---

## 2. Stage 3 — per-window X compositing

### 2.1 Redirect: Composite, in-server, manual

The server already compiles the Composite extension (`InitOutput.c` references
`noCompositeExtension`). At screen init, after `xiosSetup()`, the new compositor module
enables redirection of every child of the root using the server-internal entry point
(equivalent to a client's `XCompositeRedirectSubwindows(dpy, root, CompositeRedirectManual)`):

```
compRedirectSubwindows(serverClient, pScreen->root, CompositeRedirectManual);
```

`Manual` (not `Automatic`) means the server stops painting redirected windows to the root —
exactly right, since the root is never shown. Each redirected top-level window now has an
offscreen backing pixmap (`compAllocPixmap` → `(*pScreen->CreatePixmap)`), retrievable as a
client would via `XCompositeNameWindowPixmap`. The compositor module is the consumer.

The Xios DDX should also act as the **window manager** so X clients' geometry requests are
intercepted rather than fought: select `SubstructureRedirectMask` on the root (server-side)
so `MapRequest`/`ConfigureRequest`/`CirculateRequest` come to us, and we place windows into
the atlas (see §2.4) instead of letting them self-position. No Linux WM runs; the app draws
all chrome. (`fluxbox` in `xios-server.sh` is dropped for Stage 3.)

### 2.2 Per-window IOSurface-backed pixmaps

`fb` pixmaps are linear blobs with a known stride — identical in shape to the screen
framebuffer, which already works as an IOSurface. So a per-window IOSurface backs a
per-window pixmap by the same trick at pixmap granularity:

1. On a top-level window becoming a compositing target (realized, InputOutput, parent ==
   root, or an override-redirect popup — see §2.6), allocate an IOSurface sized to the
   window's current `w×h` (BGRA8, `IOSurfaceAlignProperty` stride), via the existing
   `xios_surface.c` allocator generalised to return a handle rather than a single static.
2. Install it as the window's backing pixmap. Two viable mechanisms; **recommend (b)**:
   - **(a)** Wrap `pScreen->CreatePixmap`; when Composite asks for a window-backing pixmap,
     return an IOSurface-backed `fb` pixmap. Hard to disambiguate which `CreatePixmap` call
     is the backing one.
   - **(b) Let Composite allocate its pixmap normally, then repoint it.** Build an
     IOSurface-backed pixmap (`fbCreatePixmap` with 0 bits, then `(*pScreen->ModifyPixmapHeader)`
     pointing `devPrivate.ptr` at `IOSurfaceGetBaseAddress` and stride at the surface's
     `bytesPerRow`) and install it with `(*pScreen->SetWindowPixmap)` /
     `compSetPixmap`-style assignment. This is precisely how the screen fb pixmap is built
     today, scoped to a window.
   - Critical: the IOSurface-backed pixmap must **not own its bits** — `fbDestroyPixmap`
     must not `free()` the IOSurface base. Mark it like the root fb pixmap (bits not owned);
     release the surface only via `CFRelease` in our own teardown.
3. `DamageCreate(...DamageReportNonEmpty...)` + `DamageRegister(&pWin->drawable, dmg)` per
   window (generalising the single root Damage). The per-window Damage region drives the
   per-window dirty message.
4. `IOSurfaceCreateMachPort` once per surface; deliver to the app over the mach channel with
   `msgh_id = XID` (§2.3).

On **resize**: allocate a new IOSurface at the new size, repoint the window pixmap, send a
new surface port (new generation id), and let the app swap textures; release the old surface
only after the app acknowledges it has dropped the old texture (generation handshake) to
avoid use-after-free during the cross-process present.

Memory: per-window surfaces are *window-sized*, not screen-sized, so they are usually small
(a dialog is a few hundred KB, not the 14 MB full-screen frame). Still, cap concurrent
surfaces and reclaim on unmap.

### 2.3 Protocol v2 (`XIO2`) — superset of today's wire format

Bump `XIOS_MAGIC` to `'XIO2'`. The connect handshake is unchanged (hello → peer-pid check),
except the server no longer immediately sends one screen surface; instead it streams window
events and per-window surfaces. The app publishes **one** persistent receive port at connect
and runs a **persistent** mach receive loop (today's `XSurface.c` does a single 5 s
one-shot — that becomes a loop on a dedicated thread, dispatching by `msgh_id`).

Server → app (framed, little-endian, `{u32 type, u32 len, payload}`):

| type | payload | meaning |
|---|---|---|
| `WIN_CREATE` | `xid, x, y, w, h, flags, parent_xid` | new tracked window (flags: override-redirect, input-only) |
| `WIN_SURFACE` | `xid, w, h, stride, format, generation` | a fresh IOSurface follows on the mach channel with `msgh_id=xid` |
| `WIN_MAP` / `WIN_UNMAP` | `xid` | becomes / stops being a presentable layer |
| `WIN_CONFIGURE` | `xid, x, y, w, h, border, above_xid` | geometry/stack change (size change ⇒ a `WIN_SURFACE` follows) |
| `WIN_RESTACK` | `xid, above_xid` | X-side stacking hint |
| `WIN_DAMAGE` | `xid, x, y, w, h` | re-present this window's layer (bbox optional; presence is enough) |
| `WIN_TITLE` | `xid, utf8…` | `_NET_WM_NAME` / `WM_NAME` for the native title bar |
| `WIN_HINTS` | `xid, type, min/max, resizable, transient_for` | `_NET_WM_WINDOW_TYPE`, `WM_NORMAL_HINTS`, `WM_TRANSIENT_FOR` |
| `WIN_DESTROY` | `xid` | drop the layer + release surface |
| `CURSOR` | `serial, hot_x, hot_y, w, h` (+ image on mach ch.) | XFixes cursor image, if a custom pointer is wanted |

App → server (framed):

| type | payload | meaning |
|---|---|---|
| `POINTER` | `xid, lx, ly, buttons` | window-local pointer state (X pixels) |
| `SCROLL` | `xid, lx, ly, dx, dy` | wheel → buttons 4/5/6/7 |
| `KEY` | `keycode\|keysym, down, mods` | to the focused window |
| `FOCUS` | `xid` | user activated this iOS window → set X input focus |
| `CONFIGURE_REQUEST` | `xid, w, h` | user resized the iOS window → resize the X window |
| `CLOSE` | `xid` | ✕ tapped → `WM_DELETE_WINDOW` client message, else `XKillClient` |
| `SURFACE_RELEASED` | `xid, generation` | ack: old surface generation dropped (resize GC) |

Damage coalescing is unchanged from today: non-blocking writes; a backed-up app never
stalls the server; the app drains and re-presents the affected layers.

### 2.4 Window lifecycle → iOS layer updates

The compositor module learns lifecycle by **wrapping screen window hooks** (the standard DDX
technique), maintaining a `Window` table keyed by XID:

- `pScreen->CreateWindow` / `DestroyWindow` → `WIN_CREATE` / `WIN_DESTROY`.
- `pScreen->RealizeWindow` (map) / `UnrealizeWindow` (unmap) → `WIN_MAP` / `WIN_UNMAP`
  (allocate/free the surface here).
- `pScreen->PositionWindow` + `ConfigNotify` → `WIN_CONFIGURE`; a size change triggers
  surface realloc + `WIN_SURFACE`.
- `pScreen->ClipNotify` → `WIN_RESTACK`.
- `pScreen->SetShape` (XShape) → non-rectangular window region (Stage 3b; pass the region so
  the app can mask the layer).
- Window properties (title/hints/type/transient) via the server-side `PropertyStateCallback`
  (watch `WM_NAME`, `_NET_WM_NAME`, `_NET_WM_WINDOW_TYPE`, `WM_NORMAL_HINTS`,
  `WM_TRANSIENT_FOR`), read with `dixLookupProperty(..., serverClient, DixReadAccess)` →
  `WIN_TITLE` / `WIN_HINTS`.

App side: each `WIN_CREATE`+`WIN_MAP`+`WIN_SURFACE` builds a layer object — a
`CAMetalLayer`-backed view (or a Metal-textured `CALayer`) plus native chrome (title bar with
the `WIN_TITLE` text and a ✕). `WIN_DAMAGE` re-presents only that layer (per-layer
`xsurface_drain` equivalent). `WIN_CONFIGURE` with a new generation swaps the texture.
`WIN_HINTS` `type` selects chrome: `_NET_WM_WINDOW_TYPE_NORMAL` → full title bar;
`DIALOG`/`UTILITY` → light chrome; `MENU`/`TOOLTIP`/`COMBO`/`DROPDOWN`/`POPUP` →
chromeless, positioned by the app near the owner (see §2.6); `transient_for` parents dialogs.

### 2.5 Per-window input routing (the atlas model)

XTEST and the core input path are **screen-absolute**: there is no "deliver to window W"
primitive. X routes by pointer position against window geometry. Our on-screen layout
(iOS layers) overlaps freely and bears no relation to X geometry, so naive absolute
injection would land in the wrong window.

**Solution — atlas:** assign every top-level X window a fixed, **non-overlapping** origin in
a large virtual X screen (e.g. tile windows on a grid in an 8192×8192 root; each window
occupies `[ox, oy, ox+w, oy+h]`, slots never overlap). Then:

- `POINTER(xid, lx, ly, buttons)` → server warps the core pointer to `(ox+lx, oy+ly)` and
  enqueues motion + button transitions. Because slots don't overlap, X delivers to exactly
  `xid` (and to its own child sub-windows by the local offset — menus inside the app, GTK
  client-side decorations, etc. all resolve correctly within the window's own subtree).
- Stacking in X is irrelevant to input in the atlas model (no overlap), so we don't have to
  mirror iOS z-order into X — a real simplification over a geometry *mirror*.
- Pointer **grabs** (menus, scrollbars, drag-select) work: while a touch sequence is over an
  iOS layer, the app keeps sending that window's `POINTER`, so the warp stays inside the
  grabbing window's slot and X's grab logic behaves.

Keyboard goes to the X **input-focus** window, not the pointer window. `FOCUS(xid)` →
`XSetInputFocus(dpy, xid, RevertToParent, CurrentTime)` (server-side: `SetInputFocus` /
`DoFocusEvents`). The app sets focus when the user taps/activates an iOS window. `KEY` then
lands in the focused window.

**Two implementations, staged:**

- **Stage 3 (pragmatic): keep XTEST.** Reuse `XInput.c` unchanged for the mechanics; the app
  warps via `XTestFakeMotionEvent(dpy, screen, ox+lx, oy+ly, 0)` then
  `XTestFakeButtonEvent`. Focus via `XSetInputFocus`. Geometry: the app (or the compositor
  module) issues `XMoveResizeWindow`/`XConfigureWindow` to park each X window at its atlas
  slot. This reuses 100% of today's working input client.
- **End state (cleaner): inject in the DDX.** The stock `hw/vfb/InitInput.c` already
  registers core pointer/keyboard devices via `mieqInit`. Feed events directly with
  `GetPointerEvents`/`GetKeyboardEvents` + `mieqEnqueue` against those devices, driven by the
  socket `POINTER`/`KEY` messages. This deletes the second Xlib client and the whole XTEST
  round-trip; the warp becomes an internal `(ox+lx, oy+ly)` with no protocol. Migrate after
  Stage 3 is functionally complete.

### 2.6 Override-redirect, menus, focus, stacking

- **Override-redirect popups** (menus, tooltips, combo lists) are separate top-level windows;
  Composite redirects them too. Each gets a `WIN_CREATE` with the override flag + its own
  IOSurface; the app positions the layer on screen using the X coordinates carried in
  `WIN_CONFIGURE` *relative to its owner* (the app knows where it drew the owner, and the X
  popup geometry is relative to the same virtual space, so `popup_x - owner_x` gives the
  on-screen offset). Chromeless. They appear/dismiss with map/unmap.
- **Stacking/focus** are owned by the app. Tap-to-front raises the iOS layer and sends
  `FOCUS`; the app's WM policy (click-to-focus, focus-follows-tap) is pure iOS. The X side
  only needs focus set for keyboard delivery; z-order is cosmetic in X (atlas).
- **Close**: ✕ → `CLOSE(xid)`; the server sends `WM_DELETE_WINDOW` if the client lists it in
  `WM_PROTOCOLS`, else `XKillClient`.

---

## 3. Native input as the shell UX

### 3.1 Keyboard (the next app feature)

The app already has the X side (`xinput_key`, `xinput_keycode_for_keysym`); what's missing is
capturing iOS keys and mapping them.

- **Hardware + on-screen** via `UIResponder.pressesBegan(_:with:)` / `pressesEnded`. Each
  `UIPress.key` is a `UIKey` exposing `keyCode` (a `UIKeyboardHIDUsage`), `modifierFlags`,
  `charactersIgnoringModifiers`, and `characters`. On-screen text input additionally comes
  through a hidden first responder conforming to `UIKeyInput` (`insertText`/`deleteBackward`)
  for soft-keyboard glyphs that don't surface as `UIKey` (emoji, dictation, autocorrect
  commits).
- **Mapping.** Maintain a static `UIKeyboardHIDUsage → X keysym` table (the HID usage page is
  stable and maps cleanly to X keysyms), then `xinput_keycode_for_keysym` → keycode. For
  printable characters arriving via `UIKeyInput.insertText`, map char → keysym (including the
  shifted plane) and synthesise the shift state.
- **Modifiers.** XTEST replays at device level and XKB composes, so wrap the main key with
  modifier keycodes: e.g. Shift-A = `Shift↓, a↓, a↑, Shift↑` via `XTestFakeKeyEvent`. Track a
  shadow modifier state from `UIKey.modifierFlags` for hardware chords (⌘/⌥/⌃ → Super/Alt/
  Control). When input migrates into the DDX (§2.5), the same composition is done with
  `GetKeyboardEvents` against the core keyboard.
- **Focus → target.** The active iOS window's XID (set via `FOCUS`) is the X input-focus
  window; key events land there. Per-window focus is just "which iOS layer is frontmost/last
  tapped" → one `XSetInputFocus`.

### 3.2 Why native beats a Linux OSK (onboard / squeekboard)

- **No software-GL window.** A Linux OSK is an X client rendered by `llvmpipe` into the
  framebuffer — sluggish, occupies X screen space, and (in the atlas/per-window world) would
  need its own surface/layer. The native keyboard is drawn by iOS, zero X cost.
- **No focus theft / grab fights.** An X OSK must avoid taking focus to type into other
  windows (the classic OSK problem); our keyboard is outside X entirely and injects to the
  chosen focus window deterministically.
- **Form-factor correct.** iPad system keyboard: predictive text, globe/emoji, dictation,
  hardware-keyboard support, floating/split — none of which onboard/squeekboard offer well.
- **Single input authority.** Touch, gestures, and keys all flow through the app → one
  consistent translation to X, instead of X-side touch + X-side OSK + app-side touch racing.

### 3.3 Touch gestures as window management

Touch is already pointer (Stage 2). The shell adds **gestures that never reach X**: drag a
title bar to move a layer, pinch/drag-grip to resize (→ `CONFIGURE_REQUEST`), drag-to-edge to
snap, a tile-4 grid, two-finger swipe to switch focus. This is the `carplayhost` macOS-WM
engine (floating dock + drag-to-edge snapping + tile-4, already built and verified) applied to
X-window layers. Only **content-area** touches become `POINTER`; chrome/gesture touches are
consumed by the app.

---

## 4. Stage 4 — hosting iOS app scenes alongside X windows

### 4.1 The constraint that dictates the architecture

The scene-hosting APIs that put a *live* iOS app UI into your own window
(`SBSceneManagerCoordinator`, `SBDeviceApplicationSceneEntity
defaultEntityWithApplication:sceneHandleProvider:displayIdentity:`, `SBAppViewController`
`_setCurrentMode:` + `setDisplayMode:LiveContent`) are **SpringBoard-only**. A sandboxed app
cannot host scenes — and on this device a `carp`-style app even gets a restricted sandbox
that **denies in-process GPU/IOSurface** (`deny iokit-open-user-client AGXDeviceUserClient`),
which would also break Metal. The `carplayhost` memory confirms both: only the SpringBoard
*tweak* can host scenes, and only inside SpringBoard is `LSApplicationWorkspace
allApplications` non-nil.

Therefore the true shell **cannot be a normal app**; the compositor must run **inside
SpringBoard** (the `carplayhost` tweak), where it already has every privilege and full GPU
access, and where iOS scene panels already work.

### 4.2 Recommended: fold the compositor into the `carplayhost` tweak (hybrid)

One window manager in SpringBoard manages two layer kinds in the same space (both are
`UIWindow`s attached to SpringBoard's foreground `UIWindowScene`, the proven CPHPanel model):

- **iOS app window** = a CPHPanel scene host (`SBAppViewController` LiveContent) — already
  working/stable in the tweak, with the documented stability fixes (catch the scene-foreground
  `BSAssert`; teardown `_setCurrentMode:0` + `invalidate` before release; debounce).
- **X app window** = a CPHPanel whose content is a `CAMetalLayer`/Metal-textured view fed by a
  per-window IOSurface from the DDX — i.e. exactly the Stage 3 app-side renderer, moved into
  the tweak. SpringBoard has GPU access, so `IOSurfaceLookupFromMachPort` + `makeTexture
  (iosurface:)` works there.

The same gesture/drag/resize/snap/tile-4 engine drives both. The standalone `Xios.app`
remains the dev/test harness; the production shell is the tweak. This also **unifies with
work already done** — `carplayhost` is already the floating-dock + snapping + tile-4 window
manager; Stage 4 is "teach it a second panel content type (X/IOSurface) and wire the DDX
socket".

IPC target changes: the DDX's `task_for_pid` + mach hand-off now targets **SpringBoard's
pid** instead of the app's. The DDX already holds `task_for_pid-allow` +
`com.apple.system-task-ports` and runs as root, so the same rendezvous works with SpringBoard
as the client publishing the receive port. IOSurface send rights cross to SpringBoard fine.

### 4.3 Entitlement / security implications

- **No new entitlement file for hosting.** Scene hosting needs SpringBoard-level privilege,
  obtained by *being in SpringBoard* (the tweak), not by an entitlement. The DDX keeps its
  existing `xios-ent.xml` (task_for_pid-allow, system-task-ports, IOSurface user-client
  classes, platform-application, skip-library-validation, no-container, file rw).
- **`task_for_pid` to SpringBoard**: allowed for the root, suitably-signed DDX under
  palera1n AMFI (it already does `task_for_pid` on the mobile app). Validate the peer via
  `LOCAL_PEERPID` as today, so only SpringBoard (or an authorised client) gets surface ports.
- **Stability is the real risk, not security.** A compositor inside SpringBoard that crashes
  = respring, and repeated crashes drove `carplayhost` into ElleKit safe mode and wedged
  tweak injection (documented). Mitigations, all proven there: defensive `@try` around scene
  callbacks, the lifecycle teardown order, debounced re-host, and keeping the heavy/long-lived
  X rendering loop crash-isolated (the DDX is a separate root process; if it dies, the tweak
  shows frozen last frames, not a SpringBoard crash — mirror the app's existing
  `teardownIOSurface` + reconnect logic).
- **Surface lifetime across SpringBoard**: reclaim IOSurfaces on `WIN_DESTROY`/unmap and on
  client disconnect (today's swap-remove in `xios_notify_dirty` generalises); leaked mach
  ports on window churn must be `mach_port_deallocate`'d (the resize generation handshake
  covers the swap case).

---

## 5. Staged implementation plan

| Stage | Server (DDX) | App / tweak | New X APIs / mechanics | Exit criterion |
|---|---|---|---|---|
| **2 (current)** | single screen IOSurface; root Damage → dirty | one full-screen Metal view; XTEST pointer | Composite *compiled*; Damage; IOSurface+mach hand-off | done/finishing: desktop visible, touch works |
| **3a** | `xios_compositor.c`: `compRedirectSubwindows(Manual)`; per-window IOSurface pixmaps; per-window Damage; protocol v2; atlas placement; SubstructureRedirect (act as WM) | N Metal layers (one/window) with native title bars; persistent mach receive loop keyed by `msgh_id`; XTEST routed via atlas warp + `FOCUS`; **native keyboard** (`pressesBegan`→keysym→keycode) | Composite (`compRedirect*`, `NameWindowPixmap`), Damage (`DamageRegister`/`DamageReportNonEmpty`), screen hooks (`Realize/Unrealize/Position/ClipNotify/Create/DestroyWindow`), `PropertyStateCallback`, `SetInputFocus`; `ModifyPixmapHeader`/`SetWindowPixmap` + `IOSurfaceCreateMachPort(msgh_id=xid)` | several X apps as independent movable native windows; type into the focused one |
| **3b** | resize → new surface + generation handshake; XShape region; WM hints/title/type; `WM_DELETE_WINDOW` | app is full WM: drag/resize/snap/tile-4 (carplayhost engine), `CONFIGURE_REQUEST`, chromeless menus/override-redirect, ✕ close | `ConfigureWindow`/`MoveResizeWindow`, XFixes regions, `XKillClient`/client message | resize/snap/menus/close feel native |
| **3c (opt.)** | inject input via `GetPointer/KeyboardEvents`+`mieqEnqueue` | drop `XInput.c` Xlib client | DDX core-device injection | no second Xlib client; lower input latency |
| **4** | hand-off targets SpringBoard pid | compositor moves into `carplayhost` tweak; X panels (IOSurface/Metal) + iOS panels (CPHPanel scene host) in one space; unified dock/launcher | SpringBoard scene hosting (`SBDeviceApplicationSceneEntity`, `SBAppViewController` LiveContent) | one shell: X apps and iOS apps side-by-side, movable |

### Key risks

1. **In-server pixmap repoint correctness** — backing-pixmap lifetime, the "bits not owned"
   flag so `fbDestroyPixmap` never frees the IOSurface, and clean resize swaps. Highest-risk
   server work; prototype on one window first.
2. **Input edge cases** — grabs, menus, modifier composition, focus-follows; the atlas model
   handles routing but XTEST-vs-mieq and grab timing need device testing.
3. **Stage 4 SpringBoard stability** — respring/safe-mode/injection-wedge (already bit
   `carplayhost`); apply its documented mitigations and keep the DDX crash-isolated.
4. **Memory / surface count** — many per-window retina IOSurfaces; cap and reclaim; windows
   are window-sized so usually cheap.
5. **`task_for_pid` reliability + mach-port leaks** on rapid window churn; the resize
   generation handshake and disconnect cleanup must be airtight.
6. **DPI/scale** — X windows at retina vs scaled-logical; decide per-window backing scale so
   Metal upscaling and pointer coordinate math agree.

### How the in-progress IOSurface DDX feeds Stage 3

Stage 2's `xios_surface.c` is the *primitive* Stage 3 multiplies by N:

- `xios_surface_create` → a per-window allocator returning a handle (surface + stride +
  base), called on map / resize instead of once at screen init.
- the single root `DamageCreate` + `xiosBlockHandler` → one Damage per window, flushing
  a per-window typed DIRTY record instead of one global record.
- `xios_server_start` accept loop, `LOCAL_PEERPID` validation, chmod-to-`mobile`, JSON
  handshake, and the `task_for_pid`+`mach_port_extract_right`+`IOSurfaceCreateMachPort`+
  `mach_msg` hand-off → reused verbatim; the hand-off just runs once per window with
  `msgh_id = XID`.
- `XSurface.c`'s connect/handshake → a persistent multi-surface client runtime (receive loop
  + socket reader); `XScreen.swift`'s single present loop → one present per window layer.
- `XInput.c` (XTEST) → reused as-is in Stage 3a (atlas warp + focus), optionally retired in
  3c.

Nothing in Stage 2 is thrown away; Stage 3 is a generalisation from "one surface, one layer,
one Damage, one hand-off" to "one of each per XID", over the same transport and entitlements.
