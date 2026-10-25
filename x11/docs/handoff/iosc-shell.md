# iosc-shell: the lightweight desktop shell on iosc

The status bar, dock, Control Center, overview and wallpaper that run on the iosc
compositor, built as layer-shell clients (not chrome inside `iosc.c`). Not the
compositor (`iosc-compositor.md`) and not app scaling (`xios-app.md`). Design and
the tablet-DE vision: `../iosc-shell.md`. File map and build:
`apps/iosc-shell/README.md`.

## Current state (2026-10-25)

- **Published:** `iosc-shell 0.9.14` (2026-10-06, Xios v2 M0). It runs as the
  `iosc` preset of `xios-session` and is pulled in by `xios-core`.
- Four clients from `apps/iosc-shell/`:
  - `ioscbar`: slim top bar (focused app with a Minimize/Maximize/Close window
    menu, clock, battery/wifi) and the Control Center trigger.
  - `ioscdock`: floating dock with favorites, running windows (foreign-toplevel)
    and the apps button; long-press reorders favorites.
  - `ioscoverview`: search, open windows and the app grid over a blurred
    screencopy, spawned on demand.
  - `ioscbg`: wallpaper plus storage/memory/load/uptime widgets and desktop pins;
    long-press drags a widget.
- Scale-invariant since 0.9.5: drawn at a 1440 reference width and scaled by
  `logical_width/1440`. The clients follow iosc's output scale.
- **Launches run as `mobile`** (2026-10-01), the same way ioscd's LAUNCH does,
  with `HOME=/var/mobile`. They join one mobile-owned session bus under
  `/var/jb/tmp/iosc-shell-bus/` so the AT-SPI bridge sees every app. A pin whose
  command needs root now fails. They also get an absolute `WAYLAND_DISPLAY`
  and keep the whole `Exec` line.
- Layout state lives outside the package prefix:
  `/var/mobile/Library/Preferences/com.max.iosc-widgets.conf` and
  `com.max.iosc-dock-order`. Writes refuse a symlinked last path component.
- M0 coexistence: a slot comes from `WAYLAND_DISPLAY`; `run-shell.sh` refuses a
  positional slot name (it used to be silently ignored and clobbered the default
  slot). Use `xios-session --slot <name> iosc`.

## Gotchas
- The panel input path is proven: iosc delivers pointer and touch to layer
  surfaces with a role-agnostic pick, and `hit_at` resolves the right control.
  The old "search pill cut off at the right" was the app's stale-scale bug, not
  shell layout.
- Translucency needs iosc to blend layer surfaces with alpha (since iosc 0.9.1).
  The frosted Control Center and overview backdrops come from screencopy, because
  iosc does not blur.
- Link lines need `-miphoneos-version-min` too, or ld64 stamps the SDK version as
  the dyld floor.
- `IOSC_SHELL_DEBUG=1` traces input to `/var/jb/tmp/iosc-shell.log` (off by
  default). Other knobs: `IOSC_PANEL_SCALE`, `IOSC_PANEL_OPACITY` (0-100, default
  85), `IOSC_WALLPAPER`, `IOSC_SHELL_ICONS`.
- Kill shell clients by PID when iterating; `run-shell.sh` matches running clients
  by program name.

## Open items
1. Device run of the 2026-10-01 launch changes (mobile identity, Documents, pins).
   Shell writes still accept a redirected `/var/mobile/Library` (audit item).
2. Server-side decorations for GTK CSD windows (design in `../iosc-shell.md` §5.5).
3. Portrait layout tuning at 1080x1440 logical.

## Iterate on device (no compositor rebuild)
```
apps/iosc-shell/build-panel.sh        # out/ioscbar, ioscdock, ioscoverview, ioscbg
scp -O those four to /var/jb/usr/local/bin/
kill the running clients by PID, then rerun run-shell.sh
apps/iosc-shell/package-shell.sh      # the deb, after bumping VER
```
`build-preview.sh` renders the real layout code to `design/preview-*.png` off the
device.
