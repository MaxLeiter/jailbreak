# Xwayland on ANGLE-Metal (X11 apps inside the Wayland desktops)

Run X11-only Linux apps GPU-accelerated as clients of a Wayland compositor
(iosc now, Mutter/KWin later) on rootless iOS. Path:

```
X11 app --> Xwayland (glamor on ANGLE/GLES) --> IOSurface wl_buffer
        --> iosc_iosurface --> compositor (iosc/Mutter) GPU-composite --> Metal
```

This makes X11 apps work inside EVERY Wayland flavor, not just a legacy Xvnc
sidecar. See memory `xwayland-on-angle-feasibility`, and the north star
`x11-native-fast-priority`.

## Feasibility verdict (scoped 2026-06-30): FEASIBLE, no structural wall

Every hard primitive is already proven on-device by other tracks; the only real
new code is a glamor buffer backend, which has a direct upstream template.

## Version pin (LOAD-BEARING): xwayland 23.2.7

`xwayland <= 23.2` is the last series with the pluggable `struct xwl_egl_backend`
vtable. `24.1` "Dropped the EGLStream backend" and "Removed the xwl_egl_backend
structure" (24.0.99.901 announce), hard-wiring gbm/dma-buf. We add an IOSurface
backend through that vtable, so we MUST stay on 23.2. The `xwayland-glamor-
eglstream.c` file in this series is a complete worked example of a NON-dma-buf
backend to model against.

## Dependency delta vs the existing stack

Already cross-built (Procursus or our recipes): pixman 0.42, xorgproto, xtrans,
libxkbfile, libxfont2, libfontenc, font-util, libxkbcommon, wayland-client
1.23.1 (+epoll-shim), wayland-protocols 1.38, **libepoxy 1.5.7+angle1** (glamor's
GL loader, ALREADY repointed at `/var/jb/lib/angle` — the key leverage), the
**libdrm links-only shim** (glamor's meson requires `libdrm.pc` even though no
DRM path runs).

NEW: **`libxcvt`** (tiny pure-C VESA CVT lib; `recipes/libxcvt.mk`). That's the
whole delta. gbm/xshmfence/eglstream are all `required: false` meson lookups and
stay absent; DRI3 auto-disables without libdrm-real+xshmfence.

## ANGLE / glamor extension fit (low risk)

glamor uses plain `GL_TEXTURE_2D` sampling; it does NOT need
`GL_OES_EGL_image_external_essl3` (the extension that blocked GskGLRenderer).
The angle+es3 deb advertises everything glamor's init touches: surfaceless +
no-config context, `GL_OES_EGL_image`, `GL_EXT_texture_format_BGRA8888`,
`GL_EXT_map_buffer_range`, fence sync. glamor has an explicit `XWL_GLAMOR_GLES`
mode, and cogl-on-ANGLE already passed a stricter feature/GLSL detection
on-device (mutter-on-iosc.md UPDATE-f). Residual risk is runtime-only.

## The one patch: a glamor IOSurface backend

`recipes/build_info/xwayland-glamor-iosurface.c` (installed as
`hw/xwayland/xwayland-glamor-iosurface.c` by `recipes/xwayland-ios-fixes.sh`):

- `init_egl`: ANGLE-Metal EGLDisplay via `eglGetPlatformDisplayEXT(
  EGL_PLATFORM_ANGLE_ANGLE, ..., METAL)`; a bind-to-texture pbuffer EGLConfig;
  ES3-then-ES2 context; surfaceless MakeCurrent (1x1-pbuffer fallback). Exact
  shape proven in `x11/wayland/xios_egl.c`.
- pixmaps: each window/shared pixmap is a BGRA `IOSurface` (fully specified,
  aligned BytesPerRow/AllocSize) wrapped as an ANGLE pbuffer
  (`EGL_IOSURFACE_ANGLE`, `EGL_TEXTURE_2D`) and bound to the glamor texture with
  `eglBindTexImage` — glamor renders straight into the IOSurface. Proven by
  iosc M2/M3 + `iosc-fbtest`.
- `get_wl_buffer_for_pixmap`: `IOSurfaceCreateMachPort()` then
  `iosc_iosurface.create_buffer(port, w, h, BGRA)` — the compositor extracts the
  send right from our task by the wl socket peer pid (same rendezvous iosc
  already runs, reversed). Protocol: `x11/wayland/iosc-iosurface.xml`.
- `post_damage`: `glFinish()` before commit (ANGLE-Metal command-buffer
  completion ordering). TODO(perf): `EGL_KHR_fence_sync` /
  `EGL_ANGLE_metal_shared_event_sync` instead of a full finish.
- `backend_flags = NEEDS_N_BUFFERING`: the core multi-buffers window pixmaps and
  rotates on `wl_buffer.release`, so we never render into a buffer the
  compositor is sampling.

Wired into the vtable by `recipes/xwayland-ios-fixes.sh` (idempotent Python):
adds `iosurface_backend` to `struct xwl_screen`; hooks `xwl_glamor_init_backends`
/ `select_backend` / `init_wl_registry`; defines `XWL_HAS_IOSURFACE` and makes
`XWL_HAS_GLAMOR` true for a gbm-less/eglstream-less build; adds the source +
`iosc-iosurface.xml` codegen + IOSurface/CoreFoundation framework link args in
`hw/xwayland/meson.build`; and re-ports the rootless popen fix
(`/bin/sh` -> `/var/jb/bin/sh` in `os/utils.c`, same as the tigervnc build).

## Rootful first (rootless needs an XWM)

Rootless Xwayland requires the compositor to be an X window manager. iosc has no
XWM -> run **rootful** first (whole X screen as one `xdg_toplevel`; an in-server
X wm like fluxbox manages windows inside it). Works under ANY compositor. Mutter
has a built-in XWM for real rootless later, but Mutter is currently built
X11/xwayland-OFF (libxcb dyld failures, see `x11-distribution-chooser`) -> that
flag + the libxcb closure must be flipped for Mutter-hosted rootless. Off the
critical path.

## GLX (honest)

`xwayland-glx.c` (EGL-backed GLX provider) is built, but direct-rendering
desktop-GL apps need a client-side Mesa DRI + dma-buf, absent on iOS -> GLX/GL
apps keep using llvmpipe swrast over SHM (status quo under Xvnc, no regression).
glamor accelerates the 2D X path (XRender/copies) = most X11-only apps. Future
exploratory: a gl4es-style client GL->GLES-on-ANGLE shim.

## Build

`build-xwayland.sh` (Docker, on a volume that already has the wayland stack +
libepoxy+angle). Two flavors from one recipe:

- **X0** (`XWAYLAND_GLAMOR=false`): pure `wl_shm` software, no glamor/libdrm/
  epoxy needed. First-light + bisect aid. Immediate win: hitori and every
  X11-only app become usable inside the Wayland desktop (our libgtk-3 is
  x11-backend-only, so today they can't run under iosc at all).
- **X1** (default): glamor on ANGLE, GPU-accelerated pixmaps. First real
  GPU-composited X app through iosc.

Produces `xwayland`, `libxcvt0`, `libxcvt-dev` debs. Xwayland is signed with the
GPU entitlement set (`xwayland-ent.xml`: AGX/IOGPU/IOSurface IOKit +
get-task-allow, NOT no-container).

## Effort / risk

X0 ~1-2 days, X1 ~3-5 days. No structural blocker. Ranked runtime risks:
(a) glamor feature detection on ANGLE-Metal (device run settles it; cogl
precedent good), (b) buffer-release/sync under damage-heavy loads, (c) GLX stays
software (accepted).

## Files

- `linux-build/recipes/xwayland.mk` — recipe (23.2.7, glamor toggle).
- `linux-build/recipes/libxcvt.mk` — the one new dep.
- `linux-build/recipes/xwayland-ios-fixes.sh` — idempotent source patcher.
- `linux-build/recipes/build_info/xwayland-glamor-iosurface.c` — the backend.
- `linux-build/recipes/build_info/{xwayland,libxcvt0,libxcvt-dev}.control`,
  `xwayland-ent.xml`, `iosc-iosurface.xml` (vendored from `x11/wayland/`).
- `linux-build/build-xwayland.sh` — build driver.
