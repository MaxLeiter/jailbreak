# Xios: X11 and Wayland on iOS

A native Linux desktop running on a jailbroken iPad: a GPU-accelerated Wayland
compositor, GNOME Shell, KDE Plasma, hardware Xwayland for X11 apps, and GTK/Qt
apps, all cross-compiled for rootless iOS (`/var/jb`) and drawn on the A10 GPU
through Metal.

- **Write-up:** [maxleiter.com/blog/xios](https://maxleiter.com/blog/xios): the
  story, what works, screenshots.
- **Wiki:** [xios.maxleiter.com](https://xios.maxleiter.com): architecture,
  display servers, graphics, flavors, hardware bridges, current status.
- **Install it:** [xios.maxleiter.com/try](https://xios.maxleiter.com/try).

The blog post and the wiki cover the design and the current status in depth; this
file is just the map of the directory.

## What it actually is

There is no Linux here. No kernel, no VM, no emulator. The apps are GNOME, GTK,
Qt, and X11 programs from the Linux desktop world, but every one of them is a
native arm64 iOS binary. Their windows reach the screen as `IOSurface`s, and your
touches reach them as X11 or Wayland input.

One app bridges to iOS. `Xios.app` (Home Screen icon "X11") owns a
`CAMetalLayer` and the UIKit input surface and renders nothing of its own. A
Wayland compositor (**iosc**, a clean-room `libwayland-server` compositor, or
Mutter for GNOME; KWin runs nested inside iosc) hands it an output `IOSurface` over a mach port; the app
draws that as a Metal texture every frame and forwards UIKit touch and keyboard
back.

There is one rendering architecture, and it is hardware-only. GTK4 and Xwayland
clients render GLES through ANGLE into their own `IOSurface`s, iosc adopts those
as Metal textures and composites them, and the app scans the result out after
waiting on the producer's brokered GPU fence, with no CPU copy and no software
synchronization fallback anywhere on that path. X11 apps reach it through
rootless Xwayland on glamor, which iosc starts and manages with its own window
manager (the `xios-x11` flavor), not through a separate X server. The old
software-rendered, Xvfb-derived Xios server was retired on 2026-07-29, and Xvfb
survives only as a headless bring-up and debug utility.

Full diagrams: [xios.maxleiter.com/architecture](https://xios.maxleiter.com/architecture).

## Installing

Add `https://repo.maxleiter.com` in Sileo, install AppSync Unified (the display
app is unsigned), then install one flavor:

```
apt install xios-gnome      # or xios-kde, xios-native, xios-x11
```

Every flavor pulls in the shell-independent `xios-runtime` base; the fullscreen
ones (`xios-gnome`, `xios-kde`, `xios-x11`) add `xios-core`, the display app, and
the session launcher, while `xios-native` gives each app its own iPadOS window
instead of a fullscreen shell. The exact closures are in
[`docs/repo-fold-in.md`](docs/repo-fold-in.md). Open the app and pick a session, or run
`xios-session gnome` from a shell. What each flavor contains:
[xios.maxleiter.com/flavors](https://xios.maxleiter.com/flavors). Troubleshooting
a session that will not come up: [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md).

## Where things live

| Path | What |
|---|---|
| `apps/Xios/` | The iOS display app: Metal present, IOSurface adoption, UIKit to X11/Wayland input. |
| `apps/iosc-host/` | The native-mode per-window host app. |
| `apps/iosc-shell/` | The iosc desktop shell (panel / dock / overview / wallpaper). |
| `apps/iosc-desktop/` | Session launcher, launch daemons, launcher generation, deploy helpers. |
| `wayland/` | `iosc`, the compositor, plus the input socket and the host bridges. |
| `linux-build/` | The Procursus/Docker cross-compile pipeline; see [`linux-build/README.md`](linux-build/README.md). |
| `packages/` | Debs: the flavor metas, `xios-fhs` hardware bridges, fonts and theme. |
| `ports/` | Quilt patch series for upstream sources we carry patches against. |
| `site/` | The wiki (Next.js), deployed to xios.maxleiter.com. |
| `bin/`, `lib/` | Device and smoke-test helpers (`xios-device`, capture scripts, `x11-up.sh` for X over VNC). |
| `tools/` | Repo-side utilities: package sync into `repo/`, Mach-O weakening, iOS-marker stamping. |
| `docs/` | Design docs and plans; `docs/handoff/INDEX.md` is the current-state index. |

## Working in here

Read [`AGENTS.md`](AGENTS.md) before changing a subsystem. It carries the
invariants that are expensive to rediscover: the rootless `/var/jb` prefix,
IOSurface output, never hardcoding framebuffer geometry (read
`/var/jb/tmp/xios.json`), coordinated compositor/app deploys when a wire
protocol changes, and the narrow entitlement sets that GPU and IOKit access
depend on. [`SCOPE.md`](SCOPE.md) is the historical scope note from the X-over-VNC
era; the wiki supersedes its status tables.
