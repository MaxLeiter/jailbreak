# Wayland on iOS — feasibility & plan

Status: **Historical feasibility baseline; iosc/Wayland is now an active implementation.** Companion to
[`../SCOPE.md`](../SCOPE.md). Scope: can we stand up Wayland on the jailbroken iPad
alongside the working native X server (Xios), and is it worth it?

> **Current status (2026-07-03): superseded as a status source.** The Wayland stack moved well
> past research: iosc is the in-tree compositor, Wayland apps are being packaged/smoked, and
> Xwayland-on-iosc is active. Use [`docs/handoff/iosc-compositor.md`](handoff/iosc-compositor.md)
> and [`docs/handoff/wayland-apps.md`](handoff/wayland-apps.md) for current state.

---

## TL;DR verdict

**Feasible, and substantially de-risked by prior art — but it is a *new compositor*, not a
port of an existing one.** Standard Wayland compositors (wlroots/Mutter/kwin/Weston) assume
Linux **DRM/KMS + GBM + libinput + libseat/logind** — none of which exist on iOS. So Wayland
here means the *same move we already made for X*: a **custom minimal compositor** built on
`libwayland-server`, presenting client buffers through **Metal/IOSurface** and feeding input
from UIKit — exactly analogous to Xios's custom Xvfb/IOSurface DDX.

Two findings change the risk profile from "speculative" to "tractable":

1. **`libwayland` already runs on Darwin.** Sergey Bugaev ported `libwayland-client/server/
   cursor` + `wayland-scanner` to Mac OS X years ago; the standard non-Linux build path
   (FreeBSD/NetBSD/OpenBSD, and now **macOS via MacPorts**) is `libwayland` + **`epoll-shim`**
   (epoll/timerfd/signalfd/eventfd on top of kqueue). `epoll-shim` has had a maintained
   **macOS port since Jan 2023**. The protocol library is small and portable.

2. **A reference compositor with our exact buffer-sharing trick already exists.** Bugaev's
   **Owl** (`owl-compositor/owl`) is a libwayland-server compositor on Cocoa that implements
   `wl_compositor`, `wl_subcompositor`, `xdg_shell` (stable + zxdg-v6), `wl_seat`
   (pointer+keyboard via xkbcommon), `wl_shm`, data-device/clipboard — **and a custom
   `zowl_iosurface_v1` + `zowl_mach_ipc_v1` protocol that shares client buffers as
   `IOSurface`s passed over a mach port.** That is the *same mach-port + `IOSurfaceCreateMachPort`
   rendezvous we already hand-rolled in `apps/Xios/Sources/XSurface.c` and
   `linux-build/patches/xios/xios_surface.c`.* Owl is GPL-3.0 and AppKit-bound, so not a
   drop-in for iOS, but it is a near-complete design template (and partial code donor) for the
   Wayland glue we'd otherwise write from scratch.

**Historical recommendation:** pursue as a parallel *research/prototype* track while keeping X11
usable. That prototype has since become the active iosc/Wayland track, including Wayland app
packaging and Xwayland integration work. The rationale below still explains why iosc exists, but
it is no longer a future-only proposal.

---

## Why standard Wayland doesn't drop onto iOS

A Linux Wayland compositor is a **display server**: it owns the GPU and screen directly. The
stack underneath every off-the-shelf compositor is Linux-kernel-specific:

| Layer | Linux mechanism | On iOS |
|---|---|---|
| Mode-setting / scanout | DRM/KMS (`/dev/dri/card0`) | **absent** — UIKit/`CADisplay` owns the panel |
| Buffer allocation | GBM + `dma-buf` | **absent** — use `IOSurface` |
| GPU buffer import | EGL `EXT_image_dma_buf_import` | **absent** — `IOSurface`→Metal/`CVPixelBuffer` |
| Input | `libinput` + evdev (`/dev/input/*`) | **absent** — UIKit touch/keyboard events |
| Session/VT | `libseat` + logind / direct DRM master | **absent** — there is no seat/VT |
| Event loop | `epoll`/`timerfd`/`signalfd` | shim with **kqueue** (`epoll-shim`) |

So **wlroots, Mutter, kwin, Weston are out as-is.** Their backends are written *to drive DRM*.
The headless backend doesn't help much: recent **wlroots makes `libseat` mandatory** for the
session even headless, and its allocators assume GBM/DRM-dumb buffers. We don't want a backend
that "drives a display" — on iOS, **UIKit already owns the display**, and the compositor must be
a UIKit app that happens to speak the Wayland protocol. That inverts wlroots's whole model.

This is the identical conclusion SCOPE reached for X ("no Xorg DDX for iOS → write a custom
kdrive-style DDX into an IOSurface"). Wayland's answer is the same shape: **a custom compositor
on `libwayland-server`.**

---

## The dependency stack — what we'd cross-compile (LIGHT)

All small, all C, all proven on Darwin. None heavier than packages we already build.

| Package | Role | Procursus? | Notes |
|---|---|---|---|
| `libffi` | wayland-scanner / libwayland | **already in Procursus** | reuse |
| `epoll-shim` | epoll/timerfd/signalfd/eventfd → kqueue | no → **new recipe** | macOS port exists (MacPorts); the lynchpin shim |
| `wayland` | `libwayland-client` + `-server` + `wayland-scanner` | no → **new recipe** | needs `-lepoll-shim`; one shm patch (`os_create_anonymous_file`: `memfd_create` → `shm_open(SHM_ANON)`/tmpfile) |
| `wayland-protocols` | `xdg-shell`, `linux-dmabuf`, … XML | no → **new recipe** | pure data files, no compile; trivial |
| `libxkbcommon` | keymap compilation for `wl_keyboard` | no → **new recipe** | small; also independently useful to the X side |

Recipe authoring fits the existing pattern (`linux-build/recipes/*.mk`, meson cross-file like
`pango.mk`; quilt series under `ports/<pkg>/`). New files with distinct names only — no edits to
`procursus-vol*`, `build-gtk.sh`, or other agents' recipes.

**Cross-compile concerns and how each is handled:**

- **Event loop** — build `libwayland` against `epoll-shim` (the FreeBSD/NetBSD/MacPorts recipe
  is the template). `wl_event_loop` is the only real Linux coupling; `epoll-shim` closes it.
- **`wl_shm` anonymous file** — `os_create_anonymous_file()` uses `memfd_create` on Linux;
  the known Darwin fix is `shm_open` with `SHM_ANON`/a random name then `unlink`. One patch.
- **fd passing** — `wl_shm`/dmabuf pass fds over the Unix socket via `SCM_RIGHTS`, which works
  on Darwin (Bugaev's port and `waypipe-darwin` both rely on it).
- **`SO_PEERCRED`** — Wayland uses it for client pid/uid; Darwin has `LOCAL_PEERPID`/
  `getpeereid` (we already use `LOCAL_PEERPID` in `xios_surface.c`). Trivial shim.
- **`linux/input-event-codes.h`** — `wl_pointer`/`wl_keyboard` button/key constants; vendored
  as a header (it's just `#define`s), exactly as Bugaev did.

**Build cost:** small. `wayland` + `epoll-shim` + `libxkbcommon` are each minutes-scale builds,
far below the GTK chain already in flight. **Per the Phase-1 constraint, no Docker build has been
run; validating these recipes is the proposed first action, gated on coordinator go-ahead.**

---

## Prior art: Owl — the linchpin

`owl-compositor/owl` (GPL-3.0, ~131 source files, Objective-C/Cocoa) is a working
libwayland-server compositor for Darwin. Its tree maps almost 1:1 onto what we need:

```
Sources/Compositor/   OwlCompositor (wl_compositor), OwlSurface/State, OwlSubcompositor/
                      Subsurface, OwlRegion, OwlBuffer + OwlShmBuffer + OwlIOSurfaceBuffer,
                      OwlZowlIOSurfaceManagerV1 / OwlZowlIOSurfaceV1   ← IOSurface buffers
Sources/Shell/        OwlXdgWmBase / OwlXdgSurface / OwlXdgToplevel (+ zxdg-v6), OwlWlShell,
                      OwlWindow / OwlWindowWrapper   ← toplevel → native window mapping
Sources/Seat/         OwlSeat, OwlPointer, OwlKeyboard   ← wl_seat via xkbcommon
Sources/Mach/         OwlMIG, OwlZowlMachIpcV1 / OwlZowlMachIpcPortV1   ← mach-port buffer handoff
Sources/Data/         wl_data_device + wlr-data-control (clipboard)
Sources/Protocol/     xdg-shell.xml, xdg-shell-unstable-v6.xml, owl-iosurface-unstable-v1.xml,
                      owl-mach-ipc-unstable-v1.xml, wlr-data-control-unstable-v1.xml
Sources/App/          OwlAppDelegate (Cocoa)   ← the only deeply AppKit-bound layer
```

What this buys us:

- **The Wayland-protocol glue is already written and debugged on Darwin** — surface/buffer
  lifecycle, commit/damage, subsurfaces, xdg_shell configure/ack handshakes, seat focus,
  keyboard maps. This is the bulk of compositor tedium and the easiest place to get the
  protocol subtly wrong.
- **It already shares `IOSurface` buffers from client to compositor over a mach port** —
  the identical mechanism as our Xios DDX. We've independently proven that primitive works
  on this exact device; Owl proves it works *as a Wayland buffer protocol*. The two halves fit.
- **`wl_shm` and `IOSurface` buffer backends both exist** (`OwlShmBuffer` vs
  `OwlIOSurfaceBuffer`), exactly our "software MVP, zero-copy GPU later" split.

What does *not* port and must be rewritten:

- **The App/Window/render layer is AppKit** (`NSWindow`/`NSView`, free-floating desktop
  windows, GNUstep). iOS has no `NSWindow`; we composite `UIView`/`CALayer`s ourselves. This
  is precisely our SCOPE Stage 3/4 work, and **we already own this layer from Xios** (CAMetalLayer
  + IOSurface→Metal texture in `XScreen.swift`; a `CALayer` can even take an `IOSurface` as
  `.contents` directly, no Metal needed for the simple path).
- **License: GPL-3.0.** Linking/forking Owl makes our compositor GPL-3.0 (vs. Xios's MIT-ish X
  stack). For a personal jailbreak project on a personal Sileo repo that's acceptable, but it's
  a real constraint — flag before reusing Owl *code* (its *design* is free to follow). A
  clean-room compositor written directly on `libwayland-server` (MIT) avoids it if we care.

---

## wlroots vs. fully-custom — recommendation: **fully-custom (Owl-style)**

| | wlroots | Fully-custom on `libwayland-server` |
|---|---|---|
| Display model | "I drive DRM" — wrong for iOS (UIKit owns the screen) | App owns the screen; compositor presents into it — right |
| Mandatory deps | `libseat` (mandatory in recent), udev, GBM/DRM allocators, pixman | just `libwayland` + `xkbcommon` + `epoll-shim` |
| iOS fit | would need a custom backend *and* to stub/replace seat+allocator+renderer — fighting the framework | direct: own the event loop, own presentation |
| Prior art on Darwin | none | **Owl** (exact template) |
| Effort | port a large framework against its grain | write a focused compositor; reuse Owl design + Xios display |

A wlroots custom backend sounds like leverage but you still inherit its allocator/renderer/seat
assumptions; you'd be stubbing the very abstractions that make wlroots wlroots. **Custom is
simpler here**, and the Owl precedent means "custom" is mostly assembly, not invention. Same
judgment as choosing a custom kdrive DDX over porting Xorg.

---

## Minimal compositor architecture for iOS

Reuse Xios's proven iOS-side machinery; replace the X protocol with Wayland.

```
Wayland clients (GTK/Qt/SDL/weston-*, GDK_BACKEND=wayland)
      │  wl_shm (CPU)  ──────────────► shared mmap'd fd  ─┐
      │  zwp_linux_dmabuf / IOSurface ► IOSurface (mach) ─┤  per-surface buffer
      ▼                                                   ▼
  «iosc»  custom Wayland compositor  (libwayland-server, in the iOS app process)
      │   wl_compositor · wl_subcompositor · wl_shm · xdg_shell · wl_seat · wl_output · wl_data_device
      │   each committed wl_surface ──► a CALayer / Metal texture (its buffer's IOSurface or shm)
      ▼
  UIKit / CAMetalLayer  ──►  display  (reuse XScreen.swift's Metal path)
      ▲
  UIKit touch/keyboard ──► wl_pointer / wl_keyboard (+ xkbcommon keymap)   [replaces XTEST]
```

**Protocol surface (MVP → full):**

- *MVP:* `wl_compositor`, `wl_shm`, `wl_subcompositor`, `xdg_wm_base`+`xdg_surface`+
  `xdg_toplevel`, `wl_seat` (pointer+keyboard), `wl_output`. Single fullscreen toplevel
  (analogous to Stage 1's one fullscreen X screen).
- *Then:* `xdg_popup` (menus), `wl_data_device` (clipboard, map to `UIPasteboard`),
  `wp_viewport`, `wp_presentation`.
- *GPU:* `zwp_linux_dmabuf_v1` or an `owl_iosurface`-style protocol for zero-copy IOSurface
  buffers (see GL story).

**Buffer paths (mirror Xios exactly):**

- **`wl_shm` (CPU, MVP):** client mmaps a pool fd; compositor mmaps the same fd; upload the
  damaged region to a Metal texture per commit. This is the Wayland analogue of Xios's
  `-fbdir` mmap fallback, and the right first milestone (software, like our llvmpipe X clients).
- **IOSurface (zero-copy, GPU):** client renders into an `IOSurface`, hands its mach port to
  the compositor — **reuse `xios_surface.c`'s `task_for_pid` + `IOSurfaceCreateMachPort` +
  `mach_msg` rendezvous verbatim**, just triggered by a Wayland request instead of our private
  socket. Compositor wraps it as a Metal texture (`makeTexture(descriptor:iosurface:)`, already
  in `XScreen.swift`) or sets it as a `CALayer.contents`. This is where Wayland's per-surface
  model pays off: it's *one IOSurface per window* natively, no XComposite redirection needed.

**Display:**

- *MVP:* one fullscreen surface → the existing `CAMetalLayer` aspect-fit blit (drop-in from Xios).
- *Stage 3/4 parallel:* one `UIView`/`CALayer` per `xdg_toplevel`, IOSurface as layer contents;
  the iOS compositor *is* the window manager. This is the same endgame SCOPE Stage 4 describes
  for X — but Wayland gets there without XComposite, because surfaces are already separate buffers.

**Input:** UIKit `touchesBegan/Moved/Ended` → `wl_pointer` enter/motion/button/frame; hardware/
soft keyboard → `wl_keyboard` with an xkbcommon keymap sent to clients. Replaces `XInput.c`'s
XTEST path; the UIKit→coordinate mapping in `XScreen.framebufferPoint` ports directly.

**Entitlements:** identical to Xios — `iokit-user-client-class` (AGX/IOSurface clients),
`get-task-allow`, `task_for_pid-allow` on the compositor, `/var/jb` path exception (see
`apps/Xios/entitlements.plist`). The mach-port buffer handoff has the same requirements as our
DDX, already solved.

---

## The GL story (ties to the hardware-GL / ANGLE track)

- `wl_shm` clients are **software-rendered** (CPU pixels) — fine for the MVP and for GTK/Qt's
  software paths, the same posture as our llvmpipe-only X clients today.
- Clients that want **hardware GLES** use **EGL** (`libwayland-egl` + a platform). On Linux that
  EGL renders into a GBM/dma-buf buffer; on iOS the equivalent is **EGL rendering into an
  `IOSurface`**, which is exactly **ANGLE's Metal backend** capability. So real accelerated
  Wayland clients require: ANGLE (EGL/GLES→Metal) + a Wayland EGL platform that allocates
  `IOSurface` buffers + the `linux-dmabuf`/`owl_iosurface` protocol to hand them to the
  compositor. **This is the hardware-GL/ANGLE track's deliverable**; the compositor side is
  ready for it the moment the IOSurface buffer protocol lands.
- **Phase-1 stance:** prove `wl_shm` first; treat GPU GLES as a milestone gated on ANGLE,
  shared with the X-side GL effort.

---

## Effort estimate (phased)

| Phase | Work | Estimate | Risk |
|---|---|---|---|
| **W0** | Recipes: `epoll-shim`, `wayland`, `wayland-protocols`, `libxkbcommon`; validate cross-compile to `iphoneos-arm64-rootless`; smoke-test `wayland-scanner` + a `wl_display` listen/connect on device | ~2–4 days | **Low** — proven on Darwin/MacPorts |
| **W1** | Single-surface `wl_shm` compositor MVP: `wl_compositor`+`xdg_shell`+`wl_shm`+`wl_seat`+`wl_output`, present one fullscreen toplevel via Xios's Metal layer, UIKit input → pointer/keyboard. Target: `weston-terminal` or a GDK-wayland GTK app paints + takes input on-device | ~1–2 weeks | **Medium** — protocol plumbing, eased by Owl as template |
| **W2** | IOSurface zero-copy buffers (reuse `xios_surface.c` rendezvous as a Wayland buffer protocol); `xdg_popup`, clipboard via `UIPasteboard` | ~1 week | **Medium** — primitive already proven in Xios |
| **W3** | Per-window compositing: one `UIView`/IOSurface per toplevel; iOS compositor = WM | shares SCOPE Stage 3/4 budget | **Medium** |
| **W4** | Accelerated GLES clients | gated on **ANGLE track** | **High** (separate track) |

W0+W1 is the real feasibility proof and is small. Everything past W1 parallels work the X track
is already funding (per-window compositing, GL).

---

## Recommendation & worth-it verdict

**Historical verdict:** build W0 and W1 as a parallel research track while keeping X11 usable.
That work has happened; keep this section as the original rationale. Reasons:

1. **X11 already works** end-to-end on-device (Xios verified). Wayland delivers **no new
   user-visible capability today** — the GTK/Qt apps we care about run on X via our stack now.
   So Wayland is *not* a near-term replacement; framing it as one would be dishonest.
2. **But Wayland is the architecturally cleaner endgame substrate.** SCOPE's Stage 3/4 vision —
   *each window is a native iOS view* — is *native* to Wayland (one buffer per surface) and is
   something we **bolt onto** X with XComposite redirection. If the long game is "Linux apps as
   first-class iOS windows," Wayland is the better foundation, and the IOSurface-per-surface
   buffer model is the same IOSurface plumbing we've already built.
3. **The risk is low and the head start is large.** `libwayland`+`epoll-shim` on Darwin is a
   solved problem; Owl is a complete design template that even shares our IOSurface-over-mach
   trick; the iOS display/input/entitlement layer is reusable from Xios. We can *prove* a real
   Wayland client painting on the iPad for ~2 weeks of effort, which is cheap insurance on the
   strategic direction.
4. **Don't over-commit.** The full modern-Wayland desktop tail (xdg-desktop-portal, dbus,
   pipewire for screenshare/portals, many clients hard-assuming systemd/logind) is heavier than
   X's. Prove the core, keep X shipping, and only graduate Wayland to "production" if W1–W3
   demonstrate the per-window UX is clearly better than X+XComposite.

**Net:** Wayland on this iPad proved feasible enough to become the iosc track. The active
question is no longer whether to prototype it, but which Wayland apps/session paths are ready to
feature and publish.

---

## Phase-1 gate (historical constraints)

- This document was originally **research/design only**. At the time, no Docker build was run,
  and `procursus-vol*`, `build-gtk.sh`, and other agents' files were not touched.
- **W0 recipes are now drafted** (new files, distinct names — no GPL code; structure follows the
  proven `fribidi`/`pango`/`brotli` recipes):
  - `linux-build/recipes/{epoll-shim,wayland,wayland-protocols,libxkbcommon}.mk`
  - `linux-build/recipes/build_info/{libepoll-shim0,libepoll-shim-dev,libwayland0,libwayland-dev,
    wayland-protocols,libxkbcommon0,libxkbcommon-dev}.control` — Procursus ships none of these
    packages, so each recipe carries its own control template.
- **Refinements found by reading the wayland 1.23.1 source** (tighter than first assumed): it is
  already Darwin-aware except for the epoll dependency — `src/wayland-os.c` has a
  `struct xucred`/`LOCAL_PEERCRED` credentials branch, and `accept4`/`memfd_create`/
  `MSG_CMSG_CLOEXEC` are feature-detected with portable fallbacks. So **no C source patch is
  needed** — the only change is a one-line meson edit so epoll-shim is pulled on `darwin`
  (upstream limits it to `freebsd`/`openbsd`). The one real cross wrinkle, handled in
  `wayland.mk`: wayland needs a **version-matched native `wayland-scanner`** to codegen its own
  headers, so the recipe builds the scanner natively first, then cross-builds the libs against it.
- **Host build-deps the container must add:** `bison` (libxkbcommon keymap parser) and
  `libexpat1-dev` (native wayland-scanner pass).
- **Next action requires coordinator approval:** validate the recipes with a LIGHT container build
  (`epoll-shim` first, then `wayland`) on a distinct volume (e.g. `procursus-vol-wayland`).
  Message the coordinator before invoking Docker.

## Sources

- libwayland Darwin port (Bugaev): <https://mastodon.technology/@bugaevc/101603518023241841>
- Owl compositor: <https://github.com/owl-compositor/owl> · org: <https://github.com/owl-compositor>
- epoll-shim (kqueue; macOS port): <https://github.com/jiixyj/epoll-shim> ·
  MacPorts: <https://ports.macports.org/port/epoll-shim/details/>
- wlroots backends/seat requirements: <https://github.com/swaywm/wlroots>
- waypipe-darwin (SHM/socket on Darwin): <https://github.com/J-x-Z/waypipe-darwin>
- `os_create_anonymous_file` shm portability: <https://www.freshports.org/graphics/wayland>
