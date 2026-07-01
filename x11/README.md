# X11 and Wayland on iOS

A native Linux desktop running on a jailbroken iPad: a real X11 server, a
GPU-accelerated Wayland compositor, and GTK4 / GNOME apps, all cross-compiled
for rootless iOS (`/var/jb`) and rendered on the A10 GPU through Metal.

This is not VNC and not emulation. Every component is a native arm64 binary.
Apps run as real Unix processes; their pixels reach the screen as `IOSurface`s
that a single iOS app presents with Metal, and your touches reach them as X11 or
Wayland input.

## Architecture

```
                      ┌─────────────────────────────────────┐
                      │              iPad screen             │
                      │           CAMetalLayer (Metal)       │
                      └──────────────────▲──────────────────┘
                                         │  presents the output IOSurface
                                         │  as a Metal texture (zero-copy)
                      ┌──────────────────┴──────────────────┐
                      │     Xios.app  —  the only iOS app    │
                      │  • adopts IOSurface over a mach port │
                      │  • forwards UIKit touch + keyboard   │
                      └────▲────────────────────────┬────────┘
            output IOSurface│                        │ input events
              (mach port)   │                        │
              ┌─────────────┴──────┐      ┌──────────┴──────────────────┐
              │ Xios  (X11 server) │      │ iosc  (Wayland compositor)  │
              │ Xvfb-derived DDX,  │      │ libwayland-server;          │
              │ draws into IOSurf. │      │ GPU-composites clients +    │
              │ XTEST input        │      │ routes input via wl_seat    │
              └─────────────▲──────┘      └──────────▲──────────────────┘
                  X11 proto  │                Wayland │ proto
              ┌─────────────┴──────┐      ┌──────────┴──────────────────┐
              │ X11 apps           │      │ Wayland apps: GTK4 / GNOME  │
              │ xterm, x11-apps    │      │ Console (kgx), Files, ...    │
              │ (software-rendered)│      │ cairo (CPU)  or  GLES (GPU) │
              └────────────────────┘      └──────────┬──────────────────┘
                                                     │ hardware GLES
                                          ┌──────────┴──────────────────┐
                                          │ ANGLE → Metal → A10 GPU     │
                                          │ libEGL / libGLESv2,         │
                                          │ renders directly into       │
                                          │ IOSurfaces (zero-copy)      │
                                          └─────────────────────────────┘

   Multi-backend GTK4: the same binary runs on Xios (X11) or iosc (Wayland);
   GDK_BACKEND picks at launch. On Wayland it can render on the A10 via ANGLE.
```

## How it works

**One app bridges to iOS.** `Xios.app` is the only thing iOS sees. It owns the
screen (a `CAMetalLayer`) and the input (UIKit). It renders nothing itself: it
adopts an `IOSurface` handed to it over a mach port, draws it as a Metal texture
with no copy, and forwards UIKit touch and keyboard back to whichever server is
running. iOS believes one ordinary app is on screen; behind it is a full Linux
display server.

**Two display servers, one display path.** Both produce an output `IOSurface`
the app shows, so they are interchangeable from the app's point of view:
- **Xios** is an Xvfb-derived X server (kdrive-style DDX) that draws the X
  screen into an `IOSurface`. X11 clients connect over the normal X protocol and
  render in software.
- **iosc** is a custom `libwayland-server` compositor (clean-room, MIT). It
  composites Wayland clients on the GPU into the output `IOSurface`, advertises
  the protocols real toolkits need (xdg-shell, xdg-popup, subsurfaces, viewport,
  fractional-scale, wl_data_device clipboard), and routes input via `wl_seat`.

**The GPU is the A10, via ANGLE.** iOS has no OpenGL and no DRM. ANGLE
translates OpenGL ES to Metal, so GLES clients (and iosc's own compositor) run
on the A10. ANGLE renders straight into `IOSurface`s, which means the compositor
can adopt a client's rendered surface as a Metal texture and blend it with zero
CPU copies. (X11 has no path to this on iOS, so X apps stay software; Wayland is
the GPU track.)

**Input flows back through the app.** A tap or keystroke enters UIKit in
`Xios.app`. For X11 it becomes XTEST into the X server; for Wayland it crosses a
small app to iosc socket and becomes `wl_pointer` / `wl_keyboard` events to the
focused window. So you can tap and type into a real GNOME terminal on the iPad
screen, and the keystrokes reach the live shell.

### A frame's journey (Wayland, GPU path)

1. A GTK4 app renders with GLES through ANGLE into its own `IOSurface`.
2. It hands that surface to iosc over a mach port (an Owl-style IOSurface
   `wl_buffer`).
3. iosc adopts it as a Metal/GL texture and composites it (with every other
   window) into the output `IOSurface` on the GPU.
4. `Xios.app` presents that output `IOSurface` as a Metal texture on the screen.

No CPU copy occurs from step 1 to step 4.

## Where things live

| Path | What |
|---|---|
| `linux-build/` | The Procursus/Docker cross-compile pipeline (X server, GTK3/4, GNOME, ANGLE, Wayland W0). See its own README. |
| `wayland/` | `iosc`, the Wayland compositor (`iosc.c`, `iosc_gl.c`, the IOSurface buffer protocol, the wayland-egl shim). |
| `apps/Xios/` | The iOS app: the Metal display surface, IOSurface adoption, and UIKit to X11/Wayland input. |
| `docs/` | Design docs and feasibility studies (Wayland plan, hardware-GL plan, GNOME plan, the Stage-3 compositor spec). |

## Status

Working and validated on-device (iPad 7, A10, iPadOS 17.6.1):

- Native X11 server with apps, displayed via Metal
- GPU Wayland compositor: zero-copy IOSurface compositing, multi-window stacking
- Multi-backend GTK4 (X11 and Wayland), published to the repo
- A real GNOME app (Console, with a live shell) running through iosc
- Interactive touch and keyboard input (tap and type into the terminal)
- GTK4 rendering on the A10 GPU, validated on-device: `GskNglRenderer` realizes
  on an ES3 ANGLE-to-Metal context through the wayland-egl shim into IOSurfaces
  (use `GSK_RENDERER=ngl`; the older `GskGLRenderer` wants an EGL-image
  extension ANGLE-Metal does not expose)

Also packaged: iosc as an installable deb, and gnome-calculator (the Vala app
route).

In progress: more GNOME apps (Files, text editor). The gnome-shell path is
designed in `docs/mutter-on-iosc.md`: Mutter becomes the compositor with a new
iOS/IOSurface backend that harvests iosc's GPU and IOSurface glue (rather than
nesting two compositors), gated on a Cogl-on-ANGLE-ES3 smoke test.
