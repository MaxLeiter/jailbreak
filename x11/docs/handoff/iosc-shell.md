# iosc-shell — the iosc lightweight desktop shell

## Ownership
The shell that runs on the iosc compositor: the slim status bar, floating dock, Control Center, wallpaper, and overview/app-grid. Plus the tablet-DE redesign vision. NOT the compositor itself (that's iosc-compositor.md) and NOT the app scaling (that's xios-app.md).

## Key files
- `x11/apps/iosc-shell/iosc-shell.c` — shared layer-shell implementation: must run as `ioscbar` (status + Control Center trigger) or `ioscdock` (favorites/running apps/apps button). Scale-invariant since 0.9.5 (draws at a 1440 reference, scales by `ui = logical_width/1440`).
- `x11/apps/iosc-shell/ioscbg.c` — wallpaper (layer-shell background).
- `x11/apps/iosc-shell/ioscoverview.c` — the overview: search + Open Windows + Applications grid.
- `x11/apps/iosc-shell/panel-layout.h`, `panel-render.h`, `preview-*.c` (off-device mockup renderer).
- `x11/apps/iosc-shell/docs/iosc-shell.md` — design doc; **§0 = the tablet-DE vision**.
- `x11/apps/iosc-shell/design/*.png` — mockups, incl. `vision-home.png` + `vision-control.png`.
- Build: `build-panel.sh`, `build-preview.sh`. Env: `IOSC_SHELL_DEBUG=1` (input trace), `IOSC_PANEL_SCALE=2`, `IOSC_PANEL_OPACITY` (0-100, default 85).

## Current state
- **0.9.6 deployed** (repo/debs + linux-build/out, minos 16.2): scale-invariant panel, full input-event trace to `/var/jb/tmp/iosc-shell.log`, a safety clamp on the launcher strip.
- Panel input path PROVEN correct on-device: `pt_enter`/`pt_button`/`hit_at` all fire and resolve to the right control (injected-tap test). iosc delivers pointer+touch to layer surfaces (role-agnostic pick, confirmed by iosc-compositor).
- The "search bar / window-pill cut off at the right" was measured OFF-DEVICE at exactly logical 1600 → the shell does NOT overflow (search pill centered at x=460..1140, all rects ≤1600). It was the APP's stale-scale bug (xios-app.md), NOT shell layout. No shell change needed for that.
- **Tablet-DE vision written + mocked** (docs §0, vision-home.png + vision-control.png) and now used as the basis for the 0.9.7 split-surface first pass.
- **0.9.9 split-surface shell installed on-device**: `iosc-shell.c` now runs as two roles based on `argv[0]`:
  - `ioscbar`: slim top status bar (focused app, centered clock, wifi/battery) + Control Center trigger.
  - `ioscdock`: bottom-anchored floating dock (favorites, running-window icons/dots, apps button).
  `build-panel.sh` cross-builds/signs `out/ioscbar`, `out/ioscdock`, `out/ioscoverview`, `out/ioscbg`; `run-shell.sh` requires bar+dock.
- `shell-draw.h` launchers now create/reuse `/var/jb/tmp/iosc-shell-bus/session-bus`
  with `dbus-daemon --session --fork` and fall back to `dbus-run-session` only if
  direct bus startup fails. This keeps shell-launched GTK apps on one app bus for
  the AT-SPI bridge instead of stranding each app on a private bus.
- Off-device previews regenerated from the real layout (`build-preview.sh`): `preview-desktop.png`, `preview-quicksettings.png`, `preview-compact.png` now show the split status bar + dock composition. Real iOS cross-build passed on 2026-07-01.
- Local dirty tree also adds a small focused-app window menu from the app-name hit target (`Minimize`, `Maximize`, `Close`) backed by foreign-toplevel requests. Treat it as in-progress until built/deployed with the rest of 0.9.7.

## The tablet-DE vision (docs/iosc-shell.md §0) — a mobile×desktop hybrid, not a shrunk GNOME
Four surfaces, each one job:
1. **Slim status bar** (top, ~36px, always-on, translucent): clock + battery/wifi only; pull-down handle for Control Center.
2. **Floating dock** (bottom, frosted pill): favorites (launchers) + running apps (icon + running-dot, tap-to-raise = taskbar-as-dock) + apps/overview button; ≥48pt targets; auto-hide in fullscreen; home-indicator pill.
3. **Control Center** (swipe down top-right): iPadOS-style circular toggles (Wi-Fi/BT/Rotation) + brightness/volume sliders + dark-mode/screenshot tiles.
4. **Overview/Home** (swipe up): search + open-window cards + app grid.
Plus a window model (fullscreen→split→float, Stage-Manager style) and a gesture grammar (swipe up=home, down=control) with pointer/keyboard equivalents (touch-first, never touch-only).

## Open items
1. **On-device validate the full 0.9.9 shell interactions**: deploy/install `ioscbar`, `ioscdock`, `ioscoverview`, `ioscbg`; start via `run-shell.sh`; confirm:
   - `ioscbar` maps at top, opens Control Center from the status cluster.
   - `ioscdock` maps at bottom, apps button opens overview.
   - running-window icons activate via foreign-toplevel.
   - focused-app window menu opens from the app name and its minimize/maximize/close actions hit the right window.
   - launchers still fire (`sd_launch`: fork -> shared `iosc-shell-bus` -> sh -lc <Exec>).
2. **Package/deploy 0.9.9** after full shell interaction smoke: `package-shell.sh` assembles `iosc-shell_0.9.9_iphoneos-arm64.deb`, and that deb was installed during the a11y shared-bus pass. Dock/panel tap behavior still needs a focused launcher-action smoke.
3. **Launcher-action verify**: taps resolve (`hit_at`→launcher idx) but confirm the launch actually fires with a real app/window. If it resolves but doesn't launch, chase the exec env / launched app stderr.
4. Server-side decorations (SSD) path for GTK CSD windows (was noted as the decor path; lead-sequenced).

## Deploy (shell-only, cheap — no compositor rebuild)
```
scp -O x11/apps/iosc-shell/out/ioscbar x11/apps/iosc-shell/out/ioscdock x11/apps/iosc-shell/out/ioscoverview x11/apps/iosc-shell/out/ioscbg root@ipad:/var/jb/usr/local/bin/
ssh: pkill by PID (pkill-by-name can miss), then relaunch via run-shell.sh or directly with IOSC_SHELL_DEBUG=1 IOSC_PANEL_SCALE=2.
```
Depends on iosc ≥ 0.9.1 for layer-surface translucency (see iosc-compositor.md).
