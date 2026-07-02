# native-ipados — the native per-window iPad flavor

## Ownership
The flavor where each Linux app is its own native iPad window (per-window presentation), instead of one full-desktop canvas. A macOS-style window manager feel on iPadOS. Task #28.

## Key files
- `x11/apps/iosc-host/` — HostApp.swift, HostScreenView.swift, NativeClient.c, Shaders.metal → builds to `out/IOSCHost` (protocol-conformant prototype).
- `x11/wayland/xios_canvas.{c,h}` — N-canvas registry + `iosc-native.sock` BIND server + `deliver_canvas_port`. Touches NO iosc.c (the non-frozen pieces).
- Design: `x11/docs/native-ipados-plan.md` (§7b scopes per-window presentation), `x11/docs/native-ipados-protocol.md` (v1.1).
- Wire: XIOS_IN_BIND=8 (scope a connection's input to one window id) — already reserved in xios_input_socket.h; IoscInput.c had 8 on-wire before the header did.

## Current state
- HostApp prototype builds + is protocol-conformant (engine verified earlier; awaiting a visual on-device confirm).
- `xios_canvas.c` is implemented on the non-frozen side and retains enough window metadata to replay `WINDOW_NEW` + canvas ports when a host binds after a window already exists (jetsam/relaunch path).
- `iosc_gl_bind_target()` is factored out of `iosc_gl_resize()`; the compositor build includes `xios_canvas.c` so it stays compile-checked.
- `XIOS_IN_BIND` is honored by the shared input reader + iosc's bound-aware dispatch path: host scene input connections can now be scoped to a compositor window id.
- Blocked on iosc-compositor for: the refactor-boundary and the frozen `iosc.c` wiring for map/unmap canvas lifecycle and per-window recomposite.

## Open items
1. Compile-check the updated compositor build in the Procursus cross-build image and fix any iOS-SDK portability fallout.
2. Coordinate with iosc-compositor on the refactor boundary + the frozen `iosc.c` half: map/unmap canvas lifecycle and per-window recomposite.
3. **Reuse the shared infra proven on iosc**: IOSurface mach-port handoff, the input socket, and the aspect-fit present. Your per-window mode binds N surfaces to N iPad windows over the same handoff.
4. **Touch coordinate transform per-window**: the same fix xios-app just landed (unproject a touch through the aspect-fit into fb pixels, keyed off the canvas's own fb size — NOT a constant) must apply PER-WINDOW. Coordinate with xios-app on the transform.
5. On-device demo (per-window presentation).

## Priority
Background — GNOME/iosc are the active demos. No device time needed yet; build + coordinate.
