# Native iPadOS flavor: Linux apps as first-class iPad windows

Design + recon only. Nothing here is implemented; Max must confirm the hosting
model (question Q1, section 8) before real code.

The idea: instead of one fullscreen Xios window containing a whole Linux desktop
(the GNOME / KDE / X11 flavors), each Linux app presents as its OWN iPadOS
window. iPadOS multitasking (app switcher, Split View, Slide Over, and Stage
Manager where the hardware has it) IS the desktop environment. A GNOME app sits
in the app switcher next to Safari and pairs with Notes in Split View.

---

## 0. Correction to the starting premise (read first)

The brief said "iosc already gives each toplevel window its own IOSurface".
Not quite. Today:

- Each **GPU client buffer** is an IOSurface (three per window, rotated by the
  EGL shim), and wl_shm clients use plain shared memory, not IOSurfaces.
- iosc GPU-composites **all** mapped windows into **one** output IOSurface
  (`xios_surface_create`), and the single Xios app Metal-presents that one
  surface. There is exactly one presentation surface, period.

So the native flavor's core compositor work is a **per-window presentation
mode** for iosc: one stable "canvas" IOSurface per xdg_toplevel (the window
plus its popups and subsurfaces composited into it), each announced to a host
app over an extended rendezvous protocol. That is a generalization of the
existing output path, not a new mechanism: allocate-surface, mach-port
hand-off, dirty notification, and GPU composite all already exist in
`xios_surface.c` / `iosc_gl.c` for the single output; native mode runs the same
machinery N times with per-window targets.

A phase-2 fast path can hand a GPU client's own buffer IOSurfaces directly to
the host (true zero copy, no compositor pass) when a window has no popups or
subsurfaces; see section 2.4.

## 1. Who hosts the scenes: the two topologies

Both variants keep the launch chain from `docs/iosc-desktop-env.md` (per-app
SpringBoard `.app` bundles, root `ioscd`, iosc wl clients). They differ in
which process owns the UIWindowScenes.

### Variant A: each per-app bundle IS the host (recommended)

The `IOSCLaunch` stub stops being a dumb "send LAUNCH and show a splash" app.
It becomes a small UIKit app that:

1. sends `LAUNCH` to ioscd (unchanged),
2. binds to iosc's native-mode socket with its `IOSCAppID`,
3. receives the per-window canvas IOSurface for the toplevel(s) that app maps,
4. Metal-presents it in its own window and forwards its own input.

Each Linux app then has a real SpringBoard identity: its own icon, its own app
switcher card, its own Split View slot, its own App Expose. Two Linux apps side
by side in Split View are just two iOS apps side by side. A multi-window Linux
app (GIMP with a detached dialog) turns on `UIApplicationSupportsMultipleScenes`
in its host and requests one extra UIWindowScene per additional toplevel.

### Variant B: one shared host app with N UIWindowScenes

Launchers stay dumb; a single host app (a grown Xios) declares
`UIApplicationSupportsMultipleScenes` and spawns one scene per Linux window
when ioscd tells it to.

Rejected as the primary model, for three reasons:

- **Identity.** All windows group under one app in the switcher and dock. That
  is exactly the "feels like one app containing a desktop" experience this
  flavor exists to avoid.
- **Activation limits.** `requestSceneSessionActivation` must be called by the
  host itself, and calling it while the host is backgrounded is restricted
  (the system may defer or ignore it). Tapping a Home Screen icon while the
  host is backgrounded is the COMMON case here.
- **Blast radius.** One host crash or jetsam kill takes down every Linux
  window's presentation at once.

Variant A's cost is one small UIKit process per running Linux app (a Metal
layer, an input forwarder, and a socket; tens of MB each). The Linux processes
themselves dwarf that. Accepted.

Multi-scene still appears inside Variant A, but scoped: a single host uses
extra scenes only for extra toplevels of its own app, where the "grouped under
one identity" behavior is exactly right.

## 2. Display path: per-window IOSurface to per-scene CAMetalLayer

### 2.1 iosc native mode

`IOSC_NATIVE=1` (env or flag, set by ioscd when the chooser selected this
flavor) changes presentation only. Wayland-facing behavior (protocols, input
delivery, clipboard) is untouched.

- No shared fullscreen output surface. On xdg_toplevel map, iosc allocates a
  canvas IOSurface at the window's configured size (same
  `IOSurfaceAlignProperty` + `IOSurfaceCreate` path as `xios_surface_create`).
- `recomposite` becomes per-window: composite that window's buffer plus its
  subsurfaces and xdg_popups into its canvas (iosc_gl already renders into an
  IOSurface-backed pbuffer; it gains per-window targets instead of the single
  output target).
- On commit, mark that window's canvas dirty and notify its host.

### 2.2 Rendezvous protocol v2

The existing ddx protocol is one-shot and single-surface (hello, one mach
port, one geometry reply). Native mode adds a second socket
(`/var/jb/tmp/iosc-native.sock`) with a message protocol; the old socket and
protocol stay byte-identical for the other flavors.

Host to iosc:

| msg | payload | meaning |
|---|---|---|
| `BIND` | app_id, receive-port name, scene w/h in px | "I display windows for this app_id; here is where to send surface ports; my scene is this big" |
| `RESIZE` | window id, w, h | scene geometry changed (Split View drag, rotation) |
| `ACTIVATE` | window id, 0/1 | scene became key / resigned key |
| `CLOSED` | window id | user closed the scene; send xdg_toplevel.close |

iosc to host:

| msg | payload | meaning |
|---|---|---|
| `WINDOW_NEW` | window id, w, h, stride, title | a toplevel matching your bind mapped; canvas port follows via mach_msg (reuses `deliver_surface_port`) |
| `WINDOW_GEOM` | window id, w, h | canvas reallocated after a resize (new port follows) |
| `DIRTY` | window id | canvas changed, re-present |
| `TITLE` | window id, utf8 | title changed |
| `WINDOW_GONE` | window id | toplevel unmapped; tear down the scene |

Matching windows to hosts: primary key is the Wayland `app_id` (same key
ioscd's raise path already uses; GTK sets it to the application id, which the
generator stores in `IOSCAppID`). Fallback for helper windows with oddball
app_ids: ioscd `setsid()`s every launch, so the wl client pid's session id
identifies which launch (and therefore which host) spawned it. Windows that
still match nothing go to a catch-all (the plain Xios app), so nothing is ever
unreachable.

### 2.3 Host presentation

Per scene: a UIWindow whose root view is exactly XScreen.swift's Metal path,
which already does everything needed (CAMetalLayer,
`makeTexture(descriptor:iosurface:plane:)`, damage-driven present, CADisplayLink
pause on background). The host is new glue around extracted Xios code, not new
rendering code. Entitlements are the proven Xios app set (IOSurface IOKit
classes, get-task-allow, skip-library-validation; no no-container).

### 2.4 Performance ladder

1. **v1:** client buffer (GPU IOSurface or shm) composited by iosc into the
   window canvas, host presents the canvas. One GPU pass per dirty window per
   frame, same cost shape as today's single output. Ships first.
2. **v2 fast path:** window has no popups/subsurfaces and a GPU client (the
   common steady state): deliver the client's three buffer IOSurface ports to
   the host once, then `DIRTY` carries the buffer index. Zero compositor work,
   zero copies; the host samples the client's render target directly. Falls
   back to v1 whenever a popup maps.

## 3. Launch path

Reuses `x11/apps/iosc-desktop` nearly whole (generator, icons, ioscd,
LaunchDaemon, install scripts).

1. Tap the "Console" icon SpringBoard shows for
   `com.max.iosc.org.gnome.Console`.
2. The host app starts foreground, connects `iosc-native.sock`, sends
   `BIND org.gnome.Console` with its scene size, and sends
   `LAUNCH\torg.gnome.Console\t<exec>` to `ioscd.sock` (protocol unchanged).
3. ioscd ensures iosc is running (now with `IOSC_NATIVE=1`) and spawns the
   client exactly as today. The `uiopen com.max.xios` step is DROPPED in
   native mode: the tapped host is already the foreground display.
4. Client maps its toplevel. iosc sizes the initial configure from the bind's
   scene size (so the first frame fits exactly), allocates the canvas, sends
   `WINDOW_NEW` + the port. Host swaps its "Opening..." placeholder for the
   live Metal view.
5. Re-tap while running: host is still alive, scene foregrounds, nothing to
   do (the ioscd raise verb is unnecessary in this flavor; iPadOS does the
   raising).
6. Host killed by jetsam while backgrounded, Linux app still running: re-tap
   relaunches the host, `BIND` re-attaches, iosc re-delivers ports for the
   app's live windows. The Linux process never noticed.

ioscd changes are small: a native-mode flag, skip `foreground_xios()`, and
keep the existing spawn env. Everything the launch env does today (private
XDG_RUNTIME_DIR, dbus-run-session, GSK renderer selection) carries over.

## 4. Input routing

All primitives exist (`IoscInput.c` in the app, the 24-byte record protocol,
iosc's wl_seat with pointer/keyboard/touch/tablet). Two changes:

- **Connection scoping.** The input socket protocol has no window addressing
  (iosc hit-tests a shared coordinate space today). Add one record type,
  `XIOS_IN_BIND` (code = window id), sent once after connect. All subsequent
  events on that connection are window-local: motion coords translate directly
  to that surface, no hit test, and a key event moves wl_keyboard focus to the
  bound window if it is not already there. The 24-byte framing is untouched
  (additive type, like TOUCH=6 / TABLET=7 were).
- **Focus follows iPadOS.** The key scene's host is the only one the user is
  typing into; hosts send `ACTIVATE` on scene key/resign and iosc moves
  keyboard focus accordingly. Two Split View windows both receive touch;
  wl_pointer/wl_touch focus is per-connection anyway.

Per-host forwarding is the existing XScreen code: touches fan out as wl_touch
(type 6) plus the pointer emulation, Pencil as tablet (type 7), hardware keys
via pressesBegan, OSK via UIKeyInput, trackpad hover via UIPointerInteraction.
Cursor shapes: iosc already rasterizes cursor-shape-v1; a later nicety is
mapping those names to UIPointerStyle per scene instead of drawing the cursor
into the canvas.

## 5. Window lifecycle mapping

| Wayland side | iPadOS side |
|---|---|
| toplevel maps (first) | tapped host is already foreground; placeholder swaps to live content |
| toplevel maps (additional, same app) | host requests another UIWindowScene, presents there |
| xdg_popup maps | composited into the parent window's canvas, never a scene (see below) |
| title / app_id set | `TITLE` msg; host sets scene title (shows in the app switcher) |
| toplevel unmaps / client exits | `WINDOW_GONE`; host closes that scene, exits when its last scene closes |
| scene resized (Split View drag, rotation, Stage Manager) | `RESIZE`; iosc sends configure, client acks + commits, canvas reallocates, host letterboxes the one transitional frame |
| scene swiped away in the switcher | `CLOSED`; iosc sends xdg_toplevel.close; GTK apps quit or prompt; if the client ignores it, ioscd can escalate (SIGTERM) after a grace period |
| host backgrounded | host pauses CADisplayLink (existing behavior); iosc stops firing that window's frame callbacks, so the client throttles itself, the standard Wayland occlusion mechanism. The Linux process keeps running root-side, untouched by iOS app lifecycle |
| host jetsammed | Linux app unaffected; re-tap re-binds (section 3, step 6) |
| device rotates | just a resize |

States sent with every configure: `maximized` (and `tiled` edges), so GTK CSD
apps drop shadows and resize edges and draw an attached headerbar, which reads
naturally as an iPad window's toolbar. `activated` tracks the `ACTIVATE` msgs.
Interactive `xdg_toplevel.move` / `.resize` requests are acked and ignored:
iPadOS owns geometry in this flavor.

**Popups.** GTK menus, dropdowns, and tooltips are xdg_popups positioned
relative to the parent, and they can legitimately overhang the parent's frame.
iPadOS has no way to draw outside a scene, so native mode constrains
xdg_positioner placement to the window bounds (the positioner's
constraint_adjustment flip/slide machinery exists for exactly this). Cost: a
tall menu on a short window gets scrolled/squeezed by GTK. Acceptable; same
compromise every nested compositor makes.

**Scale.** Scenes are in points; the canvas is physical pixels. Advertise
wl_output scale 2 so GTK renders hidpi, and map point coords times
contentScaleFactor in the host, same as Xios does now.

## 6. What carplayhost/Mosaic contributes (assessment)

Verdict: **do not reuse the scene-hosting engine as the host.** carplayhost
solves the inverse problem: hosting OTHER iOS apps' live scenes
(SBDeviceApplicationSceneEntity / FBScene) inside SpringBoard, which requires
tweak injection and private FrontBoard API. Here every window is our own Metal
content inside our own ordinary UIKit app, and iPadOS does the window
management natively. Using SBAppViewController machinery would add SpringBoard
injection risk to a flavor whose whole point is being the boring, native one.

What does carry over:

- **Xios app code is the real engine to reuse**: XScreen.swift (Metal
  IOSurface present) and IoscInput.c (input forwarding) move into the host
  stub nearly verbatim.
- **carplayhost lessons**, not code: trust-cache registration for every
  generated bundle (jbctl add per cdhash; gen-launchers must automate this or
  taps fail with launch error 3), a UIWindow is invisible without a
  UIWindowScene, and FrontBoard relaunch throttling after repeated crashes.
- **Mosaic as an optional complement, later**: the iPad 7 has no Stage
  Manager (see Q3). Mosaic already floats arbitrary iOS apps' scenes as
  draggable, resizable windows inside SpringBoard, and per-app hosts are just
  iOS apps, so Mosaic can float Linux windows TODAY with zero changes on
  either side. That combination is "Stage Manager for old iPads" and it stays
  strictly optional: no tweak needed for the base flavor.

## 7. Phasing

1. **P0, protocol + one window:** iosc native mode (per-window canvas +
   v2 rendezvous), host stub presenting one toplevel fullscreen, input bind.
   Demo: tap Console icon, Console fills the screen, type in it, home out,
   switcher shows "Console" with live thumbnail... then a second icon
   (Calculator) and both in Split View. That demo IS the flavor.
2. **P1, lifecycle polish:** resize/rotation, close-from-switcher, jetsam
   re-attach, multi-toplevel scenes, popup constraint tuning, scene titles.
3. **P2, perf + polish:** direct buffer hand-off fast path (2.4), pointer
   styles, per-app default sizes, chooser integration (this flavor's floor is
   just the catalog floor; no DE stack to install, so it is the lightest
   flavor and likely the default suggestion on non-M1 hardware).

## 8. Open questions for Max

- **Q1 (the gate): confirm scene-per-app hosting, Variant A.** Each generated
  launcher bundle becomes a real host app that presents its Linux app's
  windows; one UIKit process per running Linux app. Variant B (one shared
  host, N scenes) stays possible but demotes the flavor to "windows of one
  app". Confirm A before any code.
- **Q2: interim step or straight to P0?** The chooser memory mentions a
  simpler interim (launch into the one Xios window). That already exists
  today as the iosc-desktop flow, so the recommendation is to skip any new
  interim work and go straight at the per-window mode.
- **Q3: Stage Manager expectations.** The dev iPad (A10, iPad 7) has no Stage
  Manager; it needs M1 iPads (or A12X/A12Z iPad Pros, capped at 4 windows) on
  iPadOS 16.1+. On the dev device this flavor means fullscreen + app switcher
  + Split View + Slide Over. Is that acceptable as the shipping experience for
  old hardware, and is the Mosaic pairing (section 6) worth pursuing as the
  optional floating-window mode there? (Testing actual Stage Manager behavior
  needs hardware we do not have.)
- **Q4: background policy.** Backgrounded hosts suspend; Linux apps keep
  running root-side and burning CPU/battery invisibly (frame callbacks stop,
  so renderers idle, but the process lives). Keep running (real desktop
  semantics, instant resume) or have ioscd SIGSTOP clients whose host has been
  background for N minutes? Recommend: keep running for v1, revisit with data.
- **Q5: scene-count and jetsam limits.** No documented UIWindowScene cap, but
  the system disconnects background scenes freely and the A10 has 3GB RAM
  shared with N host processes plus the Linux stack. Practical concurrent
  window count is unknown until measured on-device; the re-attach design
  (3.6) is what makes disconnects/jetsam survivable rather than fatal.
