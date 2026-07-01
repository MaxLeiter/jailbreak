# Megafile Refactor Plan (QUEUED — run after the parallel dev tracks settle)

Purpose: split our oversized source files into cohesive modules. Behavior-preserving
moves only (cut code to a new .c/.h + wire includes; NO logic change). Build green and
commit per file. Do NOT run while agents are actively editing the target file.

## Scope — what counts
Only OUR source > ~500 lines. EXCLUDE vendored/third-party entirely (do not touch):
- `x11/apps/Xios/xlib/include/X11/**` — upstream X11 headers + Xtrans (`Xlib.h` 4025,
  `Intrinsic.h`, `keysymdef.h`, `Xproto.h`, `Xtranssock.c`, `Xtranslcl.c`, `Xtrans.c`, …).
  These are imported X11, not our code.
- Generated `*-protocol.c/.h` (wayland-scanner output).

## Real candidates (our code)
1. `x11/wayland/iosc.c` — **4021 lines** — the compositor monolith. HOTTEST file
   (edited by iosc-input = panel/protocols, iosc-cursor = blend; mutter meta-*-ios do NOT
   touch it). Refactor LAST, behind a coordinated freeze.
2. `x11/apps/Xios/Sources/XScreen.swift` — **1676 lines** — Xios app screen/render/input.
   Lower contention; can go first.

(Note: iosc_gl.c, xios_egl.c, xios_surface.c, xios_input_socket.c already factored out of
the iosc.c/gl monolith by iosc-input's task-5 split — good precedent to follow.)

## iosc.c split (target: core < ~800 lines + focused modules)
Verify exact section boundaries by reading the file at run-time; proposed by concern:
- `iosc.c` — main(), wl_display + event-loop setup, globals registry, top-level orchestration.
- `iosc_surface.c/.h` — struct iosc_surface lifecycle, roles, stacking bands, work-area /
  exclusive-zone, commit/damage, cascade/maximize/fullscreen geometry.
- `iosc_xdg.c` — xdg_wm_base / xdg_surface / xdg_toplevel / xdg_popup handlers.
- `iosc_layer_shell.c` — zwlr_layer_shell_v1 + zwlr_layer_surface_v1 (anchor, exclusive-zone,
  keyboard-interactivity, the no-buffer→configure→ack→map handshake).
- `iosc_foreign_toplevel.c` — zwlr_foreign_toplevel_management_v1 (taskbar broadcast, handle
  activate/close/state).
- `iosc_seat.c` — wl_seat, pointer, keyboard, focus, text-input v3 / IME / virtual-keyboard.
- `iosc_cursor.c` — cursor surface + composite (the begin/end_cursor blend path).
Keep the split along protocol-handler vs render boundaries (render stays in iosc_gl.c).

## XScreen.swift split
Verify at run-time; proposed by concern:
- `XScreen.swift` — the UIView / CAMetalLayer core + lifecycle.
- `XScreenPresent.swift` — IOSurface adoption + Metal present/draw.
- `XScreenInput.swift` — touch / pencil / keyboard → the input socket (iosc / X) bridge.
- `XScreenX11.swift` — X11-specific attach logic, if present.

## Why LATER + coordination
- iosc.c is in active flux: iosc-input (panel, pending input-socket unification),
  iosc-cursor (blend fix). Refactoring now collides + invalidates their diffs.
- RUN the iosc.c split ONLY after: (a) iosc-input's panel + input-unification land;
  (b) iosc-cursor's blend fix lands + is on-device validated; (c) a "iosc.c freeze"
  is announced to the team so no one edits it mid-split.
- XScreen.swift is lower-contention — can be done sooner.

## How to run
When churn settles, spawn one refactor agent per file (iosc.c warrants its own). Each:
read the file, mark exact section boundaries, move each concern to its module + header,
wire includes, build green (build-iosc.sh / Xios app build), commit per module. Announce
+ hold the iosc.c freeze first. No behavior change — the built binary must behave identically.
