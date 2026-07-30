# Xios — X11 and Wayland on iOS

A native Linux desktop running on a jailbroken iPad: a real X11 server, a
GPU-accelerated Wayland compositor, GNOME Shell, KDE Plasma, and GTK/Qt apps, all
cross-compiled for rootless iOS (`/var/jb`) and drawn on the A10 GPU through
Metal.

- **Write-up:** [maxleiter.com/blog/xios](https://maxleiter.com/blog/xios) — the
  story, what works, screenshots.
- **Wiki:** [xios.maxleiter.com](https://xios.maxleiter.com) — architecture,
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
display server hands it an output `IOSurface` over a mach port; the app draws
that as a Metal texture every frame and forwards UIKit touch and keyboard back.
Two servers produce that same surface, so they are interchangeable: **Xios**, an
Xvfb-derived X server whose clients render in software, and **iosc**, a
clean-room `libwayland-server` compositor that blends client surfaces on the GPU
through ANGLE-to-Metal with no CPU copy anywhere on the path.

Full diagrams: [xios.maxleiter.com/architecture](https://xios.maxleiter.com/architecture).

## Installing

Add `https://repo.maxleiter.com` in Sileo, install AppSync Unified (the display
app is unsigned), then install one flavor:

```
apt install xios-gnome      # or xios-kde, xios-native, xios-x11
```

A flavor pulls in the shared base packages it needs — the compositor, the GPU
stack, the session launcher, and (for the fullscreen flavors) the display app.
Open the app and pick a session, or run `xios-session gnome` from a shell. Which
base packages each flavor gets, and how to troubleshoot a session that will not
come up, are in [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md).

## Where things live

| Path | What |
|---|---|
| `apps/Xios/` | The iOS display app: Metal present, IOSurface adoption, UIKit to X11/Wayland input. |
| `apps/iosc-host/` | The native-mode per-window host app. |
| `apps/iosc-shell/` | The iosc desktop shell (panel / dock / overview / wallpaper). |
| `apps/iosc-desktop/` | Session launcher, launch daemons, launcher generation, deploy helpers. |
| `wayland/` | `iosc`, the compositor, plus the input socket and the host bridges. |
| `linux-build/` | The Procursus/Docker cross-compile pipeline — see [`linux-build/README.md`](linux-build/README.md). |
| `packages/` | Debs: the flavor metas, `xios-fhs` hardware bridges, fonts and theme. |
| `ports/` | Quilt patch series for upstream sources we carry patches against. |
| `site/` | The wiki (Next.js), deployed to xios.maxleiter.com. |
| `bin/`, `lib/` | Session/smoke-test launchers and device helpers (`x11-up.sh`, `xios-device`, capture scripts). |
| `tools/` | Repo-side utilities: package sync into `repo/`, Mach-O weakening, iOS-marker stamping. |
| `docs/` | Design docs and plans; `docs/handoff/INDEX.md` is the current-state index. |

## Working in here

Read [`AGENTS.md`](AGENTS.md) before changing a subsystem — it carries the
invariants that are expensive to rediscover: the rootless `/var/jb` prefix,
IOSurface output, never hardcoding framebuffer geometry (read
`/var/jb/tmp/xios.json`), coordinated compositor/app deploys when a wire
protocol changes, and the narrow entitlement sets that GPU and IOKit access
depend on. [`SCOPE.md`](SCOPE.md) is the historical scope note from the X-over-VNC
era; the wiki supersedes its status tables.
