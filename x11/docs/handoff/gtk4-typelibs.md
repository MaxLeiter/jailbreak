# gtk4-typelibs — on-device GObject-Introspection (the last GNOME boot gate)

## Ownership
Producing the GIR typelibs GNOME Shell + gjs need, by running g-ir-scanner ON THE iPad (Procursus native toolchain — NOT qemu; that was Blocker #2, solved). This is the last prep before GNOME Shell can boot (see gnome-session.md).

## Key files / approach
- On-device scanner scripts: `x11/apps/*/gir-build-*-ondevice.sh` (each lib scanned via its own meson/build using the native toolchain). Trick: harvest the exact g-ir-scanner command lines via an off-device introspection config, then run them on-device.
- The 5-script closure-FIRST batch:
  1. `gir-build-shell-closure-ondevice.sh <gsettings-desktop-schemas tar>`
  2. `gir-build-mutter-ondevice.sh`
  3. `gir-build-gnome-shell-ondevice.sh <gnome-shell tar>`
  4. `gir-build-accountsservice-ondevice.sh <tar>`
  5. `gir-build-session-libs-ondevice.sh`
- The 15 GIR -dev debs (libmutter-14-dev, libgjs-dev, libaccountsservice-dev, libgdm-dev, libupower-glib-dev, libgeocode-glib-2-dev, libgweather-4-dev, libgeoclue-dev, libatk1.0-dev, at-spi2-core-dev, gcr4-dev, polkit-dev, libibus-dev, libgnome-desktop-dev, p11-kit-1-dev) were `dpkg -i`'d for the headers. Scans only need the unpacked headers/.pc, not full config.

## Current state — checked 2026-07-01 23:55 PDT
- Phase 2 is complete on the device. The boot-critical typelibs are installed in `/var/jb/usr/lib/girepository-1.0` and import under gjs with:
  - `DYLD_LIBRARY_PATH=/var/jb/usr/lib:/var/jb/usr/lib/gnome-shell:/var/jb/usr/lib/mutter-14:/var/jb/lib/angle`
  - `GI_TYPELIB_PATH=/var/jb/usr/lib/girepository-1.0:/var/jb/usr/lib/mutter-14`
- Passing namespaces: `Meta-14`, `Clutter-14`, `St-14`, `Shell-14`, `Gvc-1.0`, `Shew-0`, `AccountsService-1.0`, `Gdm-1.0`, `UPowerGlib-1.0`, `GWeather-4.0`, `Geoclue-2.0`, `Gcr-4`, `PolkitAgent-1.0`, `GnomeDesktop-4.0`, `GnomeBG-4.0`, `IBus-1.0`, `Atspi-2.0`, `Atk-1.0`.
- `gir-build-mutter-ondevice.sh` now stages the Linux input shim and scan-local linker symlinks needed for `Meta-14` (`libpixman-1`, `libcolord`, `libICE`, `libX11-xcb`).
- `gir-build-gnome-shell-ondevice.sh` validation now includes `/var/jb/usr/lib/gnome-shell`, `/var/jb/usr/lib/mutter-14`, and ANGLE in `DYLD_LIBRARY_PATH`.
- `gnome-shell-ios-fixes.sh` disables the ATK bridge link on iOS because the current `libatk-bridge2.0-0 2.52.0` expects ATK 2.52 document symbols and the installed standalone ATK is 2.38.

## Open items
1. Hand to gnome-session for Phase 3 (`run-gnome-shell.sh`). That launch stops the current iosc compositor/session, so coordinate the device first.
2. Longer-term packaging cleanup: align ATK/at-spi versions or package an ATK 2.52-compatible runtime before re-enabling `atk-bridge-2.0`.

## Prior gotchas (from the introspection track)
- Missing on-device dev metadata/packages encountered and installed/staged during this pass: `libgjs-dev`, `libstartup-notification-dev` (installed with `--force-overwrite` because the dev/runtime packages both ship the unversioned dylib link), `libpulse-dev`, `perl`, `libp11-kit-dev`, `libsoup-3.0-dev`, `libpsl-dev`, DBus headers from the matching 1.14.10 source tarball, and the local Wayland/DRM/X11 dev packages needed by the Mutter scan.
- mozjs-115-dev deb was dangling symlinks + no .pc (synthesized). ibus compose-table needs a host tool; glib-compile-resources was a cross wall (solved by scanning on-device). gtk4 typelibs (Gtk-4.0/Gdk/Gsk/Pango) already scanned natively via each lib's meson (gir-build-ondevice.sh) — a gjs GTK4 window renders under Xvfb.

## Verify
Device is free for gir (CPU/build only). SSH per INDEX.md.
