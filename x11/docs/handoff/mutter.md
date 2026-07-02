# mutter — MetaBackendIOS (Mutter on iOS = GNOME Shell's compositor)

## Ownership
The Mutter 46 backend for iOS: renders its Clutter stage to an IOSurface via Cogl-on-ANGLE/Metal, and pumps the Xios app's input into Clutter. GNOME Shell IS Mutter (links libmutter-14, runs its own MetaBackendIOS), so this backend = the GNOME flavor's compositor.

## Key files
- `x11/wayland/meta-input-ios.c` — the input pump (kqueue drain of the app's input socket → ClutterVirtualInputDevice → notify_absolute_motion/notify_button/etc).
- MetaBackendIOS backend pieces (winsys/monitor-mgr/IOSurface-buffer/login1-stub) — compile against Mutter 46 ABI off-device; build check `build-backend-check.sh`. Backend selected by `gnome-shell --wayland` (compositor-TYPE branch → create_ios_backend, no argv check).
- `x11/linux-build/out/libmutter-14-0_46.0_*.deb` = **build10** (all fixes below). `mutter` thin exe is separate; the fixes are in libmutter.
- Run: `x11/wayland/run-mutter.sh` (smoke), and gnome-session's `run-gnome-shell.sh` (the real boot).
- Output IOSurface is HARDCODED 2160×1620 (`xios_surface_create(2160,1620)`); input ratio-map divides by `xios_output_geometry()` = same 2160×1620.

## build10 fixes (all landed)
- Route-A MetaRendererIOS (IOSurface FBO 0 via ANGLE, not pbuffer).
- Cogl config-attribs overflow fix (shrink to SURFACE_TYPE).
- Frame-clock PENDING_PRESENTED (was warning-looping on IDLE).
- Y-flip override (is_y_flipped→TRUE; onscreen pbuffer never swaps).
- Input pump: kqueue fd not GLib-pollable → 8ms g_timeout drain; coord ratio-map to stage size; button uses last-commanded position (not stale seat state).

## Current state
- **First-pixels VALIDATED** on-device (GNOME apps GPU-composited via mutter earlier).
- **Input transport VALIDATED**: `/var/jb/tmp/mutter-input.sock` events move the compositor cursor and reach a Wayland client in the app-bypass probe.
- **Dispatch machinery VERIFIED SOUND**: `_clutter_event_push` → `clutter_stage_pick_and_update_device` repicks the actor at the event coords + updates pointer focus → dispatches to the Wayland client, PROVIDED the window actor is mapped and coords are in-bounds.
- **Mutter-side click dispatch fix identified and patched**: the first xdg-shell buffer commit must call `meta_window_update_visibility(window)` before setting `first_buffer_attached`, or the window actor remains unmapped and unpickable.
- App-side coord offset was also real and is fixed in xios-app (a7da822 + follow-up geometry sync). Keep using `/var/jb/tmp/xios.json` as the authority for fb size.

## 2026-07-01 follow-up
- Codex installed the staged `/var/jb/tmp/libmutter-b10.deb` on device; `/var/jb/usr/lib/libmutter-14.dylib` now contains the expected `MetaInputIOS: motion out(...) -> stage(...)` mapping diagnostic.
- Re-ran `wayland/run-mutter.sh`: Mutter started, Xios adopted the IOSurface, `/var/jb/tmp/xios.json` advertised `2160x1620` and `input_socket=/var/jb/tmp/mutter-input.sock`.
- Direct injection with `/var/jb/usr/local/bin/iosc-input-test --mutter -c 1080 810` connected to `/var/jb/tmp/mutter-input.sock` and logged:
  `motion out(1080,810)/2160x1620 -> stage(1080.0,810.0) in 2160x1620`.
  This proves the app-bypass socket path and Mutter ratio mapping are correct/identity for the center click.
- A quick `kgx` keyboard marker and `iosc-dnd-test --no-drag` pointer probe did not produce a positive client-dispatch marker before the session switched back to iosc; don't over-interpret that as a regression. The strong verified result is coordinate mapping + transport. If client dispatch still matters, restart Mutter with a purpose-built pointer logger and inspect pick/focus after `_clutter_event_push`.
- Device is currently back on iosc (`/var/jb/usr/local/bin/iosc -logical 1440x1080`, panel/bg running, Xios adopted `2880x2160`), not standalone Mutter.

## 2026-07-01 evening validation
- Rebuilt and installed a libmutter package with `meta_window_update_visibility()` triggered on the first xdg-shell buffer commit (`linux-build/patches/mutter/meta-wayland-xdg-first-buffer-showing.patch`).
- App-bypass pointer test is now GREEN:
  ```
  env XDG_RUNTIME_DIR=/var/jb/tmp WAYLAND_DISPLAY=wayland-0 mutter-pointer-test
  iosc-input-test --socket /var/jb/tmp/mutter-input.sock -c 540 405
  ```
  The probe logged `ENTER`, `MOTION`, `BUTTON` and wrote `/var/jb/tmp/mutter-pointer-hit`.
- Root cause of the remaining Mutter-side dispatch failure: xdg-shell's first buffer set `first_buffer_attached` but did not recompute `MetaWindow` visibility, leaving the `MetaWindowActorWayland` unmapped (`mapped=0 visible=0`). Calling `meta_window_update_visibility(window)` before setting `first_buffer_attached` maps the actor; repick then lands on `MetaSurfaceActorWayland`, focus is set, and button events reach the Wayland client.
- `meta-wayland-pointer-ios-debug.patch` was useful for this diagnosis but is intentionally **not** in the default integration stack now. Keep it as an opt-in diagnostic patch if pick/focus regresses.

## 2026-07-01 Xwayland smoke
- The earlier "no X display" observation was because `xwayland` was not installed on the device. Installed local packages: `xwayland_23.2.7`, `libxcvt0`, `libdrm2`, and rebuilt `libxshmfence1`.
- Fixed `linux-build/recipes/libxshmfence.mk`: the runtime package must ship both `libxshmfence.1.dylib` and its real target `libxshmfence.1.0.0.dylib`; previously it installed a dangling symlink and Xwayland failed dyld load.
- Started rootful Xwayland manually under Mutter:
  ```
  XDG_RUNTIME_DIR=/var/jb/tmp WAYLAND_DISPLAY=wayland-0 XWAYLAND_NO_GLAMOR=1 \
    Xwayland :1 -geometry 1080x810 -retro -noreset
  ```
  `-rootful` is not a valid flag in this build; rootful is the default.
- `/tmp/.X11-unix/X1` appeared, then `DISPLAY=:1 fluxbox` and `DISPLAY=:1 xterm ...` stayed alive. Mutter mapped the Xwayland root window through the same first-buffer visibility path (`W1 mapped=1 visible_to_compositor=1`).

## 2026-07-01 late socket/cursor validation
- Mutter now defaults its app-input socket to `/var/jb/tmp/mutter-input.sock` instead of the old generic `/var/jb/tmp/xios-input.sock`; the env override remains `XIOS_INPUT_SOCKET`.
- Rebuilt/deployed libmutter and Xios.app. `wayland/run-mutter.sh` now advertises:
  ```
  "socket":"/var/jb/tmp/mutter-ddx.sock","input_socket":"/var/jb/tmp/mutter-input.sock"
  ```
  and Xios reports:
  ```
  iosurface-zerocopy 2160x1620 [metal]
  input-connected mutter(wayland)
  ```
- Direct injection with `/var/jb/usr/local/bin/iosc-input-test --mutter -c 1080 810` connected to `/var/jb/tmp/mutter-input.sock`; Mutter logged the expected motion/button records.
- Cursor state: Mutter uses a no-paint cursor renderer, `meta-input-ios.c` emits `xios_notify_cursor()` on app-input motion, and Xios draws the present-side overlay for `compositor_id=mutter-ios`. This removes the big stuck compositor cursor and leaves the right-sized moving cursor.
- Raw dylib smoke deploys no longer need ad-hoc postprocess commands: use `linux-build/tools/postprocess-mutter-dylib.sh <libmutter-14.0.dylib>`. The real package path already does the same libgtkintl rewrite + X11/XCB weak-link pass in `linux-build/recipes/mutter.mk`.
- Coexistence framing: separate sockets are correct (`mutter-ddx.sock`/`mutter-input.sock` vs `iosc-ddx.sock`/`iosc-input.sock`), but not sufficient for both compositors to be "live" in the app. `/var/jb/tmp/xios.json` is still the single active-display pointer; whichever compositor last writes it wins the Xios view. During testing, `xios-sessiond` resurfaced and restarted iosc, which overwrote the app view even though Mutter's sockets were distinct. True coexistence needs an active-display/session selection layer (and separate Wayland display names if both compositors run at once), not just unique socket names.

## 2026-07-01 packaged/session validation
- Built a clean non-debug Mutter package from the default patch stack (`MUTTER_CLEAN=1 TARGETS="mutter mutter-package"`). The default stack includes `meta-wayland-xdg-first-buffer-showing.patch` and intentionally does **not** apply `meta-wayland-pointer-ios-debug.patch`.
- Fresh packages:
  ```
  linux-build/out/libmutter-14-0_46.0_iphoneos-arm64.deb
  linux-build/out/libmutter-14-dev_46.0_iphoneos-arm64.deb
  ```
  They were also copied into `repo/debs/`.
- Installed on-device over the raw/debug dylib, together with `xios-session_1.0.4`. `dpkg -s` reports `xios-session 1.0.4` and `libmutter-14-0 46.0`.
- Re-launched via the session path:
  ```
  /var/jb/usr/local/bin/xios-session mutter
  ```
  Result: `xios.json` stayed on `2160x1620`, `socket=/var/jb/tmp/mutter-ddx.sock`, `input_socket=/var/jb/tmp/mutter-input.sock`, active owner file contains `mutter`, and Xios status is `input-connected mutter(wayland)`.
- Deployed `mutter-pointer-test` to `/var/jb/usr/local/bin` and verified app-bypass client dispatch:
  ```
  XDG_RUNTIME_DIR=/var/jb/tmp WAYLAND_DISPLAY=wayland-0 mutter-pointer-test
  iosc-input-test --mutter -c 540 405
  ```
  The probe logged `ENTER`, `MOTION`, and `BUTTON`, and wrote `/var/jb/tmp/mutter-pointer-hit`.
- Confirmed the packaged library/logs are clean of the opt-in pointer debug patch: `strings /var/jb/usr/lib/libmutter-14.0.dylib` and `/var/jb/tmp/mutter.log` contain no `MetaWaylandPointerIOS`.
- Active-display ownership guard validated: direct classic `/var/jb/usr/local/bin/iosc` while active owner is `mutter` exits 2 with `iosc: refusing classic output because active session is mutter`, and leaves Mutter's `xios.json` unchanged.

## Open items
1. **Regression test (run when Mutter is up + Max is at a stopping point — do NOT inject into a live session Max is driving without asking):** inject KNOWN output-px directly into the input socket (bypass the app) to isolate app-coords vs dispatch:
   ```
   iosc-input-test --mutter -c 1080 810
   # or, from a host without the rebuilt tester installed yet:
   python3 -c "import socket,struct,time; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('/var/jb/tmp/mutter-input.sock'); \
     s.send(struct.pack('<IiiIII',1,1080,810,0,0,0)); time.sleep(.1); \
     s.send(struct.pack('<IiiIII',2,0,0,0,1,0)); time.sleep(.05); s.send(struct.pack('<IiiIII',2,0,0,0,0,0))"
   ```
   `iosc-input-test` now auto-detects `/var/jb/tmp/mutter-input.sock` (Mutter), then the legacy `/var/jb/tmp/xios-input.sock`, before `/var/jb/tmp/iosc-input.sock` (iosc), and also accepts `--mutter`, `--iosc`, or `--socket PATH` for explicit routing.
   Then read `/var/jb/tmp/mutter.log` for `MetaInputIOS: motion out(X,Y)/WxH -> stage(x,y) in WxH`. EXPECT W×H = 2160×1620 and stage == out (identity, since mutter's fb == screen). For the purpose-built probe, expect `/var/jb/tmp/mutter-pointer-hit` plus `ENTER/MOTION/BUTTON` in `/var/jb/tmp/mutter-pointer-test.log`.
   NOTE the input socket path should be `mutter-input.sock` (mutter), not `iosc-input.sock` (iosc). If an old local build is still installed it may advertise the legacy `xios-input.sock`; use the tester's printed `connected to ...` line to confirm it.
2. **App-coord fix keys off xios.json per-compositor size** (guardrail): mutter advertises 2160×1620 → app fit scale = 1.0 (identity), so coords line straight through. The xios-app fix must use xios.json's advertised fb, never a constant (it does). Confirmed aligned with xios-app + team-lead.
3. Xwayland rootful works as a manual smoke. Next packaging pass should reinstall the rebuilt `libxshmfence1` deb wherever the old broken one was published, and `run-xwayland.sh` now omits the invalid `-rootful` flag.
4. Session coexistence is partially handled by active ownership now: distinct sockets plus `/var/jb/tmp/xios-active-session` prevent direct classic iosc from stealing the app view while Mutter owns the session. Longer term, `/var/jb/tmp/xios.json` should become an explicit active-display selection/registry so multiple compositors can be alive and switchable instead of last-writer-wins.

## Note
GNOME Shell inherits this path because it is the same MetaBackendIOS and xdg-shell window mapping logic.
