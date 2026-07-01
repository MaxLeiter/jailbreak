# Shared iOS/GPU glue lib — the cut lines (design for iosc-input)

Status: **design only.** Hands the cut lines to `iosc-input` (the iosc maintainer) to route once
`iosc.c` settles. Do NOT start the iosc-side refactor here — `iosc.c` is a live file. Grounded in
the actual sources read 2026-06-30: `x11/wayland/iosc_gl.{c,h}`, `x11/wayland/iosc_input.{c,h}`,
`x11/linux-build/patches/xios/xios_surface.{c,h}`, `x11/wayland/iosc-iosurface.xml`, and mutter
46's cogl winsys (`cogl/cogl/winsys/cogl-winsys-egl{,-x11}.c`). Companion to
[`mutter-on-iosc.md`](mutter-on-iosc.md).

## Why a shared lib

We are keeping **iosc** (our own compositor) AND adding **gnome-shell** (Mutter with a new
`MetaBackendIOS`) as a switchable option. Both need the same hard-won iOS glue: get an IOSurface to
the Xios app, render into it with ANGLE-Metal, import client IOSurfaces, pump input back. Today that
glue is entangled with iosc's compositor. Factor it into `libxios_glue` so both link it and neither
forks it.

## The single most important refinement: split `iosc_gl.c`

`iosc_gl.c` does **two** jobs that must be separated, because Mutter does the second one itself:

1. **EGL/ANGLE-Metal + IOSurface plumbing** (SHARED) — `eglGetPlatformDisplay(ANGLE,…,METAL)`,
   config choice (`EGL_PBUFFER_BIT` + RGBA8 + `EGL_BIND_TO_TEXTURE_RGBA`), context create,
   `create_iosurface_pbuffer` (`eglCreatePbufferFromClientBuffer(EGL_IOSURFACE_ANGLE)`),
   `bind_pbuffer_texture` (`eglBindTexImage`), the FBO-0-into-IOSurface setup, and the
   client-IOSurface→texture import. This is the `iosc_gl_init` body + `create_iosurface_pbuffer` +
   `bind_pbuffer_texture` + `make_iosurface_tex_wh`. **MetaRendererIOS's Cogl winsys needs exactly
   this and nothing else.**

2. **Compositing** (iosc-ONLY) — the shaders, `draw_quad`, `iosc_gl_draw_iosurface`,
   `iosc_gl_draw_shm`, the BGRA-swizzle fragment shader, the placement/flip_v conventions, the
   texture cache. **Mutter composites with Cogl/Clutter instead — it must NOT pull this in.**

Proposed split:
- `xios_egl.{c,h}` (SHARED): job 1. A tiny surface API — see below.
- `iosc_gl.c` (iosc-only, unchanged API `iosc_gl.h`): job 2, reimplemented on top of `xios_egl`
  (it calls `xios_egl_*` for display/context/pbuffer, keeps its own shaders + draw loop).

This is the make-or-break seam for the Cogl de-risk: `MetaRendererIOS` supplies a Cogl
**custom winsys** (`cogl_renderer_set_custom_winsys`, the same hook mutter's native renderer uses)
whose `platform_vtable` calls `xios_egl_get_display()` / `xios_egl_create_onscreen(iosurface)` —
i.e. job 1 — and lets Cogl own job 2.

## What goes in `libxios_glue`

| file | API (already the boundary) | iosc uses | MetaBackendIOS uses |
|---|---|---|---|
| `xios_surface.{c,h}` (from `linux-build/patches/xios/`) | `xios_surface_create`, `xios_server_start`, `xios_notify_dirty`, `xios_get_output_iosurface`, `xios_import_client_iosurface`, `xios_release_client_iosurface`, `xios_read_output_pixel` | output alloc + present + client import, verbatim | the backend's monitor/present (`xios_get_output_iosurface` → the CoglOnscreen target; `xios_notify_dirty` → swap), and the `MetaWaylandBuffer` IOSurface import |
| `xios_egl.{c,h}` (NEW, split from `iosc_gl.c` job 1) | `xios_egl_get_display()`, `xios_egl_choose_config()`, `xios_egl_create_pbuffer(iosurface,w,h)`, `xios_egl_bind_texture(pb)` | via `iosc_gl.c` | via the Cogl custom-winsys `platform_vtable` |
| `iosc_input.{c,h}` | `iosc_input_init`, `iosc_input_keymap_string/size`, `iosc_input_lookup`, `iosc_input_mod_*` | wl_keyboard keymap + keysym→evdev | the Clutter seat keymap + `ClutterVirtualInputDevice` key events |
| the input **socket** reader (24-byte pointer/key msgs; today in iosc + `ios-inputd.c`) | a small `xios_input_socket_*` open/poll/read API | feeds iosc's `wl_seat` | feeds a `ClutterVirtualInputDevice` |
| `iosc-iosurface.xml` + the import path | the `iosc_iosurface` client-buffer protocol (mach_port_name → IOSurface) | iosc serves it directly | Mutter wraps the imported IOSurface as a new `MetaWaylandBuffer` type (via `EGL_ANGLE_iosurface_client_buffer`, NOT `eglCreateImage`) |

## What stays in `iosc.c` (NOT shared)

Everything that makes iosc *a compositor*: its hand-rolled `wl_compositor` / `xdg_wm_base` /
`wl_seat` / `viewporter` / `fractional-scale` / `presentation` / `subcompositor` /
`wl_data_device`, the surface/stacking/damage bookkeeping, and the iosc-only GPU compositing (job
2 above). Mutter's `src/wayland/` replaces all of this for the gnome-shell path; iosc keeps it for
the iosc path. Both link `libxios_glue` underneath.

## Build / packaging

- New static (or dylib) `libxios_glue` built from `xios_surface.c` + `xios_egl.c` +
  `iosc_input.c` + the input-socket reader, with headers in one place.
- `iosc` links it (drops the now-moved .c files from its own build).
- `MetaBackendIOS` (mutter-side, built in the mutter tree because the Cogl winsys needs cogl's
  **private** winsys headers — they are NOT in `libmutter-14-dev`) links it too. The cogl custom
  winsys is mutter-internal; it consumes `libxios_glue` for the iOS primitives only.
- Frameworks: `-framework IOSurface -framework CoreFoundation -framework Foundation`, ANGLE
  `libEGL`/`libGLESv2` (`/var/jb/lib/angle`), `-framework IOKit/Metal` as ANGLE pulls them.

## Risks / notes for iosc-input

- The split must preserve iosc's proven placement/flip_v conventions (those live in job 2 / iosc
  only — `xios_egl` is render-agnostic, so no behavior change for iosc).
- `xios_egl` should expose the `EGLConfig`/`EGLContext` so the Cogl winsys can create *its own*
  surfaces against the same display/context (Mutter may want 2–3 output IOSurfaces rotating for
  double/triple-buffered present; `xios_surface` already owns the output IOSurface lifecycle).
- Keep `iosc_gl.h`'s API stable so iosc.c needs no change beyond the file move.
- No iosc.c edits in this design. The extraction is iosc-input's call; this is the target shape.
