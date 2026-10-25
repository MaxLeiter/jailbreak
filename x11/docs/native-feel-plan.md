# Native-feel bundle: rotation, volume, dark mode, haptics, brightness

Small system-integration features that make the desktop feel like it belongs on
the iPad.

**Status (2026-10-25): all landed.** This used to be a set of per-owner patch kits;
they are all in the tree now, so the kits are gone and this file describes what
was built. Current status and what still needs a human on the device:
`handoff/polish.md`.

## Pieces

| Feature | Record (`apps/shared/XiosProtocol.h`) | Where |
|---|---|---|
| Rotation | `XIOS_IN_OUTPUT` | app `SystemIntegration.swift`; iosc output resize; `xios_surface_resize` in `linux-build/patches/xios/xios_surface.c`; `iosc_gl_resize()` in `wayland/iosc_gl.c` |
| Haptics | `XIOS_IN_HAPTIC` | iosc `input_clients_send_haptic()` on pointer/touch down over layer UI; app fires UIKit feedback (`rightClickHaptic()` for the long-press right-click) |
| Volume | `XIOS_IN_VOLUME` | `wayland/xios-sysintd.c` and the app's hidden `MPVolumeView` |
| Dark mode | `XIOS_IN_APPEARANCE` | `xios-sysintd` |
| Brightness | `XIOS_IN_BRIGHTNESS` | `xios-hwbridged` to `xios-sysintd` to the app's `UIScreen.brightness` |

All of these are 32-byte `xios_msg` records. The old numbering (types 10 to 13 in
`xios_input_socket.h`) is gone; that header now includes `XiosProtocol.h`.

## How rotation works

UIKit rotates the app's scene, so the drawable is always upright; rotation for the
desktop is a resize plus metadata. The app sends the interface orientation as
`XIOS_IN_OUTPUT` (transform 0/1/3; both landscapes count as normal because the
launch shape is landscape), on orientation and layout changes and again after
every adopt, so a compositor restart in the same orientation still converges.
iosc swaps its launch logical size on quarter-turns, reallocates the output
IOSurface, rebinds GL, re-advertises `wl_output`/`xdg_output`, re-lays-out layer
chrome and toplevels, and drops present clients. The app's normal
teardown/reconnect path adopts the new surface and input follows the new
framebuffer size. There is no pixel rotation in the compositor.

`wl_output` semantics are wlroots-style: with a transform advertised, `mode` stays
the untransformed landscape pixels and clients derive logical size from transform
and scale; `xdg_output` sends the post-transform logical size. Escape hatch:
`IOSC_NO_OUTPUT_TRANSFORM=1` advertises NORMAL with the real buffer size (a pure
resize), in case a client pre-rotates buffers with `set_buffer_transform` (iosc
ignores that request; GTK, Qt and SDL do not use it).

The app allows all orientations only while it is attached to iosc
(`allowsAllOrientations`); other backends stay landscape.

## xios-sysintd

- Ships in `xios-session-stubs` (`/var/jb/usr/libexec/xios-sysintd`) and is
  started per session bus by the session launcher and by ioscd; see
  `handoff/session-launcher.md`.
- VOLUME from the app runs `pactl set-sink-volume` on sink `xios` (override
  `XIOS_SYSINT_SINK`); a desktop-side volume change is broadcast back so the app
  sets iOS hardware volume. iOS volume still scales the RemoteIO output, so the
  effective curve is roughly v squared. Fine so far.
- APPEARANCE writes `color-scheme` (prefer-dark / prefer-light) and, unless
  `XIOS_SYSINT_NO_GTK3=1`, `gtk-theme` Adwaita / Adwaita-dark (override with
  `XIOS_SYSINT_GTK3_LIGHT` / `_DARK`). These are user-level dconf writes, so they
  win over the packaged gschema override the way a user toggle would.
- BRIGHTNESS is a pure relay from `xios-hwbridged` to the app, because only an app
  process can move the panel (`BKSDisplayBrightnessSet` is inert from a daemon on
  iPadOS 17.6.1). Details: `xios-fhs-plan.md`.

## Validation checklist (on device)

1. Rotate to portrait: the desktop re-lays-out at 1080x1440 logical, the panel
   re-anchors, a maximized Console refits, `wayland-info` shows transform 1 and the
   swapped logical size. Tap the panel clock corner to check touch accuracy.
   (Done 2026-07-04 on iosc.)
2. Rotate back and forth five times quickly: watch iosc RSS for a leak and check
   no present client gets stuck.
3. Volume buttons: `pactl get-sink-volume xios` tracks and the GNOME slider moves.
4. iOS dark mode toggle: a GTK4 app flips (libadwaita) and a GTK3 app flips theme.
5. Panel tap gives a light impact, long-press right-click a medium one (the iPad 7
   has no Taptic Engine, so this needs other hardware to feel).
6. `IOSC_NO_OUTPUT_TRANSFORM=1` if any client renders sideways.
