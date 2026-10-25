# Megafile refactor plan (queued, not started)

Status 2026-10-25: not done. The two big files have grown since this was written
(July 2026): `x11/wayland/iosc.c` is about 7,500 lines and
`x11/apps/Xios/Sources/XScreen.swift` about 5,300. Some concerns have been split
out along the way (`iosc_gl.c`, `iosc_input.c`, `iosc_text_input.c`,
`iosc_foreign_toplevel.c`, `iosc_xwm.c`, `iosc_kde_output.c`, the `xios_*.c`
glue), which is the precedent to follow.

The rule: behavior-preserving moves only. Cut code into a new `.c`/`.h` and wire
the includes, no logic change. Build green and commit per module. Don't run it
while someone else is editing the target file.

Out of scope: generated `*-protocol.c/.h` (wayland-scanner output) and anything
vendored.

## iosc.c split

Target a core under ~800 lines plus focused modules. Read the file for the real
section boundaries first; the proposed cut by concern:

- `iosc.c`: `main()`, wl_display and event-loop setup, the globals registry,
  top-level orchestration.
- `iosc_surface.c/.h`: `struct iosc_surface` lifecycle, roles, stacking bands,
  work area and exclusive zones, commit/damage, cascade/maximize/fullscreen
  geometry.
- `iosc_xdg.c`: xdg_wm_base, xdg_surface, xdg_toplevel and xdg_popup handlers.
- `iosc_layer_shell.c`: zwlr_layer_shell_v1 and its surfaces (anchor, exclusive
  zone, keyboard interactivity, the no-buffer, configure, ack, map handshake).
- `iosc_seat.c`: wl_seat, pointer, keyboard and focus.
- `iosc_cursor.c`: the cursor surface and its composite.

Split along protocol-handler versus render boundaries; rendering stays in
`iosc_gl.c`.

## XScreen.swift split

Probably moot: the Xios v2 app rewrite (unmerged, `claude/xios-v2-app` branch) removes
`XScreen.swift` and splits the app into modules. Only do this if that rewrite is
dropped. The original cut:

- `XScreen.swift`: the UIView / CAMetalLayer core and lifecycle.
- `XScreenPresent.swift`: IOSurface adoption and the Metal draw.
- `XScreenInput.swift`: touch, pencil and keyboard to the input socket.

## How to run it

iosc.c is the hottest file in the tree, so announce a freeze before splitting it
and give it its own agent. Each refactor: read the file, mark boundaries, move one
concern at a time, build (`wayland/build-iosc.sh` or the Xios app build), commit.
The built binary must behave identically.
