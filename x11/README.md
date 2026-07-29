# X11 and Wayland on iOS

A native Linux desktop running on a jailbroken iPad: a real X11 server, a
GPU-accelerated Wayland compositor, GNOME Shell, KDE Plasma, and GTK/Qt apps, all
cross-compiled for rootless iOS (`/var/jb`) and drawn on the A10 GPU through
Metal.

Full write-up, diagrams, and status: **https://xios.maxleiter.com**

There is no Linux here. No kernel, no VM, no emulator. The apps are GNOME, GTK,
and X11 programs from the Linux desktop world, but every one of them is a native
arm64 iOS binary. Their windows reach the screen as `IOSurface`s, and your
touches reach them as X11 or Wayland input.

## The story

Years ago I compiled X11 and its whole dependency tree for a jailbroken iPad, by
hand, on the device. It ran, but you reached it through a VNC client: the pixels
were real, the path to them was a network hop to localhost. This is that project
done over. The servers now draw straight to the screen, and there is no VNC and
no Mac in the loop.

## Architecture

One app bridges to iOS. `Xios.app` (shown on the Home Screen as "X11") owns a
`CAMetalLayer` and the UIKit input surface and renders nothing of its own. A
display server hands it an output `IOSurface` over a mach port; the app draws
that as a Metal texture every frame and forwards UIKit touch and keyboard back to
the server.

```
        +-------------------------------------------+
        |            iPad screen (Metal)            |
        +---------------------^---------------------+
                              | output IOSurface, no copy
        +---------------------+---------------------+
        |   Xios.app  (the app iOS sees; "X11")     |
        +------^---------------------------+--------+
     IOSurface |                           | UIKit input
        +------+----------+       +--------+------------------+
        |  Xios (X11)     |       |  iosc (Wayland)           |
        |  Xvfb-derived   |       |  libwayland-server        |
        |  software       |       |  GPU compositor           |
        +------^----------+       +--------^------------------+
      X11 proto |                  Wayland | proto
        +------+----------+       +--------+------------------+
        |  X11 apps (CPU) |       |  GTK4 / GNOME apps        |
        +-----------------+       +--------^------------------+
                                           | GLES
                                  +--------+------------------+
                                  |  ANGLE -> Metal -> A10 GPU|
                                  +---------------------------+
```

Both servers produce the same output `IOSurface`, so they are interchangeable
from the app's point of view. Xios is an Xvfb-derived X server that draws into an
`IOSurface`; X11 clients render in software. iosc is a clean-room
`libwayland-server` compositor that blends client surfaces on the GPU and routes
input through `wl_seat`.

On the Wayland path a GTK4 app renders GLES through ANGLE into its own
`IOSurface`, iosc adopts that as a Metal texture and composites it, and the app
scans the result out. No CPU copy happens anywhere along that path.

## Three ways to run a desktop

Install one flavor package; each pulls in the shared `xios-core` base.

- **Native mode** (`xios-native`) - X11/Wayland apps can show up on the Home
  Screen and launch as per-window iPadOS apps. The core path exists; host-window
  validation and polish are still in progress.
- **iosc desktop** (in every flavor, via `xios-core`) - the compositor's own
  tablet-first shell: a panel with launchers, a dock, an overview, and a
  wallpaper. Runs interactively on device today.
- **Bring your own DE** - full upstream environments. GNOME Shell 46 works on
  device through the packaged `xios-gnome` session. KDE Plasma Desktop and
  Plasma Mobile work through KWin/KF6 in `xios-kde`; the remaining work is polish
  and productization, not first paint.

## Installing it

Add `https://repo.maxleiter.com` in Sileo, install AppSync Unified (the display
app is unsigned), then install one flavor:

```
apt install xios-gnome      # or xios-kde, xios-native, xios-x11
```

That pulls in the display app (Home Screen icon "X11"), the compositor, the GPU
stack, and the session launcher. Open the app and pick a session, or run
`xios-session gnome` from a shell. Full instructions, including troubleshooting:
[`docs/USER-GUIDE.md`](docs/USER-GUIDE.md) and
[xios.maxleiter.com/try](https://xios.maxleiter.com/try).

## The GPU path

iOS gives this stack no DRM/KMS device and no desktop OpenGL path, but the A10 is
still there behind Metal. ANGLE translates OpenGL ES to Metal and renders into
`IOSurface`s, so GLES clients and iosc itself run on the GPU. GTK4's
`GskNglRenderer` realizes on an ES3 ANGLE-to-Metal context and draws into
`IOSurface`s, validated on device. X11 has no route to this on iOS, so the X
track stays software.

## Hardware and POSIX bridges

A desktop expects a battery, brightness, sound, a keyboard, orientation, and a
user. None of that exists in the Linux sense on iOS, so small daemons read the
real iOS API and republish it as the D-Bus service, Wayland protocol, or sysfs
file the desktop wants.

- **Live:** `xios-input` (touch/Pencil/keys/scroll to `wl_seat`), `xios-osk`
  (iOS keyboard to `text-input-v3`), `xios-audiod` (RemoteIO to PulseAudio),
  `xios-hwbridged` (battery/backlight), `xios-sysintd`
  (volume/dark-mode/rotation), `xios-sensord` (CoreMotion), session identity,
  login1/polkit/Accounts stubs, `xios-fhs`, and the fonts/theme defaults.
- **In progress:** Bluetooth/BlueZ coverage, true UIKit pasteboard round trips,
  physical haptic feel, real VoiceOver gesture validation, and GNOME-facing
  camera/media portal work.

## Build and packaging

Everything is cross-compiled on a Mac in Docker against the
[Procursus](https://github.com/ProcursusTeam/Procursus) toolchain, patched
reproducibly with quilt, and shipped as Debian packages to an apt repo at
**repo.maxleiter.com**. The harder cross-compiles include mozjs 115 (with JIT,
which lets gjs and GNOME Shell run), Bun (JIT and `bun:ffi` despite iOS blocking
executable heap), ANGLE, ICU (native-then-cross), and the Qt6 / KF6 ladders.

## Status

Validated on device (iPad 7, A10, iPadOS 17.6.1). The device is the reference,
not the limit; packages target rootless jailbroken iOS more broadly.

- Native X11 server running apps, displayed through Metal
- GPU Wayland compositor: zero-copy IOSurface compositing, multi-window stacking
- iosc desktop shell running interactively on device
- GTK3/GTK4, Qt/KF6, X11, and Wayland app waves running under iosc
- GTK4 rendering on the A10 GPU through ANGLE-to-Metal
- GNOME Shell 46 working through the packaged `xios-session gnome` path
- KDE Plasma Desktop working through `xios-session kde` / `kde-desktop`, with
  Kicker app launch, System Settings/KScreen, Breeze styling, and the first KDE
  app batch verified
- Plasma Mobile mostly working: full-frame orientation-correct sessions, live
  iOS-backed status providers, drawer/home/app-launch proof, and remaining polish
  around log noise and product fit
- Native per-window iPadOS mode implemented and runtime-gated; host-window polish
  remains

## Where things live

| Path | What |
|---|---|
| `linux-build/` | The Procursus/Docker cross-compile pipeline (X server, GTK, GNOME, ANGLE, Qt/KF6). |
| `wayland/` | `iosc`, the Wayland compositor, plus the input socket and the host bridges. |
| `apps/Xios/` | The iOS app: Metal present, IOSurface adoption, UIKit to X11/Wayland input. |
| `apps/iosc-host/` | The native-mode per-window host app. |
| `apps/iosc-shell/` | The iosc desktop shell (panel / dock / overview). |
| `packages/` | Debs: the flavor metas, `xios-fhs` hardware bridges, fonts and theme. |
| `site/` | This project's wiki (Next.js), deployed to xios.maxleiter.com. |
| `docs/` | Design docs and plans. |
