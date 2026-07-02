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
- **Dispatch machinery VERIFIED SOUND** (from Clutter source, not a guess): `_clutter_event_push` → `clutter_stage_pick_and_update_device` repicks the actor at the event coords + updates pointer focus → dispatches to the Wayland client, PROVIDED coords are correct + in-bounds. build10 makes motion coords correct + button-at-last-motion.
- **The "clicks don't dispatch" cause = the app-coord offset** (the same stale-scale bug fixed in xios-app a7da822): the app fed notify_absolute_motion the WRONG output-px → wrong pick → no activation. Mutter inherited it (same app, same socket). NOT the Clutter path.
- Max most recently: switched to Mutter via the picker, sees bg + cursor, but "mouse still doesn't work."

## 2026-07-01 follow-up
- Codex installed the staged `/var/jb/tmp/libmutter-b10.deb` on device; `/var/jb/usr/lib/libmutter-14.dylib` now contains the expected `MetaInputIOS: motion out(...) -> stage(...)` mapping diagnostic.
- Re-ran `wayland/run-mutter.sh`: Mutter started, Xios adopted the IOSurface, `/var/jb/tmp/xios.json` advertised `2160x1620` and `input_socket=/var/jb/tmp/xios-input.sock`.
- Direct injection with `/var/jb/usr/local/bin/iosc-input-test --mutter -c 1080 810` connected to `/var/jb/tmp/xios-input.sock` and logged:
  `motion out(1080,810)/2160x1620 -> stage(1080.0,810.0) in 2160x1620`.
  This proves the app-bypass socket path and Mutter ratio mapping are correct/identity for the center click.
- A quick `kgx` keyboard marker and `iosc-dnd-test --no-drag` pointer probe did not produce a positive client-dispatch marker before the session switched back to iosc; don't over-interpret that as a regression. The strong verified result is coordinate mapping + transport. If client dispatch still matters, restart Mutter with a purpose-built pointer logger and inspect pick/focus after `_clutter_event_push`.
- Device is currently back on iosc (`/var/jb/usr/local/bin/iosc -logical 1440x1080`, panel/bg running, Xios adopted `2880x2160`), not standalone Mutter.

## Open items
1. **THE test (run when Mutter is up + Max is at a stopping point — do NOT inject into a live session Max is driving without asking):** inject KNOWN output-px directly into the input socket (bypass the app) to isolate app-coords vs dispatch:
   ```
   iosc-input-test --mutter -c 1080 810
   # or, from a host without the rebuilt tester installed yet:
   python3 -c "import socket,struct,time; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect('/var/jb/tmp/xios-input.sock'); \
     s.send(struct.pack('<IiiIII',1,1080,810,0,0,0)); time.sleep(.1); \
     s.send(struct.pack('<IiiIII',2,0,0,0,1,0)); time.sleep(.05); s.send(struct.pack('<IiiIII',2,0,0,0,0,0))"
   ```
   `iosc-input-test` now auto-detects `/var/jb/tmp/xios-input.sock` (Mutter) before `/var/jb/tmp/iosc-input.sock` (iosc), and also accepts `--mutter`, `--iosc`, or `--socket PATH` for explicit routing.
   Then read `/var/jb/tmp/mutter.log` for `MetaInputIOS: motion out(X,Y)/WxH -> stage(x,y) in WxH`. EXPECT W×H = 2160×1620 and stage == out (identity, since mutter's fb == screen). If a widget activates → dispatch is DONE and it was the app-coord offset (now fixed). If not → it's still dispatch; add a post-dispatch seat-pointer query + instrument the pick.
   NOTE the input socket path may be `xios-input.sock` (mutter) not `iosc-input.sock` (iosc) — use the tester's printed `connected to ...` line to confirm it.
2. **App-coord fix keys off xios.json per-compositor size** (guardrail): mutter advertises 2160×1620 → app fit scale = 1.0 (identity), so coords line straight through. The xios-app fix must use xios.json's advertised fb, never a constant (it does). Confirmed aligned with xios-app + team-lead.
3. Once the click path is confirmed, GNOME Shell inherits it working (it's the same backend).

## Note
The input socket for mutter is a source of the "mouse doesn't work". The near-certain fix is already in xios-app (a7da822) — deploy that build, switch to mutter, then run the test above. Mutter dispatch itself needs no further change unless the isolation test says otherwise.
