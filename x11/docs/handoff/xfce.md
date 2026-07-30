# XFCE desktop port

## Ownership

The legacy/lightweight X11 XFCE flavor: build the existing 4.16 recipe chain,
package it reproducibly, add a supported session launcher, and validate it under
Xios/Xwayland. This is distinct from the iosc shell and is not yet one of the
four product flavors advertised by the session picker.

## Current state — Thunar shipped 2026-07-29

- GTK3 3.24.38+ios2, D-Bus, X11 libraries, startup-notification, libepoxy, and
  the other shared prerequisites exist.
- The focused Thunar chain now builds and packages as
  `libxfce4util7 4.16.0+ios1`, `xfconf 4.16.0+ios1`,
  `libxfce4ui-2-0 4.16.0+ios1`, `libexo-2-0 4.16.4+ios1`, and
  `thunar 4.16.11+ios1`.
- `linux-build/build-xfce.sh` owns the reproducible build order, cross compiler
  wrapper, source-patch staging, build-sysroot `libgtkintl` bridge, scoped
  artifact collection, and final shared `libgtkintl` relink pass.
- The package layout is rootless `/var/jb`, Thunar's post-install updates icon
  and desktop caches and creates a native launcher, and the app label is the
  concise `Thunar` in both desktop and SpringBoard modes.
- Device proof on 2026-07-29 installed the five packages, rendered the
  `/var/mobile` window in isolated classic slot `codexthunar`, and mapped a
  native Thunar window after `IOSCHost` bound app id `thunar`. The native path
  uses per-window canvases, so global compositor screencopy is not a visual
  cross-check for that mode.
- Production publication completed on 2026-07-29 after the scoped index passed
  dependency resolution and repo audit. The exact public bytes were streamed
  back from `repo.maxleiter.com`, hash-matched to `repo/debs`, and reinstalled
  on the iPad. Final SHA256s are `4229b960…2c84f` (`libxfce4util7`),
  `84b82139…eee79` (`xfconf`), `893dcd0f…adc587` (`libxfce4ui-2-0`),
  `37d6ec28…707e3` (`libexo-2-0`), and `b87bdd19…6c664` (`thunar`).
  SpringBoard registration is `Thunar` / `com.max.iosc.thunar`; a final launch
  left both `IOSCHost` and the mobile-owned `thunar` process live.
- `packages/xfce4` and `bin/xfce-up.sh` predate the current session-launcher
  architecture. Do not advertise XFCE in the picker until the packages build
  and a rootless `xios-session` runner has been added.

## Build order

1. Foundation: `dbus`, `libxfce4util`, `xfconf`.
2. Toolkit/window helpers: `libwnck3`, `libxfce4ui`, `exo`, `garcon`.
3. Desktop: `thunar`, `xfwm4`, `xfdesktop`, `xfce4-panel`, `xfce4-session`,
   `xfce4-settings`, `xfce4-appfinder`.

Use a narrow `TARGETS` prefix for the first compiler probe. The full driver
defaults to the complete order once each prefix is green.

## Remaining gates

1. Build/package the remaining complete-desktop chain and audit dependencies
   and install names.
2. Add a package-owned rootless session runner through `xios-session`; retire
   or rewrite the legacy `bin/xfce-up.sh` path.
3. Device smoke the full desktop: session reaches `up`,
   panel/desktop/window-manager render, appfinder launches an app, and
   input/resize work.
