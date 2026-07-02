# iosc-shell — our own desktop shell for the iosc compositor

The status bar / dock / Control Center / overview / wallpaper that make `iosc`
feel like a desktop, built as **layer-shell clients** of the compositor (not
chrome baked into `iosc.c`). Design and the iosc-side protocol hand-off:
**`../../docs/iosc-shell.md`**. Ships as the **`iosc-shell`** deb; this is the
lightweight 5th flavor of the distribution chooser.

This complements `../iosc-desktop/` (which turns Linux apps into iOS Home Screen
icons); this is the chrome *inside* the Xios display.

## What's here

| File | Role |
|---|---|
| `iosc-shell.c` | shared shell client implementation for `ioscbar` and `ioscdock`: status bar + Control Center, floating dock, launcher/running-window activation. |
| `ioscoverview.c` | full-screen OVERLAY layer surface — search field, open-window chips, app grid over the blurred + scrimmed desktop (one-shot screencopy). Tap to launch/raise, Escape/background tap dismisses. |
| `ioscbg.c` | wallpaper + desktop widgets on the background layer: wl_shm + CoreGraphics/ImageIO decode of `$IOSC_WALLPAPER`, cairo/pango cards for storage, memory, load, and uptime. |
| `shell-theme.h` | the design tokens: palette, radii, spacing, type scale. Edit here first. |
| `panel-render.h` | cairo/pango draw primitives on the tokens (text, pills, cards, icons). |
| `panel-layout.h` / `overview-layout.h` | wayland-free scene layout + hit-testing, shared verbatim by the device clients and the preview harness. |
| `shell-blur.h` | the frosted "material": box-blur passes + tint over a screencopy capture. |
| `shell-screencopy.h` | one-shot synchronous zwlr-screencopy capture into a cairo surface. |
| `shell-status.h` | battery/charging + date/time readers (IOKit/CoreFoundation, with clean fallbacks). |
| `shell-draw.h` | `.desktop` scan + app launch + anon-fd/shm helpers. |
| `panel-icons.h` | Icon= name -> shipped PNG resolution (no SVG loader on device; see `gen-shell-icons.sh`). |
| `preview-host.c` | off-device preview harness: renders the real layout code to `design/preview-{desktop,quicksettings,overview}.png` with SF type. The design iteration loop. |
| `protocols/` | vendored protocol XML: wlr-layer-shell, wlr-foreign-toplevel-management, wlr-screencopy, xdg-shell. |
| `build-panel.sh` | cross-compile + link + sign the shell clients for iOS arm64 (Docker; cairo/pango stack from procursus-vol-gtk). |
| `build-preview.sh` | compile + run `preview-host.c` natively in the container (fast visual iteration; no device). |
| `run-shell.sh` | on-device bring-up: iosc (if needed) -> ioscbg -> ioscbar + ioscdock. |
| `package-shell.sh` | assemble the `iosc-shell` deb (binaries + run script + icon set). |
| `panel-ent.xml` | client entitlements (wl_shm clients: sockets + .desktop scan + launch; no GPU IOKit classes). |

## Build and package

```sh
./build-panel.sh        # -> out/ioscbar, out/ioscdock, out/ioscoverview, out/ioscbg
./build-preview.sh      # -> design/preview-*.png (the design loop; SF type)
./package-shell.sh      # -> iosc-shell_<ver>_iphoneos-arm64.deb (out/ + repo/debs)
```

Rootless is the default scheme. For rootful builds/packages, use:

```sh
IOSC_PACKAGE_SCHEME=rootful ./build-panel.sh
IOSC_PACKAGE_SCHEME=rootful ./package-shell.sh
```

`build-panel.sh` maps `rootless` to Procursus target `iphoneos-arm64-rootless`
with prefix `/var/jb`, and `rootful` to target `iphoneos-arm64` with prefix `/`.
Use `IOSC_PROC_VOL`/`GTK_VOL` if the rootful Procursus sysroot lives in a
different Docker volume.

Gotcha: the *link* lines need `-miphoneos-version-min` too, or ld64 stamps the
SDK version (16.5) as the dyld floor and the deb's stamped minos overshoots.

## Run (on-device)

```sh
apt install iosc iosc-shell        # iosc >= 0.9.0 (layer-shell + screencopy)
run-shell.sh                       # then open the Xios app
```

The dock's apps button / Control Center "Overview" spawns `ioscoverview` on demand.
Long-press a desktop widget to drag it; long-press a dock app icon to reorder
favorites. Layout state persists outside the package prefix by default:
`/var/mobile/Library/Preferences/com.max.iosc-widgets.conf` and
`/var/mobile/Library/Preferences/com.max.iosc-dock-order`.

Env knobs: `IOSC_PANEL_SCALE`, `IOSC_WALLPAPER`, `IOSC_SHELL_ICONS`,
`IOSC_WIDGET_CONFIG`, `IOSC_DOCK_ORDER`.

## Compositor requirements (met since iosc 0.9.0)

zwlr-layer-shell v4, zwlr-foreign-toplevel-management v3, zwlr-screencopy v1
(software). On an older iosc each client exits with a clear message. Pending
polish: `IOSC_ROLE_LAYER` alpha blending in iosc for true shell translucency
(the Control Center card fakes it today with a screencopy backdrop).
