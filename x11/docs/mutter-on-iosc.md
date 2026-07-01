# Mutter on iosc — getting gnome-shell onto the iOS Wayland substrate

Status: **Mutter 46 cross-builds + links to iOS arm64, and is now packaged as debs.** The 5 libs
(libmutter-14, -cogl-14, -cogl-pango-14, -clutter-14, -mtk-14) + deps are built off-device and
staged in `x11/linux-build/out` (see "Typelib generation" below for the deb list). The
introspection *config* is proven to resolve off-device (the gir scanner commands harvested to
`out/mutter-gir-commands.txt`); generating the actual typelibs requires the device (Blocker #2).
**Backend code (MetaBackendIOS) is now WRITTEN and compile-clean off-device** against the real
Mutter 46.0 ABI — the winsys (Step 2) plus the four Step-3/4/5 pieces (monitor manager, input,
IOSurface buffer type, login1 stub) all compile under mutter's own strict flags; see "Backend code
status" below. Grounded in the Mutter 46.0 source tree and in the working `iosc` compositor
(`x11/wayland`). **We keep iosc as a switchable compositor AND add
gnome-shell** — the shared iOS/GPU glue (iosc_gl.c + xios_surface.c + the iosc_iosurface protocol +
libiosc_egl winsys) is factored into a shared lib both iosc and MetaBackendIOS link; iosc is NOT
retired.

Sibling docs: [`gnome-plan.md`](gnome-plan.md) (the four Shell blockers),
[`gjs-plan.md`](gjs-plan.md) (typelibs + mozjs, both SOLVED), [`wayland-plan.md`](wayland-plan.md)
(why a custom compositor, not wlroots/Mutter-as-is), and memory `wayland-m1-compositor` (iosc's
M1–M8 milestones, all on-device validated).

---

## TL;DR — the recommendation

**Make Mutter the compositor, with a new iOS/IOSurface backend, and dissolve `iosc` into that
backend.** Concretely: write a `MetaBackend` for iOS (call it `MetaBackendIOS`) whose renderer
presents to the output `IOSurface` the Xios app shows, reusing iosc's already-validated iOS glue
verbatim — `xios_surface.c` (IOSurface alloc + the Xios-app mach handshake), `iosc_gl.c`
(ANGLE-EGL rendering *into* an IOSurface as the default framebuffer), the `iosc_iosurface`
client-buffer protocol, and the `iosc_input.c` socket. Mutter's own Wayland server, xdg-shell,
seat, and damage tracking *replace* iosc's hand-rolled versions, which are then thrown away.

This is chosen over the two "nested" options because **Mutter already *is* a complete Wayland
compositor** (`src/wayland/` is a full wl server — `wl_compositor`, `xdg_shell`, `wl_seat`,
`linux-dmabuf`, `wl_drm`/EGL, single-pixel, viewporter, tablet, …). Nesting Mutter *inside* iosc
would stack two Wayland compositors with iosc reduced to a pointless IOSurface forwarder — and
**upstream Mutter has no Wayland-host nested backend anyway** (its only nested backend nests into
an *X server*), so the nested route requires writing net-new Mutter backend code of the *same
order* as the native-style backend, for a worse architecture.

**Single biggest risk:** Cogl/Clutter initializing and rendering correctly on **ANGLE-Metal
GLES3** on the A10 — Cogl is a stricter, older GL consumer than GTK4's GSK (which we already
proved on this exact stack). It must be spiked first, before any backend code is written.

---

## What "gnome-shell on iosc" actually means

gnome-shell is not an app that runs *on* a compositor — **gnome-shell *is* Mutter**. The
`gnome-shell` binary links libmutter and instantiates a `MetaContext` whose compositor type is
Wayland; the JS (on gjs, consuming the Meta/Clutter/Cogl/St typelibs) drives Mutter's stage. So
"hardware gnome-shell on iOS" = **Mutter running as a Wayland compositor on an iOS display
backend.** The question is only *which* backend, and what happens to iosc.

The hardware constraint is already settled in `gjs-plan.md`: a *hardware* shell cannot be
Mutter-as-X11-WM (that GPU-composites by binding redirected X11 pixmaps as GL textures via
`texture-from-pixmap`, which needs hardware DRI inside the X server — Xios is software-only, and
ANGLE has no X11 platform to import pixmaps). **On this stack, GPU compositing is reachable only
through Wayland** — clients hand the compositor IOSurface buffers; the compositor renders to the
display IOSurface via ANGLE→Metal. That is exactly iosc's architecture, and it is exactly what
Mutter's *native* (not X11) backend shape wants — just over IOSurface instead of KMS/GBM.

---

## Mutter's backend architecture (grounded in 46.0)

The selection logic is in `src/core/meta-context-main.c:meta_context_main_create_backend`:

```
compositor type = X11      → create_x11_cm_backend  → MetaBackendX11Cm     (Mutter = X11 WM)
compositor type = WAYLAND:
    options.nested         → create_nested_backend  → MetaBackendX11Nested (nests in an X server)
    options.headless       → MetaBackendNative (HEADLESS mode)
    else                   → create_native_backend  → MetaBackendNative    (KMS/DRM/GBM/libinput)
```

A `MetaBackend` owns: a **MetaRenderer** (→ a Cogl renderer + per-monitor `MetaRendererView`s,
each wrapping a Cogl framebuffer), a **MetaMonitorManager** (enumerates outputs/CRTCs/modes), a
**ClutterBackend/seat** (input → Clutter events), a **MetaCursorRenderer**, and a
**MetaColorManager**. The display path bottoms out at one **CoglOnscreen** per output that gets
`cogl_onscreen_swap_buffers`'d.

Two facts from the source decide everything below:

1. **The renderer's winsys is pluggable through a public Cogl seam.** Mutter's native renderer
   does not use a built-in Cogl winsys; it calls
   `cogl_renderer_set_custom_winsys(cogl_renderer, get_native_cogl_winsys_vtable, …)`
   (`meta-renderer-native.c:1269/1274`) to supply its *own* `CoglWinsysVtable`. The native winsys
   is an **EGL** platform whose onscreens are GBM/KMS surfaces. **An iOS backend supplies the same
   kind of custom EGL winsys, but its onscreen renders into an IOSurface via ANGLE** — which is
   precisely what `iosc_gl.c` already does (pbuffer-from-output-IOSurface as FBO 0, validated
   on-device, see M3).

2. **Cogl ships a GLES2 driver** (`cogl/cogl/driver/gl/gles`, `_cogl_driver_gles`,
   `COGL_DRIVER_GLES2` in `cogl-renderer.c`). Mutter-on-GLES is the normal embedded/ARM path, so
   ANGLE's GLES3 is a supported driver target, not a port. The Apple-GPU-family ES3 gate we already
   fixed for GTK4/GSK applies here too.

### Why upstream "nested" does not help

`MetaBackendX11Nested` (under `src/backends/x11/nested/`) requires **both** `HAVE_X11` and
`HAVE_WAYLAND` and nests into an **X server**: `meta-renderer-x11-nested.c` renders each monitor
view into a `CoglOffscreen` ("fake_onscreen"), and `meta-stage-x11-nested.c` swaps the result onto
one **X11 window** onscreen (`cogl_onscreen_swap_buffers(stage_x11->onscreen, …)`) via Cogl's GLX
or EGL-X11 winsys. There is **no Wayland-host nested backend in upstream Mutter.** So "Mutter as a
wl client of iosc" is not a configuration — it is new code.

---

## Option (a) — Mutter nested as a client

Two sub-cases, because "nested" upstream means "into an X server," not "into iosc."

### (a1) Nest into Xios (the working upstream path, X11-nested)

`mutter --nested` against **Xios** (or Xvfb). Mutter opens an X11 window on Xios, Cogl renders into
it. **This builds with minimal Mutter change** — it's the supported nested path.

But it is the wrong substrate for the project's "native and fast" north star:

- **Software only.** Cogl's host onscreen would use the **GLX** winsys against Xios's *software*
  GLX (gallium-xlib indirect, llvmpipe). ANGLE cannot help: ANGLE-iOS is Metal-only with no X11
  EGL platform, so it cannot back an X11 window. So gnome-shell would composite on llvmpipe — the
  exact outcome `gnome-plan.md` Blocker #3 flags as "unproven / likely unbearable on an A10."
- **Two display servers stacked** (Xios + Mutter), plus the gjs proof already hit Xios's app-
  sandbox X-socket problem (it ran against a root-reachable Xvfb, not the live Xios surface).
- It throws away every GPU asset we built (iosc_gl, the IOSurface buffer path, the EGL shim).

**Verdict: usable only as a throwaway *bring-up* spike** (see "interim milestone" below) to flush
out the *non-graphics* integration — gjs, typelibs, the session/dbus/login1 plumbing, Clutter/Cogl
init — cheaply, accepting that it renders in software. Not a destination.

### (a2) Nest into iosc (a new Wayland-nested backend)

To nest Mutter *as a Wayland client of iosc*, you must write a new backend —
`MetaBackendWaylandNested` + `MetaRendererWaylandNested` + `MetaStageWaylandNested` — whose host
onscreen is a `wl_surface`/`wl_egl_window` on iosc, rendered through `wayland-egl`. On iOS that
host onscreen would go through **our existing `iosc_egl_shim`** (wl_egl_window → ANGLE IOSurface →
`iosc_iosurface` handoff → iosc composites it as one surface). Input would come back from iosc's
`wl_seat` into Mutter's seat. So it *can* get GPU, by reusing the shim.

What it needs from iosc, and the verdict:

- **Output:** iosc advertises enough (`wl_compositor` v4, `xdg_wm_base`, `wl_output`, the
  `iosc_iosurface` buffer protocol) for Mutter-the-client to map one fullscreen toplevel and hand
  it GPU buffers via the shim. ✓ already there.
- **Input/seat passthrough:** iosc's `wl_seat` (pointer+keyboard, M8) would feed Mutter's nested
  seat — but it is a *single* seat with no relative-pointer, no constraints, no tablet. gnome-shell
  is tolerant of that for a first light.
- **GLES/buffer path:** Mutter-nested would *not* need `linux-dmabuf`; it uses the `iosc_iosurface`
  buffer protocol through the shim, same as any GTK4 client. ✓ proven (M4 shim path).

But architecturally this is **two Wayland compositors stacked**: Mutter (a full wl server in its
own right) renders its entire desktop into one surface that iosc then composites alone. iosc's
xdg-shell/seat/damage/viewporter all become dead weight — iosc degenerates to "a program that
forwards one IOSurface to the Xios app and one input socket back," which is *exactly the iOS
backend job that option (b) folds into Mutter directly.* You'd write comparable new Mutter backend
code as option (b), keep a redundant compositor, and pay an extra composite + an extra buffer copy
per frame. **Verdict: dominated by (b).**

---

## Option (b) — Mutter IS the compositor (new iOS/IOSurface backend) — RECOMMENDED

Add a Wayland-mode backend, `MetaBackendIOS`, structured like `MetaBackendNative` but with **no
KMS, no GBM, no libinput, no logind/libseat device takeover** — none of which exist on iOS. Its
renderer presents to the Xios app's output IOSurface; Mutter's own Wayland server handles clients.
"iosc" stops being a process and becomes this backend; its iOS-glue files are harvested.

### The reuse map (this is why (b) is tractable)

| iosc asset (validated on-device) | Becomes, in Mutter |
|---|---|
| `iosc_gl.c` — ANGLE-EGL context whose render target **is** the output IOSurface (pbuffer-from-IOSurface as FBO 0; M3) | the **CoglOnscreen** of a custom Cogl EGL winsys (`cogl_renderer_set_custom_winsys`, the native-renderer seam) |
| `xios_surface.c` — fullscreen BGRA IOSurface alloc + `task_for_pid`/`IOSurfaceCreateMachPort` rendezvous with the Xios app | the backend's **present**/page-flip + the "monitor" the MonitorManager exposes |
| `iosc-iosurface.xml` + `xios_import_client_iosurface` — mach-port → IOSurface → ANGLE texture import of *client* buffers (M2) | a new **`MetaWaylandBuffer` type** (IOSurface), parallel to `META_WAYLAND_BUFFER_TYPE_DMA_BUF` |
| `iosc_input.c` socket protocol (24-byte pointer/key msgs; M8) + the Xios app's input forwarder | a **`ClutterVirtualInputDevice`** fed from the same socket |
| `iosc_egl_shim.dylib` — wl_egl_window → IOSurface → `iosc_iosurface` handoff (M4) | **unchanged**; it is the client-side GPU path for any wl_egl_window client (GTK4, and now Mutter's own clients) |

iosc's hand-rolled `wl_compositor`/`xdg_wm_base`/`wl_seat`/`viewporter`/`fractional-scale`/
`presentation`/`xdg-decoration`/`xdg-activation`/`subcompositor`/`wl_data_device` are all
**discarded** — Mutter's `src/wayland/` implements the same and more, correctly.

### The four new pieces of backend code

1. **`MetaRendererIOS` + a custom Cogl EGL winsys.** Subclass `MetaRenderer`; in
   `create_cogl_renderer` call `cogl_renderer_set_custom_winsys(...)` with an EGL winsys whose
   `eglGetPlatformDisplay` is **ANGLE-Metal** and whose single onscreen renders into the output
   IOSurface. This is `iosc_gl.c`'s init/begin/draw/end lifted into the Cogl winsys vtable
   (`cogl-winsys-egl-private.h` defines the platform vtable; model it on
   `cogl-winsys-egl-x11.c`). Force `COGL_DRIVER_GLES2`. One `MetaRendererView` ↔ one virtual
   monitor ↔ the iPad screen. Swap-buffers → `xios_notify_dirty` so the Xios app re-presents.

2. **A virtual MonitorManager.** Model on `MetaMonitorManagerDummy` (`meta-monitor-manager-dummy.c`)
   or the native `MetaCrtcVirtual`/`MetaVirtualMonitor` scaffolding the headless backend already
   uses: one hardwired output at the iPad's native resolution and scale (iosc already computes
   `output_scale()` and a fractional scale; reuse those numbers). No EDID, no XRandR, no KMS probe.

3. **Input → Clutter.** Mutter's native backend feeds Clutter from libinput in an input thread; we
   have no evdev. Instead create a `ClutterVirtualInputDevice` (Clutter's existing API, used by
   remote-desktop) for pointer+keyboard and push events from the `iosc_input.c` socket. The xkb
   keymap iosc already compiles on-device (us layout) carries over to Clutter's seat. This is
   strictly *less* code than iosc's seat because Clutter owns focus/serials.

4. **A Wayland IOSurface buffer type.** `src/wayland/meta-wayland-buffer.h` enumerates
   `SHM / EGL_IMAGE / EGL_STREAM / DMA_BUF / SINGLE_PIXEL`. On iOS there is no dma-buf, so add an
   IOSurface type (or graft onto the EGL_IMAGE path): when a client commits an `iosc_iosurface`
   buffer, import it as a Cogl texture. **Subtlety:** iosc imports client IOSurfaces with
   `EGL_ANGLE_iosurface_client_buffer` (pbuffer-bind), *not* `eglCreateImage`; Mutter's
   `EGL_IMAGE`/`DMA_BUF` paths assume `EGLImage`. So the import glue must use the ANGLE
   iosurface_client_buffer extension to produce the GL texture Cogl wraps — concrete, isolated work,
   and the primitive is already proven (M2). Clients keep using `iosc_egl_shim` to *produce* these
   buffers, so the client story is unchanged.

### What is *removed* relative to a Linux Mutter

- `MetaLauncher` / libseat / logind **device takeover** (DRM master, input fd leasing): not
  instantiated — our backend opens no devices. This removes Mutter's *own* hard logind dependency.
- KMS/atomic, GBM, `MetaDevicePool`, `meta-kms-*`, drm-buffer-gbm/dumb/import: not compiled into
  this backend.
- libinput / `MetaSeatNative` input thread: replaced by the virtual device.

### The session / logind story (the second real lift)

Removing Mutter's *backend* logind need does **not** remove the *session* logind need.
gnome-shell + gnome-session + gnome-settings-daemon still call `org.freedesktop.login1` (Session
object, `Inhibit`, idle, `LockSession`, `GetSessionByPID`) over D-Bus. Per `gnome-plan.md`
Blocker #4, the answer is a **stub `org.freedesktop.login1`** service answering the handful of
calls gsd/gnome-session actually make — *not* elogind (there is no VT/seat/DRM to manage). The
session **D-Bus bus** is already solved (kgx ran fine under `dbus-run-session`, M6). gnome-session
can spawn the session the old way (it still does in the GNOME 45/46 era), so `systemd --user` is
avoidable. polkit/accountsservice are stubbed or skipped (single-user jailbreak).

---

## Option (c) — iosc grows shell features itself

Keep iosc and add a panel/overview/app-grid to it (St-free, hand-written). This reaches a *usable
desktop shell* far sooner and with zero gjs/typelib/Mutter risk, and iosc already has the
compositor primitives (stacking, input, focus). But it is **explicitly not gnome-shell** — it is a
bespoke WM that happens to host GNOME *apps*. Given the project's stated convergence goal is real
gnome-shell, treat (c) as the **fallback** if Cogl-on-ANGLE proves unworkable, not the target. (It
is also the natural home for a good touch UX regardless of whether real Shell ever lands.)

---

## Recommended path + concrete engineering steps

**Pursue (b). Sequence the risk so the expensive backend code is written only after the one
make-or-break unknown is cleared.**

- **Step 0 — Cogl-on-ANGLE smoke test (DO THIS FIRST; it gates everything).** Outside Mutter,
  stand up a Cogl context on ANGLE-Metal GLES3 rendering into an IOSurface: reuse `iosc_gl.c`'s
  EGL setup, then `cogl_renderer_new` + force `COGL_DRIVER_GLES2` + a custom winsys returning that
  EGLDisplay/onscreen, and draw one `CoglPipeline` textured quad. If Cogl initializes (feature
  detection passes, GLSL compiles, FBO 0 is complete) and a quad lands in the IOSurface, the whole
  plan is green. If not, that's the wall, surfaced for ~a day of work.

- **Step 1 — interim: `mutter --nested` on Xvfb (software), to flush non-graphics bugs.** Build
  Mutter `-Dx11=true`, run nested against a root-reachable Xvfb (as the gjs GTK4 proof did), get
  *gnome-shell's JS* executing against real Meta/Clutter/Cogl/St typelibs. This is option (a1) used
  purely as bring-up: it shakes out gjs/typelib/login1-stub/gnome-session/dbus problems with no GPU
  work. Slow and software, discarded after. (Parallelizable with Step 0.)

- **Step 2 — `MetaRendererIOS` + custom Cogl winsys** (depends on Step 0). Get Mutter's stage
  rendering into the output IOSurface; Xios app presents it. No clients yet — just the shell's own
  background/stage drawing on screen.

- **Step 3 — virtual MonitorManager + virtual input device.** One monitor at iPad res; pointer/key
  from the `iosc_input.c` socket into Clutter. gnome-shell becomes interactive.

- **Step 4 — Wayland IOSurface buffer import** (the new `MetaWaylandBuffer` type via ANGLE
  iosurface_client_buffer). Now real Wayland clients (kgx, GTK4 apps via the shim) appear *as
  windows inside gnome-shell*, GPU-composited by Mutter.

- **Step 5 — session glue:** stub `org.freedesktop.login1`, run under `dbus-run-session` +
  gnome-session; bring up gnome-settings-daemon's essential pieces. Then `gnome-shell` proper.

- **Step 6 (optional) — Xwayland.** Mutter can host Xwayland for X11 apps; on iOS that's a separate
  bring-up (Xwayland rootful as a Mutter-spawned client) and not on the critical path.

Throughout, **coordinate the backend with the gjs/Mutter-typelib agent**: the Meta/Clutter/Cogl/St
typelibs are backend-agnostic (the gjs-plan already notes this), so they can be scanned now against
Mutter linked to ANGLE `libEGL`/`libGLESv2` for symbols, independent of which backend wins.

---

## Open risks (ranked)

1. **Cogl/Clutter on ANGLE-Metal GLES3 (the headline).** Cogl does its own GL feature detection and
   is stricter and older than GSK. Unknowns: FBO-0 completeness for an IOSurface-pbuffer default
   framebuffer (M4's `iosc-fbtest` says YES for a raw ANGLE pbuffer, but not yet *through Cogl*),
   GLSL version acceptance, `GL_EXT_texture_format_BGRA8888` / red-blue swizzle for BGRA IOSurfaces,
   `npot`/packed-depth-stencil, and the Apple-GPU-family ES3 gate (already patched for GSK). Mitigation:
   **Step 0** proves or kills this cheaply before any backend code.
2. **Client IOSurface import inside Mutter.** Mutter's GPU-buffer import is `EGLImage`-shaped
   (dma-buf); iosc's proven import is `EGL_ANGLE_iosurface_client_buffer` (pbuffer-bind). The new
   buffer type must bridge ANGLE's extension into a Cogl texture. Isolated, but real.
3. **logind/session.** The stub `org.freedesktop.login1` must answer exactly what gnome-session/gsd
   call, and gnome-session must start without `systemd --user`. Bounded but fiddly; `gnome-plan.md`
   #4 scopes it.
4. **D-Bus session services breadth.** Beyond the bus itself (solved), gsd wants several services
   (color, media-keys, power, xsettings); many degrade gracefully, some may block shell startup.
5. **Performance.** Interpreter-only (JIT-less) mozjs (`gjs-plan.md` #1) plus Cogl-on-ANGLE-on-Metal
   plus a full St scene graph on an A10 — gnome-shell animations may be sluggish. Functional first,
   fast later; the per-frame *compositing* path is GPU/zero-copy (the iosc win), but the *shell JS*
   is interpreter-bound.
6. **Cursor.** Mutter wants a hardware cursor plane (KMS) or falls back to a Clutter-drawn cursor;
   on iOS use the software/Clutter cursor (no plane). Minor.
7. **Damage / single-buffer present.** iosc presents one shared output IOSurface; Mutter expects to
   own swap timing and may want double/triple buffering of the *output*. Reconcile Mutter's
   `CoglOnscreen` swap model with the Xios app's single-surface present (likely a 2–3 IOSurface
   rotation on the output, mirroring how the shim rotates client buffers).

---

## Why (b), in one paragraph

iosc and Mutter both want to be *the* Wayland compositor, and only one can own the single shared
output IOSurface. Mutter's is the vastly more complete implementation and is *required* anyway (it
*is* gnome-shell). The unique, hard-won thing iosc owns is not its compositor logic — it's the iOS
**glue**: getting an IOSurface to the Xios app, rendering into it with ANGLE, importing client
IOSurfaces, and pumping UIKit input back. That glue is exactly the contents of a Mutter *backend*.
So the convergence is not "run one compositor inside the other" — it's "**retarget Mutter's
backend seam at iosc's iOS glue and retire iosc as a process.**" The custom-winsys hook Mutter's
own native backend uses (`cogl_renderer_set_custom_winsys`) is the plug; `iosc_gl.c` is the thing
that plugs into it. (Refinement, per the team: do NOT actually retire iosc — keep it as a
switchable compositor and share the iOS/GPU glue into a lib both link.)

---

## Typelib generation — the on-device step (status 2026-06-30)

gnome-shell's JavaScript consumes the **Meta / Clutter / Cogl / CoglPango / Mtk** typelibs. Mutter
is cross-built `-Dintrospection=false` off-device (cross can't run the gir dumper — an iOS Mach-O
qemu can't exec, gnome-plan Blocker #2), so the typelibs are scanned **on the device**, exactly the
Design-A pattern proven for the GTK4 stack (memory `x11-gtk4-typelibs-ondevice`).

### What's built + packaged off-device (in `x11/linux-build/out`)

18 debs across the mutter track. New/bumped runtime+dev pairs the device needs on top of the
existing GTK4/gjs/wayland stack:

| deb | role |
|---|---|
| `libmutter-14-0_46.0` | the 5 dylibs (libmutter-14 + cogl/clutter/cogl-pango/mtk in `lib/mutter-14/`) + the default plugin |
| `libmutter-14-dev_46.0` | headers + 5 `.pc` (needed to run g-ir-scanner on-device) |
| `liblcms2-2 / -dev_2.12` | colour engine (colord dep) |
| `libcolord2 / libcolord-dev_1.4.7` | client-only colour profiles (no daemon/udev) |
| `libxcomposite1 / -dev_0.4.6` | X11 Composite ext |
| `libxfixes3 / -dev_6.0.1` | bumped to ≥6 (mutter needs it) |
| `libpixman-1-0 / -dev_0.42.2` | bumped to ≥0.42 |
| `libxkbcommon0_1.7.0` + `libxkbcommon-dev_1.7.0` | **the x11 sublib `libxkbcommon-x11.0.dylib` + `xkbcommon-x11.pc` ship in the -dev deb** — install -dev on device |
| `libjson-glib-1.0-0 / -dev_1.8.0` | clutter dep |
| `libei1_1.2.1` | **inert** `libeis.dylib` shim — mutter dependency()s libeis (required:false) but still linked it; this lets dyld resolve the load command (no EIS functionality) |

Recipe note: `recipes/mutter.mk` had a bug — the `lib/mutter-N` data dir uses the **API** version
(14), not the release (46); it was copying `mutter-46` (nonexistent) so only the top-level
libmutter-14 dylib shipped. Fixed with `MUTTER_API_V := 14`. The 8 missing control templates
(`libcolord{2,-dev}`, `libxcomposite{1,-dev}`, `libmutter-14-{0,dev}`) are authored in
`build_info/`; `libxkbcommon{0,-dev}.control` are reused from `recipes/build_info/`.

### Device install order (for main to run in a device window)

dpkg-install deps before libmutter (dyld resolves the closure at scan time). Most of the GTK4/glib/
X11/wayland/ANGLE closure is already installed; these are the additions:

```
dpkg -i liblcms2-2_*.deb liblcms2-dev_*.deb \
        libcolord2_*.deb libcolord-dev_*.deb \
        libxcomposite1_*.deb libxcomposite-dev_*.deb \
        libxfixes3_*.deb libxfixes-dev_*.deb \
        libpixman-1-0_*.deb libpixman-1-dev_*.deb \
        libxkbcommon0_*.deb libxkbcommon-dev_*.deb \
        libjson-glib-1.0-0_*.deb libjson-glib-dev_*.deb \
        libei1_*.deb \
        libmutter-14-0_*.deb libmutter-14-dev_*.deb
apt-get -f install   # only if a transitive name is unmet
```

### Generating the typelibs (route + fallback)

**Primary route — `x11/linux-build/gir-build-mutter-ondevice.sh`** builds mutter 46 natively on
the iPad with `-Dintrospection=true` and lets meson drive g-ir-scanner. The meson-generated
scanner invocations correctly assemble the per-namespace filelists, the codegen'd headers
(enum-types, version, config), the `--include` GI-dependency chain, and the
`--include-uninstalled` internal order (Mtk → Cogl → CoglPango → Clutter → Meta). The script
applies the same portability patches as the cross recipe and stages the inert stub headers. It
ends by validating `gjs -c 'imports.gi.Meta'`. Heaviest step (a native mutter compile on the A10,
never done before — expect iteration); needs wayland-scanner + the -dev stack on-device.

**Reference / fallback — `out/mutter-gir-commands.txt`** holds the literal g-ir-scanner command
for each of the 6 namespaces, harvested from an off-device introspection *config* (which resolves
cleanly — proof the args are right). These document the exact `--include` deps the device must
have as girs: `GObject-2.0 Gio-2.0 Graphene-1.0 cairo-1.0 Atk-1.0 Pango-1.0 PangoCairo-1.0
GL-1.0 xlib-2.0 xfixes-4.0 GDesktopEnums-3.0`. If the full native build proves intractable, these
can be replayed standalone against the installed libmutter (after a meson *configure* to emit the
codegen headers + filelists), pointing `--library` at `/var/jb/usr/lib`.

### Validation (the milestone)

`gjs -c 'imports.gi.versions.Meta="14"; const Meta = imports.gi.Meta'` loading without error =
gnome-shell's JS substrate is unblocked. That is the gate this track has been driving toward.

---

## Cogl-on-ANGLE de-risk — architecture findings (2026-06-30)

Step 0 (the make-or-break: can Cogl init + render on ANGLE-Metal-ES3?) splits into a *structural*
question (can Cogl be plugged into our ANGLE/IOSurface stack at all?) and a *runtime* question
(does `cogl_context_new` survive ANGLE's feature/GLSL detection?). The structural question is now
**answered YES off-device**, and the exact integration seam is identified:

- **The plug is `cogl_renderer_set_custom_winsys()`** — the same hook mutter's own native backend
  uses. `meta-renderer-native.c` is the line-for-line template: it (1) defines a
  `CoglWinsysEGLVtable` platform vtable (`display_setup`/`choose_config`/`context_created`/…), (2)
  `get_native_cogl_winsys_vtable()` copies the EGL **base** vtable via `_cogl_winsys_egl_get_vtable()`
  and overrides `renderer_connect` to set `cogl_renderer_egl->platform_vtable`, (3) registers it
  with `cogl_renderer_set_custom_winsys(...)`. **`MetaRendererIOS` is this with KMS/GBM/libgbm
  swapped for ANGLE-Metal `eglGetPlatformDisplay` + the IOSurface pbuffer** — i.e. the platform
  vtable's `display_setup`/`choose_config` call into `libxios_glue`'s `xios_egl_*` (see
  iosc-shared-glue.md). Cogl 14's winsys vtable has **no onscreen members** (onscreen moved to
  `cogl-onscreen-egl.c`), so an offscreen-only render path is small.
- **Consequence for packaging:** the winsys needs cogl's **private** headers
  (`cogl-winsys-egl-private.h`, `cogl-winsys-private.h`), which are NOT in `libmutter-14-dev` (only
  the 58 public cogl headers ship). BUT the private winsys *symbols* it links
  (`_cogl_winsys_egl_get_vtable` / `_cogl_winsys_egl_renderer_connect_common` /
  `_cogl_winsys_egl_make_current` / `cogl_renderer_set_custom_winsys`) ARE **exported** from
  `libmutter-cogl-14` (mutter's own `libmutter` links them cross-dylib — verified with `nm -gU`).
  So the smoke test builds *off-device* against the mutter **source tree** (private headers) + the
  already-built `libmutter-cogl-14`, then is retargeted onto the installed device dylib paths — so
  it runs against the `libmutter-14-0` deb + ANGLE **without** an on-device mutter build. **This
  decouples the Cogl de-risk from the heavy typelib build.**
- **The IOSurface-as-FBO0 half is already proven** (M4 `iosc-fbtest`: raw ANGLE pbuffer-from-
  IOSurface is renderable as FBO 0). The new thing the smoke test adds is *Cogl* on top of that.

**DONE off-device (2026-06-30):** `x11/wayland/iosc-cogl-smoke.c` — the real `MetaRendererIOS`
Cogl winsys (the `CoglWinsysEGLVtable` platform + `get_ios_cogl_winsys_vtable()` subclassing the
EGL base + `cogl_renderer_set_custom_winsys`) → `CoglContext` → `CoglOffscreen` over a
`CoglTexture2D` → a `CoglPipeline` red quad over a green clear → `cogl_framebuffer_read_pixels`.
**Compiles clean and links to a valid iOS arm64 Mach-O with NOUNDEFS** (every cogl/EGL/glib symbol
resolved — the winsys is wired correctly against the real cogl ABI). Cross-built by
`x11/linux-build/build-cogl-smoke.sh`; device-ready binary staged at `out/iosc-cogl-smoke` (deps
retargeted to absolute device paths, ad-hoc signed). The winsys IS the real `MetaRendererIOS`
winsys — start of backend code, not throwaway.

**Runtime unknown — SETTLED on-device (2026-07-01): `RESULT: COGL-ON-ANGLE OK` on the A10.**
Cogl connected the ANGLE-Metal EGLDisplay, `cogl_context_new` passed ANGLE-Metal-ES3 feature/GLSL
detection, the offscreen FBO allocated, and the red quad read back `ff0000ff`. The whole backend
plan is GREEN — Cogl/Clutter render on our exact ANGLE/Metal/ES3 stack. Three reproducibility
gotchas it took to get there (bake these into packaging):

1. **Cogl's GLES driver `dlopen`s the LINUX soname `libGLESv2.so.2` + `libEGL.so.1`, not the iOS
   `.dylib` names.** Fix on-device was symlinks in `/var/jb/lib/angle`
   (`libGLESv2.so.2`→`libGLESv2.dylib`, `libEGL.so.1`→`libEGL.dylib`; also a versioned
   `libGLESv2.2.dylib` install_name mismatch — same class). **For reproducibility the `angle` deb
   should ship these Linux-style symlinks (or a mutter-deb postinst should create them).**
2. **The client needs GPU entitlements** — sign with `iosc-gpu-client-ent.xml` (ad-hoc alone → no
   Metal device, black screen; the AGX IOKit wall from memory `fakesigned-metal-gpu-entitlement`).
3. **`libmutter-14-0` only needs UNPACKING** — `dpkg` "dependency problems / unconfigured" is fine;
   the cogl dylib loads via `DYLD_LIBRARY_PATH`.

Device run: `DYLD_LIBRARY_PATH=/var/jb/usr/lib:/var/jb/usr/lib/mutter-14:/var/jb/lib/angle
./iosc-cogl-smoke` (smoke signed with the gpu-client entitlements).

## Backend code status (2026-06-30) — WRITTEN + compile-clean off-device

All of MetaBackendIOS beyond the winsys is now real code in `x11/wayland/`, each compiled against
the **real Mutter 46.0 source tree** in the Docker volume under mutter's own strict per-object
flags (harvested from ninja — `-Werror=implicit`, `-Wmissing-prototypes`, …), zero diagnostics on
our code. Harness: `x11/linux-build/build-backend-check.sh` (stages the flat files into the eventual
`src/backends/ios/` layout, reuses the harvested command, generates any protocol header with the W0
native `wayland-scanner`). The Step-0 winsys is `iosc-cogl-smoke.c` (compile+link-clean, device-ready
`out/iosc-cogl-smoke`); the four new pieces:

| piece | files | modeled on | verification |
|---|---|---|---|
| **MetaMonitorManagerIOS** (Step 3) — one fixed 2160x1620 @ scale-2 output (MetaGpu/Crtc/Output-IOS) | `meta-monitor-manager-ios.{c,h}` | `meta-monitor-manager-dummy.c` | `.o` clean |
| **Input pump** (Step 3) — pointer+keyboard `ClutterVirtualInputDevice` on the default seat, fed by the Xios input socket via a GLib fd source | `meta-input-ios.{c,h}` | `meta-remote-desktop-session.c` / EIS | `.o` clean |
| **IOSurface MetaWaylandBuffer type** (Step 4) — `iosc_iosurface` global + IOSurface→EGLImage→Cogl import | `meta-wayland-iosurface.{c,h}` + `linux-build/patches/mutter/meta-wayland-buffer-iosurface.patch` | `meta-wayland-dma-buf.c` | `.o` clean; the patched core `meta-wayland-buffer.c` also compiles clean |
| **login1 / gnome-session stub** (Step 5) — GDBus daemon answering the Manager/Session/Seat calls gsd/gnome-session make | `xios-login1-stub.c` | logind D-Bus API | compile-clean **and fully linked**, device-ready `out/xios-login1-stub` |
| **MetaRendererIOS** (Step 2, completes it) — MetaRenderer + the inline ANGLE-Metal Cogl winsys (the smoke's, now real) + a view that renders zero-copy INTO the output IOSurface (same IOSurface→EGLImage→Cogl bridge as the wl_buffer type); `present()` = flush + `xios_notify_dirty` | `meta-renderer-ios.{c,h}` | `meta-renderer-native.c` | `.o` clean (winsys inline via `cogl/cogl-mutter.h`, no COGL_COMPILATION) |

**The `MetaBackend` assembly is COMPLETE — all pieces written + compile-clean vs real 46.0.** With
`native_backend=false` the concrete `MetaSeatNative`/`MetaVirtualInputDeviceNative`/
`MetaClutterBackendNative` are compiled OUT and `MetaSeatX11` needs an X display, so the backend
supplies its own — all done:

- **MetaVirtualInputDeviceIOS** (`meta-virtual-input-device-ios.{c,h}`) — pump notify_* → ClutterEvents
  via the clutter-mutter constructors + `_clutter_event_push` (light path, no input-thread).
- **MetaSeatIOS** + **MetaKeymapIOS** (`meta-seat-ios.{c,h}`, `meta-keymap-ios.{c,h}`) — `ClutterSeat`
  with two logical core devices, a text-direction keymap, and the 13 vfuncs incl.
  create_virtual_device→MetaVirtualInputDeviceIOS. (base `ClutterInputDevice` is instantiable, so no
  MetaInputDeviceIOS needed.)
- **MetaClutterBackendIOS** (`meta-clutter-backend-ios.{c,h}`) — get_renderer/get_default_seat/
  create_stage(base `MetaStageImpl`)/is_display_server; near-copy of the native clutter backend.
- **MetaBackendIOS** (`meta-backend-ios.{c,h}`) — the capstone: create_clutter_backend/renderer/
  monitor-manager/default-seat/color-manager/cursor-renderer (software), adds a `MetaGpuIOS` in
  constructed, starts the input pump in post_init; the keymap/stage/pointer-constraint vfuncs are
  minimal (fixed "us", single monitor, no constraints). All 9 backend `.o`s compile clean under
  mutter's own strict flags.

One design fork is settled in code: the renderer view renders zero-copy directly into the output
IOSurface (fallback if that IOSurface-EGLImage proves non-FBO-renderable at runtime = a plain
offscreen + a present-time blit, a localized change).

**What's left is INTEGRATION/packaging, not backend code:** (1) drop the `src/backends/ios/*` files
into the mutter tree + add them to `src/meson.build`; (2) a `meta-context-main.c` patch adding the
Wayland→`MetaBackendIOS` branch (like the existing buffer.c patch); (3) call
`meta_wayland_iosurface_init()` from the wayland compositor bring-up (parallel to the dma-buf init);
(4) link `libxios_glue` (switch the files off `xios-glue-stub.h` to `<xios-glue.h>`). Then the
on-device typelib build + running the backend.

All four target the planned `libxios_glue` via `x11/wayland/xios-glue-stub.h` (the exact API the
shared-lib split, `iosc-shared-glue.md`, must export): `xios_output_geometry`/`_scale`,
`xios_input_socket_*` + `struct xios_in_msg`, `xios_import_client_iosurface`/`_release`,
`xios_egl_image_from_iosurface`/`_destroy_image`. No `iosc.c` was touched.

**Refinement to Risk #2 (resolved in code):** the mutter cogl fork dropped the public
foreign-GL-texture wrap, so the pbuffer+bind→wrap route this doc originally sketched has no clean
public cogl seam. The IOSurface buffer type instead goes IOSurface → **EGLImage** →
`cogl_egl_texture_2d_new_from_image()` — the *same* idiomatic path mutter uses for its EGL_IMAGE and
DMA_BUF types, so the IOSurface buffer composites uniformly and needs only public cogl. Cost: the
glue must produce an EGLImage from an IOSurface on ANGLE-Metal, which has no direct route — it needs
a wrapping `MTLTexture` + `EGL_ANGLE_metal_texture_client_buffer` (verify our ANGLE build exposes it;
else the pbuffer+bind fallback stays entirely inside `libxios_glue`, mutter-side code unchanged).

## build5: X11/xcb weak-link — the device-load fix (2026-06-30)

The on-device backend smoke died at **dyld load**, before MetaBackendIOS ran: `libmutter-14.0.dylib`
links the whole X11/xcb closure (`@rpath/libxcb-randr.0.dylib`, `libxcb-res.0.dylib`, `libX11-xcb.1`,
`libX11.6`, …), and those libs do not exist on the iPad (Wayland-only, no XWayland).

**Root cause (not the xkbcommon-x11 patch):** mutter 46 hardcodes `have_x11 = true` in `meson.build`
("For now always require X11 support"). There is **no `x11` meson option** — only `xwayland` — so
`-Dxwayland=false` does *not* turn off `have_x11`, and `have_x11` alone pulls the X11/xcb dep block
into `libmutter`, `libmutter-cogl-14`, and `libmutter-mtk-14` (`src/meson.build` `if have_x11`, plus
`mtk`/`cogl` linking `x11_dep`).

**Fully dropping X11 is NOT a build-flag flip on mutter 46.** `core/frame.c` and `core/keybindings.c`
are in the **always-compiled** base `mutter_sources` list and use X11 **unconditionally**
(`#include <X11/Xatom.h>`, call `meta_x11_display_register_x_window` / `meta_x11_display_grab_keys`
with no `HAVE_X11` guard; those symbols live only in `have_x11_client`-gated files). Building X11-off =
backporting GNOME 47/48's "x11-optional" work across ~18 files — out of scope, and runtime-risky. That
is exactly why upstream hardcodes it.

**Fix: weak-link the dead X11/xcb load commands** (`tools/macho-weaken.py`, wired into
`mutter.mk:mutter-package` before SIGN). It flips `LC_LOAD_DYLIB` → `LC_LOAD_WEAK_DYLIB` for the whole
X/xcb set so dyld tolerates those libs being **absent** and binds their (never-called) symbols to 0;
the X11 code is dead on iOS (Wayland + MetaBackendIOS, never MetaBackendX11). `libxkbcommon.0` stays
**strong** (the Wayland keymap uses it for real). Byte-length-preserving; SIGN re-covers the edit
(Procursus ldid → `flags=0x2(adhoc)`). We ship **zero** dead X11 debs and `libmutter-14-0`'s `Depends`
gains no X11 entry. `MinimumOSVersion` (LC_BUILD_VERSION minos 16.0) is untouched.

**Verification** (replaces the unreachable "`otool -L | grep xcb` is empty" — the compiled-in X11 code
means the load commands must remain, just weak):
`otool -l out/…/libmutter-14.0.dylib` shows all 16 X/xcb entries as `LC_LOAD_WEAK_DYLIB` and
`libxkbcommon.0` as `LC_LOAD_DYLIB` (strong). Staged in `out/`: the weakened+resigned
`libmutter-14-0_46.0` deb (16 weak in libmutter, 5 in cogl, 1 in mtk) + `out/mutter` resigned with
`iosc-gl-ent.xml`. Reproducible: `build-mutter.sh` now mounts `tools/` and the recipe hard-errors if
`macho-weaken.py` is absent.

**The weaken must cover the whole RUNTIME CLOSURE, not just libmutter (2026-06-30).** On device,
libmutter loaded, but dyld then failed one level deeper: `libxkbcommon-x11.0.dylib` (shipped in
`libxkbcommon-dev`, present on device via the `enable-x11=true` build patch) STRONG-links
`@rpath/libxcb-xkb.1.dylib`, which is **absent**. Weak-linking libmutter's *reference* to
`libxkbcommon-x11` did nothing because that lib is **present** — dyld loads a present lib regardless of
a weak reference, then processes *its* load commands. Key distinction: **weak-linking only helps when
the target is absent.** A closure survey (`otool -L` every dylib in the `out/` mutter-track debs) showed
the base X libs (`libX11.6`, `libxcb.1`, `libxcb-render.0`, `libXrender.1`, …) are **present** (cairo +
gtk4 load fine on device and strong-link them); the only **absent** extension sublibs are
`libxcb-randr.0` / `libxcb-res.0` (weakened inside libmutter) and `libxcb-xkb.1` (the sole remaining
strong ref, inside `libxkbcommon-x11.0.dylib`). Fix: weaken `libxcb-xkb.1` **inside**
`libxkbcommon-x11.0.dylib` and repack `libxkbcommon-dev` (kept `libxcb.1` + `libxkbcommon.0` strong —
both present). Chosen over "don't ship libxkbcommon-x11" because the on-device typelib build needs it to
link. Host tool for repacking any closure deb: `tools/weaken-deb.sh <deb> <absent-lib> …` (extract →
macho-weaken → `codesign -f -s -` → regenerate md5sums/Installed-Size → repack root:root; idempotent).
Final closure check: no dylib in `out/` STRONG-links any of `libxcb-randr|res|xkb`, `libxcb-shape`,
`libX11-xcb`. NOTE: `libxkbcommon-dev` is built by the Wayland-track recipe (not `mutter.mk`), so its
weaken is NOT yet auto-wired — re-run `weaken-deb.sh out/libxkbcommon-dev_*.deb libxcb-xkb.1.dylib`
after any libxkbcommon rebuild.

**Weak-linking a lib is a TWO-STAGE edit on chained-fixups binaries — the load command alone is not
enough (2026-06-30).** After the load-command weaken, the device got *past* the missing-library wall but
died at the next dyld stage: `Symbol not found: _xcb_res_client_id_value_next` (from the absent
`libxcb-res`). Root cause: `LC_LOAD_DYLIB`→`LC_LOAD_WEAK_DYLIB` makes the *library* optional, but the
per-symbol IMPORTS from it are still regular (non-weak), and these dylibs use `LC_DYLD_CHAINED_FIXUPS`
(verify: `otool -l | grep CHAINED`) — so dyld binds through the chained-fixups **imports table**, where
each import has its own `weak_import` bit. dyld reaches the symbol-bind stage, the lib is gone, and a
strong import has nowhere to resolve. `tools/macho-weaken.py` now does BOTH stages: after flipping the
load command it sets `weak_import` on every chained-fixups import bound to a now-weak library (the bit
dyld actually uses) AND `N_WEAK_REF` (n_desc 0x0040) on the matching `LC_SYMTAB` undefined symbols (so
`nm -m` shows "weak external"). It weakens imports from ALL weak-linked libs, not just the absent ones —
harmless for the present ones (a weak import from a present lib still binds normally), and it keeps the
weak-lib invariant. Counts: libmutter 250 imports, cogl 34, mtk 5, libxkbcommon-x11 69; `libxkbcommon.0`
imports (the live keymap path) stay STRONG because that lib's load command is strong. Verify:
`python3 tools/… inspect` or `nm -m …dylib | grep -c 'weak external'`, and no undefined symbol from an
absent lib should be plain "external". The two `out/` debs were re-staged with imports weakened (sigs
`codesign --verify` OK, minos 16.0, md5sums regenerated).

**PAST DYLD — next wall was a PACKAGING gap: mutter's GSettings schemas were dropped from the deb
(2026-06-30).** With both weak stages done, `mutter --wayland` reached `main()` ("Running Mutter (using
mutter 46.0) as a Wayland display server") then aborted: `GLib-GIO-ERROR: Settings schema
'org.gnome.mutter' is not installed`. Cause: `mutter.mk:mutter-package` only copied `lib/` + dev headers
and dropped mutter's whole `share/` tree — 104 files: the 2 schemas (`org.gnome.mutter{,.wayland}
.gschema.xml`), the GConf convert file, 4 gnome-control-center keybinding lists, ~97 locale `.mo`. Fix:
`mutter-package` now copies `share/{glib-2.0,GConf,gnome-control-center,locale}` (skips `man/` — the
minos stamper double-zsts it into `mutter.1.zst.zst.zst`) and `build_info/libmutter-14-0.postinst` runs
`glib-compile-schemas` on install (same as the libgtk-4-1 deb). The `out/libmutter-14-0` deb was host-
repacked to include the tree + postinst (112 md5sums, weak-link work intact — verified). Loose schemas
also staged at `out/mutter-schemas/` for a manual drop-in. Schemas are the first of several session
data layers (expect `gsettings-desktop-schemas` next).

## Consolidated mutter-on-A10 device window (what to run, in order)

One focused window covers both the typelib milestone and the Cogl de-risk:

1. **Install the deb set** (the "Device install order" section above): the 18 mutter-track debs on
   top of the existing GTK4/gjs/wayland/ANGLE stack.
2. **Cogl de-risk (quick, no build):** push `out/iosc-cogl-smoke`, run it. Needs only
   `libmutter-14-0` + ANGLE — independent of steps 3–4. Settles the make-or-break in seconds.
3. **Typelib generation (heavy):** `gir-build-mutter-ondevice.sh` — native mutter introspection
   build → the 6 typelibs. Verify `wayland-scanner` + the dependency girs are present first.
4. **Milestone validation:** `gjs -c 'imports.gi.versions.Meta="14"; imports.gi.Meta'`.
5. **(session step, later) login1 stub:** push `out/xios-login1-stub` (already linked + device-ready,
   deps on `/var/jb/usr/lib`, ad-hoc signed); run it to own `org.freedesktop.login1` before
   gnome-session/gsd. `XIOS_LOGIN1_BUS=session` to own it on the session bus under
   `dbus-run-session` (no system bus needed).

Run step 2 first — it is cheap and high-signal, so a Cogl wall (if any) is known before committing
to the long step 3. All 18 mutter-track debs (incl. `libxfixes3/-dev` 6.0.1) + both device-ready
binaries are confirmed staged in `x11/linux-build/out/`.
