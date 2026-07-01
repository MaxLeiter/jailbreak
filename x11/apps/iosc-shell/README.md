# iosc-shell — our own desktop shell for the iosc compositor

The panel / quick settings / launcher / overview / wallpaper that make `iosc`
feel like a desktop, built as **layer-shell clients** of the compositor (not
chrome baked into `iosc.c`). Design and the iosc-side protocol hand-off:
**`../../docs/iosc-shell.md`**. Ships as the **`iosc-shell`** deb; this is the
lightweight 5th flavor of the distribution chooser.

This complements `../iosc-desktop/` (which turns Linux apps into iOS Home Screen
icons); this is the chrome *inside* the Xios display.

## What's here

| File | Role |
|---|---|
| `ioscpanel.c` | the panel: `zwlr_layer_shell_v1` client anchored top — app-grid button, launcher tiles, window taskbar (foreign-toplevel: activate/close), battery + date + clock cluster, and the quick-settings card (frosted screencopy backdrop, battery bar, Overview/Screenshot actions). |
| `ioscoverview.c` | full-screen OVERLAY layer surface — search field, open-window chips, app grid over the blurred + scrimmed desktop (one-shot screencopy). Tap to launch/raise, Escape/background tap dismisses. |
| `ioscbg.c` | wallpaper on the background layer: wl_shm + CoreGraphics/ImageIO decode of `$IOSC_WALLPAPER` (default: the xios-desktop-theme JPEG), gradient fallback. |
| `shell-theme.h` | the design tokens: palette, radii, spacing, type scale. Edit here first. |
| `panel-render.h` | cairo/pango draw primitives on the tokens (text, pills, cards, icons). |
| `panel-layout.h` / `overview-layout.h` | wayland-free scene layout + hit-testing, shared verbatim by the device clients and the preview harness. |
| `shell-blur.h` | the frosted "material": box-blur passes + tint over a screencopy capture. |
| `shell-screencopy.h` | one-shot synchronous zwlr-screencopy capture into a cairo surface. |
| `shell-status.h` | battery/charging + date/time readers (IOKit-free: sysfs-style /var/jb paths + libproc fallbacks). |
| `shell-draw.h` | `.desktop` scan + app launch + anon-fd/shm helpers (SD_NO_DRAW mode); legacy 5x7 software renderer for the v1 clients. |
| `panel-icons.h` | Icon= name -> shipped PNG resolution (no SVG loader on device; see `gen-shell-icons.sh`). |
| `preview-host.c` | off-device preview harness: renders the real layout code to `design/preview-{desktop,quicksettings,overview}.png` with SF type. The design iteration loop. |
| `protocols/` | vendored protocol XML: wlr-layer-shell, wlr-foreign-toplevel-management, wlr-screencopy, xdg-shell. |
| `build-panel.sh` | cross-compile + link + sign all three clients for rootless iOS arm64 (Docker; cairo/pango stack from procursus-vol-gtk). |
| `build-preview.sh` | compile + run `preview-host.c` natively in the container (fast visual iteration; no device). |
| `run-shell.sh` | on-device bring-up: iosc (if needed) -> ioscbg -> ioscpanel. |
| `package-shell.sh` | assemble the `iosc-shell` deb (binaries + run script + icon set). |
| `panel-ent.xml` | client entitlements (wl_shm clients: sockets + .desktop scan + launch; no GPU IOKit classes). |

## Build and package

```sh
./build-panel.sh        # -> out/ioscpanel, out/ioscoverview, out/ioscbg (signed)
./build-preview.sh      # -> design/preview-*.png (the design loop; SF type)
./package-shell.sh      # -> iosc-shell_<ver>_iphoneos-arm64.deb (out/ + repo/debs)
```

Gotcha: the *link* lines need `-miphoneos-version-min` too, or ld64 stamps the
SDK version (16.5) as the dyld floor and the deb's stamped minos overshoots.

## Run (on-device)

```sh
apt install iosc iosc-shell        # iosc >= 0.9.0 (layer-shell + screencopy)
run-shell.sh                       # then open the Xios app
```

The panel's grid button / QS "Overview" spawns `ioscoverview` on demand.
Env knobs: `IOSC_PANEL_SCALE`, `IOSC_WALLPAPER`, `IOSC_SHELL_ICONS`.

## Compositor requirements (met since iosc 0.9.0)

zwlr-layer-shell v4, zwlr-foreign-toplevel-management v3, zwlr-screencopy v1
(software). On an older iosc each client exits with a clear message. Pending
polish: `IOSC_ROLE_LAYER` alpha blending in iosc for true panel translucency
(the QS card fakes it today with a screencopy backdrop).
