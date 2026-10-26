# Handoff: XFCE

Last checked against `repo/Packages`: 2026-10-25.

## Current state

Only Thunar ships. XFCE is not a session flavor and the picker does not offer
it.

Published:

- `thunar 4.16.11+ios1`, with `libxfce4util7 4.16.0+ios1`, `xfconf 4.16.0+ios1`,
  `libxfce4ui-2-0 4.16.0+ios1` and `libexo-2-0 4.16.4+ios1`.
- `libstartup-notification0 0.12+ios2`.

Thunar runs as a Wayland client in classic iosc and as a native iPad window
(`com.max.iosc.thunar`, label "Thunar"). Its postinst refreshes the icon and
desktop caches and creates the native launcher. In native mode each window has
its own canvas, so a global compositor screencopy can't cross-check it.

Not built: `libwnck3`, `garcon`, `xfwm4`, `xfdesktop`, `xfce4-panel`,
`xfce4-session`, `xfce4-settings`, `xfce4-appfinder`. The control-only `xfce4`
metapackage in `packages/xfce4/` depends on all of them, so it is not
installable yet and must not be published until they exist.

`bin/xfce-up.sh` brings XFCE components up on a rootful Xwayland that is
already running under iosc (`wayland/run-xwayland.sh`, display `:1`). It is a
bring-up script, not a session runner.

## Remaining gates

1. Build and package the rest of the desktop chain and audit dependencies and
   install names.
2. Add a package-owned session runner through `xios-session` (with a
   preflight entry in `xs_preset_check`, like the other flavors), and retire or
   rewrite `bin/xfce-up.sh`.
3. Device smoke: the session reaches `up`, panel, desktop and WM render,
   appfinder launches an app, input and resize work.

## Port notes

- `linux-build/build-xfce.sh` owns the build order, the cross compiler wrapper,
  source-patch staging, the build-sysroot `libgtkintl` bridge, scoped artifact
  collection, and the final shared `libgtkintl` relink. Use a narrow `TARGETS`
  prefix for the first compiler probe of a new component.
- Build order: (1) `dbus`, `libxfce4util`, `xfconf`; (2) `libwnck3`,
  `libxfce4ui`, `exo`, `garcon`; (3) `thunar`, `xfwm4`, `xfdesktop`,
  `xfce4-panel`, `xfce4-session`, `xfce4-settings`, `xfce4-appfinder`.
- XFCE stays on 4.16: it is autotools and GTK3 throughout. 4.18 pulls in
  `libxfce4windowing` and more meson; 4.20 is meson everywhere.
- The three non-XFCE dependencies are D-Bus (xfconfd is a session-bus
  service), `libwnck3` (xfwm4, panel pager/tasklist), and startup-notification.
  Linux-only bits (udev/gudev, logind, upower, polkit) are optional configure
  checks that turn off when the `.pc` is missing, so Thunar browses local files
  only and has no removable-media mounting.
- xfconfd is D-Bus-activated from `$XDG_DATA_DIRS/dbus-1/services`, so
  `XDG_DATA_DIRS` must include `/var/jb/usr/share` or settings won't persist.

## Things to decide before the full desktop

- **Rootful or rootless X.** xfwm4 wants to own the X screen. Under iosc's
  rootless XWM (built in since iosc 0.9.51) the XWM already owns `WM_S0`, so a
  full XFCE desktop most likely needs its own rootful Xwayland, which is what
  `xfce-up.sh` assumes. Not tested either way.
- **Display numbers.** `run-xwayland.sh` and `xfce-up.sh` hardcode `:1`. iosc
  0.9.51 now picks an X display per slot (`:0`, then `:1` for a second slot),
  so a second desktop slot and the rootful harness can collide.
- xfwm4's compositor should start disabled; turn it on only once it is proven.

## History

The original plan (2026-07-03) targeted the retired software Xios X server on
`DISPLAY=:3`. Thunar and its libraries were built, device-tested in slot
`codexthunar`, and published on 2026-07-29.
