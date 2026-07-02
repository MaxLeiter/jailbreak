# native-ipados — the native per-window iPad flavor

## Ownership
The flavor where each Linux app is its own native iPad window (per-window presentation), instead of one full-desktop canvas. A macOS-style window manager feel on iPadOS. Task #28.

## Key files
- `x11/apps/iosc-host/` — HostApp.swift, HostScreenView.swift, NativeClient.c, Shaders.metal → builds to `out/IOSCHost` (protocol-conformant prototype).
- `x11/wayland/xios_canvas.{c,h}` — N-canvas registry + `iosc-native.sock` BIND server + `deliver_canvas_port`.
- `x11/wayland/iosc.c` — runtime-gated native mode (`IOSC_NATIVE=1` or `-native`) that maps each xdg_toplevel to its own canvas while keeping classic mode available in the same binary.
- Design: `x11/docs/native-ipados-plan.md` (§7b scopes per-window presentation), `x11/docs/native-ipados-protocol.md`.
- Wire: XIOS_IN_BIND=8 (scope a connection's input to one window id) — already reserved in xios_input_socket.h; IoscInput.c had 8 on-wire before the header did.

## Current state
- HostApp prototype builds + is protocol-conformant (engine verified earlier; awaiting a visual on-device confirm).
- The native host now replays the latest Wayland text-input TRAITS on scene activation/key-window activation and on tap, so the iPad keyboard can rise after the per-window host becomes the active UIKit scene.
- `xios_canvas.c` is implemented on the non-frozen side and retains enough window metadata to replay `WINDOW_NEW` + canvas ports when a host binds after a window already exists (jetsam/relaunch path).
- `iosc_gl_bind_target()` is factored out of `iosc_gl_resize()`; the compositor build includes `xios_canvas.c` so it stays compile-checked.
- `iosc.c` native mode now starts `iosc-native.sock`, creates/destroys per-window canvases on toplevel map/unmap, composites each toplevel into its own IOSurface, and handles host resize/activate/close requests on the Wayland event loop.
- `XIOS_IN_BIND` is honored by the shared input reader + iosc's bound-aware dispatch path: host scene input connections can now be scoped to a compositor window id, including native-mode keyboard TRAITS broadcasts for the focused window.
- Native launch is now explicit per request: iosc-host sends `LAUNCH_NATIVE`, and ioscd starts a native compositor namespace on `wayland-native-0` + `iosc-native-input.sock` + `xios-native.json`. Classic launchers keep `wayland-0` + `iosc-input.sock`, so native wrapped apps and the classic Xios desktop can coexist on the same device.
- Standalone compositor deploys need host-side signing after `build-iosc.sh`: `wayland/sign-iosc.sh wayland/out/iosc`. This keeps the GPU/IOSurface/task_for_pid entitlements DER-signed before the binary is copied to a device.

## Open items
1. On-device demo (per-window presentation): `gen-launchers.sh --native`, tap a generated app, confirm it opens as its own iPad window, resizes, focuses, accepts text, and closes cleanly.
2. Coexistence smoke: keep a classic Xios desktop up, tap a native generated app, and confirm both compositor sockets stay live.
3. **Touch coordinate transform per-window**: verify the host unprojects touches against the canvas's own fb size for every scene.
4. Validate jetsam/relaunch replay: open a native-hosted app, kill/relaunch the host, confirm `WINDOW_NEW` + the live canvas port are replayed from `xios_canvas.c`.
5. Confirm the keyboard hint path on device: focus a GTK/Qt text field inside a native-hosted window and verify the OSK appears when that scene is key.
6. Decide whether native mode should keep the classic output IOSurface for tooling/fallback or skip it later to save memory.

## Priority
Ready for device validation.
