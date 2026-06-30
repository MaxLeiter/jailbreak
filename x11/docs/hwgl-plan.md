# Hardware-accelerated GL on iOS — plan

Research deliverable for the "real GL driver" ask. Today the stack is **software GL only**
(Mesa `llvmpipe`/`swrast`, already built); the only thing touching the GPU is the Xios
compositor (Metal). This file evaluates the realistic ways to get **hardware GL** and
recommends a path.

**Device reality:** iPad7,12 (A10), iPadOS 17.6.1, palera1n rootless `/var/jb`, Procursus.
Apple GPU, **Metal/AGX only** — no Vulkan, no DRM/KMS, no DRI. See [[x11-on-ios-project]].

---

## Phase A result — VERIFIED ON-DEVICE (2026-06-29)

Hardware GLES on the iPad is **proven** from an entitled command-line process:

- **AGX-from-CLI works** (`metalprobe`, first-party C/Metal). An ldid-signed CLI process with
  the Xios entitlement set got a real `MTLDevice` ("Apple A10 GPU"), created an IOSurface, ran
  a GPU render pass into it, and read back the exact color. The biggest unknown — whether a
  non-app jailbroken process can touch the GPU — is **retired**. Entitlements are per-process;
  on a jailbreak we ldid-sign them ourselves, exactly like Xios.
- **Hardware GLES via ANGLE/Metal works** (`angleprobe`, first-party, linking a prebuilt
  MetalANGLE for the throwaway test). Same entitled CLI process →
  `GL_RENDERER = ANGLE (Metal Renderer: Apple A10 GPU)`, `OpenGL ES 2.0.0 (ANGLE 2.1.0)` →
  drew a Gouraud triangle, `glGetError = 0` → wrote a PNG on-device (ImageIO). Visually
  confirmed correct (a red-apex / green-blue-base interpolated triangle).
- **Zero-copy GLES → IOSurface works** (`angleprobe3`) — the literal win condition. GLES
  rendered a triangle **directly into an IOSurface**, no CPU copy: IOSurface → `MTLTexture` on
  *ANGLE's own* `MTLDevice` (queried via `EGL_EXT_device_query` + `EGL_ANGLE_device_mtl`) →
  `eglCreateImageKHR(EGL_MTL_TEXTURE_MGL)` → GL texture (`glEGLImageTargetTexture2DOES`) → FBO
  color attachment → draw. CPU readback of the IOSurface: center = the triangle's centroid
  blend, corner = the clear color → the GPU output landed in the shared surface. PNG confirmed
  visually. This is exactly the Stage 2 DDX interop (an IOSurface-backed Metal texture shared
  with GL).

**Note for Phase B (zero-copy is no longer a blocker):** the *prebuilt MetalANGLE 0.0.8 fork*
reaches zero-copy via `EGL_MGL_mtl_texture_client_buffer` + `eglCreateImageKHR` (proven
above), but lacks the newer one-call `EGL_ANGLE_iosurface_client_buffer` (which takes an
IOSurface directly, skipping the manual `MTLTexture` step). Upstream **google/angle** exposes
that cleaner, IOSurface-native path (it is what WebKit uses on iOS), so Phase B still builds
upstream from source — but as a quality/ergonomics upgrade, not to unlock a missing
capability.

Net: the whole chain (signing → AGX → ANGLE → GLES → **IOSurface zero-copy** → on-device
image) is **proven on-device**. Proceed to Phase B (build upstream ANGLE from source, package
the deb) on the coordinator's go.

---

## TL;DR / recommendation

**Ship hardware GL as GLES via ANGLE's Metal backend** (`libEGL` + `libGLESv2` translating
GLES→Metal/AGX). It is the only mature, shipping option on this hardware — Apple itself
ships the ANGLE Metal backend inside WebKit for WebGL/WebGL2 on iOS devices. It is *additive*:
Mesa/llvmpipe stays as the fallback for everything ANGLE can't serve.

**What it unlocks:** GPU rendering for **EGL+GLES** consumers — the Xios compositor itself,
a future Wayland compositor (Stage 4), GLES-native apps/toolkits (SDL2-GLES, Qt EGLFS, mpv,
emulators), and **GTK4's GL renderer**. The killer fit: ANGLE's
`EGL_ANGLE_iosurface_client_buffer` lets GLES render **straight into an IOSurface**, which is
exactly the zero-copy primitive the Stage 2 IOSurface DDX is already built around.

**What it can NOT do:** accelerate **legacy GLX / desktop-OpenGL** X clients (`glxgears`,
classic fixed-function GL apps). Those need DRI direct rendering (no DRM on iOS) or fall back
to indirect GLX = software. ANGLE is GLES/EGL, not GLX/desktop-GL. **Legacy GLX apps stay on
llvmpipe** — which already works and is fine for light use.

**Cost/risk:** ANGLE builds with its *own* toolchain (depot_tools + GN + ninja, on **macOS +
Xcode** for the Metal shader compiler) — **separate from our Procursus/Debian-Docker
`linux-build/` pipeline**. De-risk first with a prebuilt/fork build + a tiny EGL triangle
test before committing to the upstream GN build. **No heavy build started — awaiting your go.**

---

## The options (a/b/c), evaluated

### (a) ANGLE → Metal — RECOMMENDED
Google's ANGLE is a conformant GLES implementation with a **Metal backend**. Status on this
hardware:

- **Mature and shipping on iOS devices.** The Metal backend is the same code on macOS & iOS,
  and Apple ships it in WebKit as the engine behind **WebGL/WebGL2 on iOS Safari** — i.e. it
  drives the A-series GPU on real devices in production, not just the simulator.
- **GLES coverage:** ES 2.0 is complete/conformant; ES 3.0 on Metal is effectively done (it
  is what WebGL2 requires) with only edge-case gaps. ES 1.x via `libGLESv1CM`.
- **Outputs:** `libEGL.dylib` + `libGLESv2.dylib` (+ `libGLESv1CM.dylib`) — standard EGL 1.4/1.5
  + GLES. This is exactly the ABI the Linux/mobile GL ecosystem links against.
- **IOSurface interop (decisive):** `EGL_ANGLE_iosurface_client_buffer` binds an EGL pbuffer
  to an **IOSurface** and presents via `CALayer`; `EGL_ANGLE_metal_texture_client_buffer`
  imports native `MTLTexture`. So ANGLE plugs directly into the IOSurface/CAMetalLayer
  plumbing Xios already uses.
- **Prior art for the device build:** `kakashidinho/metalangle` (the original Metal backend,
  now upstreamed) and prebuilt arm64 device binaries (`nutiteq/angle-metal`) prove the
  arm64-device build and give us a de-risking shortcut.

### (b) Mesa + a custom Metal/IOSurface backend — REJECTED
No upstream Metal backend exists in Mesa. `zink` is GL→**Vulkan**, and there is **no Vulkan
on iOS** (MoltenVK is Vulkan→Metal, but layering Mesa→zink→Vulkan→MoltenVK→Metal is absurd and
unproven on iOS). Writing a native Mesa Gallium driver for AGX from scratch (cf. Asahi's
`agx` driver, which targets Linux/DRM, not iOS userspace Metal) is a multi-person-year effort.
Not viable.

### (c) Custom GLES→Metal — REJECTED
This is reinventing ANGLE. ANGLE is the conformant, Apple-co-maintained version of exactly
this. No reason to build it ourselves.

### (also considered) System `OpenGLES.framework` (EAGL) — fallback only
iOS *already* ships hardware GLES (`OpenGLES.framework`) running on the A10 GPU. But it is
**EAGL-bound** (contexts tied to `CAEAGLLayer`/renderbuffers), **deprecated since iOS 12**,
GLES-only, and exposes **no EGL** — so it doesn't drop into a Linux EGL-expecting stack
without a custom EGL-over-EAGL shim. ANGLE gives standard EGL + IOSurface interop + active
maintenance, so ANGLE wins. Keep EAGL in mind only as a contingency if ANGLE ever can't be
built.

---

## The critical gap: GLES is achievable, desktop GL (GLX) is not

This is the single most important thing to be clear-eyed about.

| Path | What uses it | On iOS |
|---|---|---|
| **GLES + EGL** | Wayland, GTK4 GL renderer, modern toolkits, GLES apps, WebGL | **achievable via ANGLE→Metal** |
| **Desktop GL via GLX** | legacy X11 OpenGL apps (`glxgears`, classic CAD/games) | **hardware = no** (needs DRI; none on iOS) → software/llvmpipe only |

Why GLX hardware acceleration is effectively dead on this device:
- Hardware GLX needs **DRI direct rendering** — the client mmaps the GPU via DRM. iOS has no
  DRM/DRI; GPU access is exclusively Metal/IOKit (AGX).
- The X server's **indirect GLX** path exists but renders in the server with **software**
  (this is our current llvmpipe situation).
- The whole Linux graphics world is migrating **GLX → EGL** anyway (Firefox, GTK, Wayland).
  ANGLE rides that migration: it serves the EGL side and leaves GLX to software.

A `libGLX`-on-EGL shim that translates desktop GL → GLES is theoretically possible but is a
large translation problem (different shading language, fixed-function pipeline, compat
profiles). **Not recommended** — the payoff (a handful of legacy apps) doesn't justify it,
and they already run on llvmpipe.

---

## What this unlocks for our stack (consumers, ranked by realism)

1. **The Xios compositor itself — best first real consumer.** It already owns an `MTLDevice`
   and the GPU entitlement (Stage 1). Today it hand-blits the framebuffer/IOSurface to a
   `CAMetalLayer`. With ANGLE it gets a portable **GLES context bound to the same IOSurface**
   (`EGL_ANGLE_iosurface_client_buffer`) for GPU compositing of per-window IOSurfaces
   (Stage 3) — and the EGL path is reusable off-iOS. Lowest-risk, highest-leverage.

2. **A future Wayland compositor (Stage 4 "the iOS compositor *is* the desktop").** ANGLE
   gives the compositor its GLES/EGL context; Wayland clients hand it
   dmabuf/IOSurface-backed buffers. This is the strategic fit with the Wayland + hardware-GL
   research track. Needs an EGL platform binding (surfaceless / a custom Wayland-EGL platform
   over IOSurface) — medium effort, but this is *the* reason hardware GLES matters long-term.

3. **GLES-native apps & toolkits** linking EGL+GLES directly — SDL2 (GLES), Qt (EGLFS/GLES),
   mpv (gpu/GLES), emulators/RetroArch, `kmscube`-style demos. Direct win once
   `libEGL`/`libGLESv2` are installed and the app binary is entitled (see below).

4. **GTK4 GL renderer** — GTK4 speaks **EGL** and can render with **GLES**. Big visual win,
   **but a caveat for the lead:** the in-flight toolkit build is **GTK3**, whose main path is
   cairo/**CPU**; GTK3 only touches GL inside `GtkGLArea`, so hardware GL barely moves the
   needle for GTK3 broadly. If "hardware-accelerated GTK desktop" is a goal, the target is
   **GTK4** (note: GTK 4.16 defaults to the **Vulkan** GSK renderer, unavailable here — must
   force `GSK_RENDERER=gl`/`ngl` + GLES via ANGLE). Worth a decision: GTK3 gets little from
   this; GTK4 gets a lot.

5. **Mutter / Clutter on GLES** — possible in principle (Cogl supports GLES), but Mutter wants
   KMS/logind/DRM for its native backend; only a *nested* Mutter (Wayland/X backend) on
   surfaceless EGL could use ANGLE. Deep — keep as research (ties to the Mutter feasibility
   track).

---

## Entitlement / IOSurface plumbing (already 90% solved)

The hard part — getting a fakesigned process onto the GPU — is **already solved for Xios** and
generalizes:

- **GPU command submission needs `AGXDeviceUserClient`** via
  `com.apple.security.iokit-user-client-class`. Without it `MTLCreateSystemDefaultDevice()`
  returns nil. We already grant this to Xios.
- **`IOSurfaceRootUserClient` has no sandbox/entitlement block** (no permission check on the
  IOSurface user client), but we list it anyway to match Xios and for `task_for_pid`/buffer
  sharing.
- **Entitlements are per-*process* (the executable), not per-library.** ANGLE's
  `libEGL.dylib`/`libGLESv2.dylib` just need a valid (ad-hoc/ldid) signature to *load*; the
  GPU entitlement lives on whatever process dlopens them:
  - **Xios app:** already entitled → loads ANGLE and hits the GPU immediately. ✓
  - **Standalone client binaries** (a GLES demo, an SDL2/GTK4 app): each must be
    **ldid-signed with the GPU entitlements**. On a jailbreak **we control signing** (we
    already re-sign Xios with the Mac's `ldid` for DER entitlements), so this is *packaging*,
    not a blocker — but it does mean every GPU-using client binary must be entitled (a real
    per-binary step that App-Store distribution could never do). Jailbreak CLI/daemon
    processes run **outside the App-Store container sandbox**, so an entitled + signed binary
    reaches the GPU.
- **Install path:** Mesa already provides `libEGL`/`libGLESv2` in Procursus. Install ANGLE
  under a **private prefix** (e.g. `/var/jb/lib/angle/`) to avoid SONAME collision; consumers
  select it via `DYLD_LIBRARY_PATH`/rpath/explicit `dlopen` (or a libglvnd vendor JSON),
  leaving Mesa as the default `libGL`/llvmpipe for GLX. **Both coexist.**

The buffer-sharing path also already exists: Stage 2's IOSurface-over-mach-port rendezvous
(server `IOSurfaceCreateMachPort()` → app `IOSurfaceLookupFromMachPort()`) is exactly what
feeds an ANGLE `EGL_ANGLE_iosurface_client_buffer` surface.

---

## Build feasibility & first build plan

**Key practical fact:** ANGLE does **not** build like the rest of our stack. It uses
**depot_tools + GN + ninja**, and the iOS/Metal build needs **macOS + Xcode** (for the `metal`
/ `metallib` shader compiler and Apple SDKs). It is independent of `linux-build/` and of
Procursus — so the "macOS 26/Xcode 26 too new for Procursus" problem does **not** apply
(ANGLE tracks current Xcode; the Mac already builds Xios). Official `DevSetup.md` documents
the *simulator* build well; the *arm64-device* GN path is less documented (routes through a
Chromium-iOS-style checkout), which is the main build risk — hence de-risk first.

### Phase A — de-risk — **DONE & VERIFIED (2026-06-29)**
See the "Phase A result" banner at the top: AGX-from-CLI, hardware GLES on the A10, and
zero-copy GLES→IOSurface are all proven on-device with first-party probes. The entire hardware
path (signing → AGX → ANGLE → GLES → IOSurface → PNG) is de-risked. Probes live in
`scratchpad/hwgl/` (`metalprobe.m`, `angleprobe.m`, `angleprobe3.m`, `ents.plist`).

### Phase B — upstream ANGLE GN build + packaging — **DONE & VERIFIED ON-DEVICE (2026-06-30)**

Built upstream `google/angle` (commit `a32d31d2f1`, "ANGLE 2.1.28223") for arm64 iOS device,
Metal backend only, packaged as an **`angle` deb**, installed clean, and validated the
**one-call** IOSurface path on the A10 GPU. Deliverables:

- **Deb:** `x11/linux-build/out/angle_2.1.0+git20260630.a32d31d_iphoneos-arm64.deb` (3.9 MB,
  self-contained, zstd). Payload `/var/jb/lib/angle/{libEGL,libGLESv2}.dylib` + headers under
  `/var/jb/include/{EGL,GLES,GLES2,GLES3,KHR,platform}`. Does **not** collide with Mesa's libEGL.
- **On-device probe (`scratchpad/hwgl/angleprobe4.m`) → PASS:** `EGL 1.5`,
  `EGL_ANGLE_iosurface_client_buffer` **advertised**, `GL_RENDERER = ANGLE (Apple, ANGLE Metal
  Renderer: Apple A10 GPU)`, rendered a Gouraud triangle into an IOSurface via the **single**
  `eglCreatePbufferFromClientBuffer(EGL_IOSURFACE_ANGLE)` call (FBO complete, `glGetError=0`,
  centroid color landed in the shared surface) → `angle_iosurface_b_phaseB.png`.

**Two gotchas hit & fixed (reproducibility — scripts in `scratchpad/hwgl/`):**
1. `gn gen` aborts with `assert(!(current_os=="ios" && is_component_build))`. **iOS forbids
   component build** → use `is_component_build=false`. (This was the only real blocker.)
2. On iOS, ANGLE's `angle_shared_library` emits **`.framework` bundles**, not bare dylibs, and
   libEGL's `egl*` are lazy trampolines that `dlopen(ANGLE_DISPATCH_LIBRARY)` from the app-bundle
   `<exe>/Frameworks/libGLESv2.framework/libGLESv2` — wrong for Procursus CLI consumers (epoxy/
   GTK4 expect Mesa-style `libEGL.dylib`/`libGLESv2.dylib`). Fixed with a small **3-edit patch**
   (`scratchpad/hwgl/angle-procursus-dispatch.patch`): dispatch to `libGLESv2.dylib`, resolve it
   from `/var/jb/lib/angle/` (override via `ANGLE_FRAMEWORK_PATH`), and let a verbatim `.dylib`
   name skip the `.framework` mangling. Then extract the framework binaries → `.dylib`,
   `install_name_tool -id /var/jb/lib/angle/…`, `ldid -S`, package.

The library carries no entitlements; the **GPU-using process** must be ldid-signed with the
AGX/IOSurface IOKit entitlements (`scratchpad/hwgl/ents.plist`), same as Xios.

Build state lives at `/private/tmp/angle-ios-build` (13 GB checkout + 23 GB free headroom kept by
a 3 GB disk watchdog). **Next: Phase C** — wire the Xios compositor / GTK4 epoxy onto this deb.

#### Original turnkey runbook (for a clean rebuild)
macOS + Xcode, depot_tools/gn/ninja (no `linux-build/` Docker contention):

```sh
# 1. depot_tools
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$PWD/depot_tools:$PATH"

# 2. fetch ANGLE (shallow)
mkdir angle && cd angle
git clone https://chromium.googlesource.com/angle/angle .
python3 scripts/bootstrap.py && gclient sync -D --no-history

# 3. configure: arm64 iOS device, Metal only (drop unused backends to cut build time/deps)
gn gen out/ios-arm64 --args='
  target_os="ios" target_environment="device" target_cpu="arm64"
  ios_deployment_target="15.0" ios_enable_code_signing=false
  is_debug=false is_component_build=false   # iOS forbids component build
  angle_enable_metal=true
  angle_enable_vulkan=false angle_enable_gl=false angle_enable_d3d11=false angle_enable_null=false
  angle_enable_essl=true angle_enable_glsl=true'

# 4. build the two libs (autoninja = ninja + reclient autodetect)
autoninja -C out/ios-arm64 libEGL libGLESv2
```

- **Outputs:** `out/ios-arm64/libEGL.dylib` + `libGLESv2.dylib` (component build → real dylibs).
  *Known unknown:* if the iOS component build doesn't emit standalone dylibs, fall back to
  `is_component_build=false` + the `*_static` targets wrapped into a thin dylib, or build the
  `angle_libGLESv2`/`angle_libEGL` shared targets directly.
- **Sign + relink:** `install_name_tool -id /var/jb/lib/angle/libEGL.dylib libEGL.dylib`
  (same for GLESv2; fix the inter-lib `@rpath` ref too), then `ldid -S` each (Mac ldid, for a
  valid signature — libraries need no entitlements; the *process* carries them).
- **Package** a Procursus-style **`angle` deb**: payload `/var/jb/lib/angle/{libEGL,libGLESv2}.dylib`
  + headers `/var/jb/include/{EGL,GLES2,GLES3,KHR}/`. `Architecture: iphoneos-arm64`,
  `Package: angle`, self-contained (no Procursus dep). Lives **outside** `linux-build/`
  (do not entangle with `procursus-vol`).
- **Validate on device:** rebuild an `angleprobe`-style test against the deb's dylibs; confirm
  `EGL_EXTENSIONS` now advertises **`EGL_ANGLE_iosurface_client_buffer`**, then render a
  triangle into an IOSurface via the **one-call** path
  (`eglCreatePbufferFromClientBuffer(EGL_IOSURFACE_ANGLE, …)`) — the cleaner upstream route the
  fork lacked.

### Phase C — first-consumer smoke test (GTK4) — **DONE, NEGATIVE FOR X11 (2026-06-30)**

Ran the GTK4-on-ANGLE smoke test the obvious way (the installed GTK4 4.14.5 `hello-gtk4` on the
Xvfb `:3` scratch display, `GSK_RENDERER=gl GDK_BACKEND=x11 DYLD_LIBRARY_PATH=/var/jb/lib/angle
GDK_DEBUG=opengl`). **Result: GTK4's X11 backend does not — and structurally cannot — use ANGLE.**
ANGLE is never consulted; GDK goes to GLX, gets an **indirect (software)** context from the X
server's Mesa swrast, then **fatally `dlopen`s the absent `/System/Library/Frameworks/OpenGL.framework`**
→ with `GSK_RENDERER=gl` forced it `SIGABRT`s (rc 134); unforced it silently falls back to cairo
(the current state). Three independent root causes:

1. **Windowing-platform mismatch (the real wall).** GDK-X11's EGL path needs `EGL_EXT_platform_x11`.
   ANGLE advertises `EGL_ANGLE_platform_angle`, `EGL_EXT_platform_device`, **`EGL_EXT_platform_wayland`**,
   `EGL_KHR_platform_gbm` — but **not `_x11`** — and its window surfaces require a **`CAMetalLayer`**,
   not an X11 `Window`. So even with EGL reachable, `eglGetPlatformDisplay(EGL_PLATFORM_X11)` fails →
   GDK falls back to GLX.
2. **epoxy is mis-wired for this platform.** It `dlopen`s EGL from the **absolute** path
   `/var/jb/usr/lib/libEGL.1.dylib` (absent — so `DYLD_LIBRARY_PATH` can't redirect it to ANGLE),
   desktop GL from `OpenGL.framework` (absent), GLES from `libGLESv2.so` (a Linux soname). None point
   at `/var/jb/lib/angle`.
3. GDK prefers/falls to **GLX**, which here is software + routes GL through the absent `OpenGL.framework`.

**Decisive confirmation (gave ANGLE its best shot):** symlinked ANGLE to the exact paths epoxy/GDK
use (`/var/jb/usr/lib/libEGL.1.dylib`, `libGLESv2.so`) **and** forced the EGL backend
(`GDK_DEBUG=gl-egl`). GDK then *did* load ANGLE (`Using OpenGL backend EGL`) — but:
`Failed to realize 'GskGLRenderer' for surface 'GdkX11Toplevel': **No EGL configuration with
required features found**` → fell back to `GskCairoRenderer`. So ANGLE's libEGL loads fine; the
real wall is that ANGLE exposes **no EGL config that can back an X11 window surface** (its configs
are Metal/IOSurface/`CAMetalLayer`). The EGL *layer* is not the blocker — the X11 *windowing
config* is. (System symlinks reverted immediately after.) This is the airtight proof that the X11
path is a dead end and the answer must be Wayland or the compositor.

**The real GTK4-on-GPU path (do NOT keep pushing X11):**
- **Wayland backend** — ANGLE's supported windowing platform is **Wayland** (`EGL_EXT_platform_wayland`),
  not X11. `GDK_BACKEND=wayland` on the **W0 Wayland compositor** (now built) + ANGLE EGL is the match.
- **epoxy fix — DONE (2026-06-30), building block landed.** `recipes/libepoxy.mk` now repoints
  epoxy's `EGL_LIB`→`/var/jb/lib/angle/libEGL.dylib` and `GLES2_LIB`→`/var/jb/lib/angle/libGLESv2.dylib`
  (Apple block; `GLX_LIB`/`OPENGL_LIB` left on mesa/`OpenGL.framework` for the X11 software path).
  Built as **`libepoxy0_1.5.7+angle1`** (`linux-build/out/`). **Verified on-device:** with the new
  epoxy installed, GTK4 forcing EGL prints `Using OpenGL backend EGL` and reaches ANGLE with **no
  symlink and no `DYLD_LIBRARY_PATH`** — epoxy resolves ANGLE on its own. (It still hits the X11
  `GdkX11Toplevel` config wall above → cairo; that is the windowing layer, not epoxy.) The dlopens
  are soft, so epoxy still works if the `angle` deb is absent (graceful fallback) — no hard dep.
- **OR (independent of GTK) wire the Xios compositor onto ANGLE** (consumer #1 below): the compositor
  is already entitled + IOSurface-based, so it can composite GTK windows on the GPU via
  `EGL_ANGLE_iosurface_client_buffer` regardless of GTK's own (cairo) drawing.

Probes/scripts: `scratchpad/hwgl/run-gtk-angle.sh` (+ `run.log` evidence on device, since cleaned).

### Phase C-real / D — first real consumer (recommended next)
- Wire the **Xios compositor** to render via ANGLE EGL + `EGL_ANGLE_iosurface_client_buffer`
  on the existing per-window IOSurfaces (folds into Stage 2/3). Validates the IOSurface
  interop on real workload — and is the lowest-risk way to put the A10 GPU under the desktop.
- In parallel, the **GTK4-on-Wayland-on-ANGLE** path above (needs W0 + the epoxy fix).

### Phase D — broaden
- A `kmscube`-style surfaceless GLES demo → an entitled GLES app (mpv/SDL2) → then evaluate
  the Wayland-compositor + GTK4 paths.

---

## Open questions for the coordinator

1. **GTK3 vs GTK4:** hardware GL barely helps the GTK3 build that's in flight; the real GPU
   payoff is GTK4 (forced GL renderer + GLES). Is GTK4 in scope, or is GTK3 fixed?
2. **Per-binary entitlement policy:** are we comfortable ldid-signing every GPU-using client
   binary with the AGX entitlement (fine on a jailbreak), or do we want GPU rendering
   centralized in the entitled compositor only?
3. **Scope of "real driver":** is the goal "GPU for the compositor + select GLES apps"
   (clean, near-term) or "GPU for arbitrary X clients" (the latter largely needs the Wayland
   pivot, since GLX-over-Metal isn't happening)?

---

## Sources

- [google/angle](https://github.com/google/angle) · [ANGLE DevSetup](https://chromium.googlesource.com/angle/angle/+/HEAD/doc/DevSetup.md) · [iOS Metal ETA / status thread](https://groups.google.com/g/angleproject/c/11wLJvlYefQ)
- [kakashidinho/metalangle](https://github.com/kakashidinho/metalangle) · [nutiteq/angle-metal (prebuilt iOS arm64)](https://github.com/nutiteq/angle-metal)
- [EGL_ANGLE_iosurface_client_buffer](https://chromium.googlesource.com/angle/angle/+/master/extensions/EGL_ANGLE_iosurface_client_buffer.txt) · [ANGLE extensions](https://github.com/google/angle/tree/main/extensions)
- [GLX (Wikipedia)](https://en.wikipedia.org/wiki/GLX) · [Direct Rendering Infrastructure](https://en.wikipedia.org/wiki/Direct_Rendering_Infrastructure) · [Switching the Linux graphics stack from GLX to EGL (Mozilla)](https://mozillagfx.wordpress.com/2021/10/30/switching-the-linux-graphics-stack-from-glx-to-egl/)
- [GTK "Adventures in graphics APIs" (EGL/GLES)](https://blog.gtk.org/2021/05/10/adventures-in-graphics-apis/) · [GTK 4.16 Vulkan GSK default (Phoronix)](https://www.phoronix.com/news/GTK-4.16-Released)
- [Reading iOS Sandbox Profiles (8kSec)](https://8ksec.io/reading-ios-sandbox-profiles/) — IOSurface user client / platform sandbox
