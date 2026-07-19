# XFCE desktop port

## Ownership

The legacy/lightweight X11 XFCE flavor: build the existing 4.16 recipe chain,
package it reproducibly, add a supported session launcher, and validate it under
Xios/Xwayland. This is distinct from the iosc shell and is not yet one of the
four product flavors advertised by the session picker.

## Current state — audited 2026-07-18

- GTK3 3.24.38+ios2, D-Bus, X11 libraries, startup-notification, libepoxy, and
  the other shared prerequisites exist. The old “blocked on GTK3” comments were
  stale and have been removed.
- Recipes and control templates exist for the full 4.16 chain, but no XFCE deb
  is currently present in `linux-build/out` or the published repo.
- `linux-build/build-xfce.sh` now owns the reproducible build order, cross
  compiler wrapper, control staging, artifact collection, and libgtkintl pass.
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

1. Run the foundation build after Docker recovers; fix source portability walls
   as proper `ports/<pkg>/patches/series` stacks.
2. Build/package the complete chain and audit dependencies/install names.
3. Add a package-owned rootless session runner through `xios-session`; retire
   or rewrite the legacy `bin/xfce-up.sh` path.
4. Device smoke: session reaches `up`, panel/desktop/window manager render,
   appfinder launches an app, and input/resize work. Device is currently offline.
