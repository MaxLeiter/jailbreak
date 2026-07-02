# iosc-compositor — the iosc Wayland compositor + wire protocol

## Ownership
`iosc` — the clean-room pure-C libwayland-server compositor that composites clients into an IOSurface for the Xios app to present. Owns the wire protocol between compositor and the Xios app (input, present/DIRTY, clipboard, cursor). NOTE: iosc.c is under a FREEZE (monolith → modules refactor pending); non-trivial changes are lead-gated.

## Key files
- `x11/wayland/iosc.c` — the compositor (monolithic; freeze). `out/iosc` binary → `/var/jb/usr/local/bin/iosc`.
- `x11/wayland/xios_input_socket.{h,c}` — the 24-byte input wire (shared by iosc AND mutter's MetaBackendIOS). Types: 1 MOTION, 2 BUTTON, 3 KEY, 4 TEXT, 5 TRAITS(→client OSK), 6 TOUCH, 7 TABLET/Pencil, 8 BIND(per-window native), 9 AXIS(scroll), 10 OUTPUT(rotation), 11 HAPTIC, 12 VOLUME, 13 APPEARANCE. x,y = absolute OUTPUT-pixel.
- `x11/wayland/xios_surface.{c,h}` — the DDX present side (IOSurface, typed HELLO/DIRTY/CURSOR framing).
- `x11/wayland/xios.json` contract: `{width,height,stride,format:BGRA,ddx:"iosurface",socket:<ddx>,input_socket:<path>,display}`.
- Run: `run-shell.sh` (iosc + ioscbg + ioscbar + ioscdock), `run-kgx.sh` (a client).

## Current state
- iosc composites at logical N×M with 2× supersample → output IOSurface = 2N×2M (e.g. `-logical 1600x1200` → 3200×2400). Default in run-shell.sh is 1440×1080.
- Input path PROVEN correct on-device: `surface_at()` pick is role-agnostic (delivers wl_pointer + wl_touch to layer surfaces too, not just toplevels); `handle_motion`/`handle_button`/`handle_touch` route to the hit surface's client; `iosc_input_record` divides output-px by `output_scale` ONCE (`iosc.c:4922-4923`) — no double-divide. Injected known-coord taps land dead-on.
- Layer-surface translucency (alpha blend) needs iosc ≥ 0.9.1 (commit e11aa52); deployed iosc has it.
- Cursor overlay + typed HELLO/DIRTY/CURSOR framing landed. AXIS scroll wire + touch (type 6) + tablet/Pencil (type 7) wire decode landed (3ebf085). The Xios app halves also landed (`sendScroll`/`iosc_input_touch`/`iosc_input_tablet`, 9470335) — both sides are in, not pending.

## Known compositor-side issues
1. **Zombie surfaces**: iosc appears to keep compositing a surface after its client dies (restarting a shell client many times stacks stale panels visible over the live one). WORTH INVESTIGATING: does iosc destroy client surfaces on wl_client disconnect? If not, that's a resource leak + the zombie-panel cause. Workaround today = restart iosc to clear all surfaces.
2. `iosc.c` is frozen pending a monolith→modules refactor. The clipboard hooks (XIOS_MSG_CLIPBOARD 0x04) are freeze-gated behind that refactor. AXIS was un-frozen as a one-off because it was contained.

## Open items
1. Investigate/fix the dead-client surface cleanup (zombie surfaces).
2. Support native-ipados: the XIOS_IN_BIND=8 path + a per-window canvas registry — native-ipados needs the refactor-boundary answer (which parts are non-frozen). See native-ipados.md.
3. Rotation (XIOS_IN_OUTPUT=10): reconfigure the output IOSurface on device rotation (paired with xios-app's drawable update). See polish.md #21.
4. Un-freeze plan: the monolith→modules refactor unblocks clipboard + native-per-window cleanly.

## Verify
`/var/jb/tmp/iosc.log` (logical/output/clients), shell stderr logs (with IOSC_SHELL_DEBUG=1). Input socket is `/var/jb/tmp/iosc-input.sock` for iosc.
