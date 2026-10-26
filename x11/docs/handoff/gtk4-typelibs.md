# gtk4-typelibs: GObject-Introspection typelibs, scanned on the iPad

Owns producing the typelibs gjs and GNOME Shell load. Cross builds cannot run g-ir-scanner's dumper
for a Mach-O target, so the scans run on the iPad itself with the Procursus native toolchain (no
qemu). Background and the original reasoning are in [../gjs-plan.md](../gjs-plan.md).

## Current state

- Done and packaged. `xios-gnome-typelibs 0.2.0` ships the regenerated boot typelibs (43 files,
  including Atk, Atspi, Gck, Gcr, GnomeDesktop, GnomeBG, GnomeRR, GWeather, St-14, Shell-14 and
  Gdm-1.0) and is a dependency of `xios-gnome`. Data files those libraries need at runtime stay with
  their own packages (`Locations.bin` in `libgweather-4-0`, the login-screen schema in `libgdm1`).
- The GTK4 stack typelibs (Graphene, HarfBuzz, GdkPixbuf, Pango*, Gdk/Gsk/Gtk-4.0) and Adw-1 were
  scanned the same way; a gjs GTK4/libadwaita window renders. GLib/GObject/Gio come from the
  `gir1.2-glib-2.0` package built by gobject-introspection itself.
- Namespaces that import under gjs on device: Meta-14, Clutter-14, St-14, Shell-14, Gvc-1.0, Shew-0,
  AccountsService-1.0, Gdm-1.0, UPowerGlib-1.0, GWeather-4.0, Geoclue-2.0, Gcr-4, Gck-2,
  PolkitAgent-1.0, GnomeDesktop-4.0, GnomeBG-4.0, GnomeRR, IBus-1.0, Atspi-2.0, Atk-1.0.
- Runtime environment for a manual import test:
  `DYLD_LIBRARY_PATH=/var/jb/usr/lib:/var/jb/usr/lib/gnome-shell:/var/jb/usr/lib/mutter-14:/var/jb/lib/angle`
  and `GI_TYPELIB_PATH=/var/jb/usr/lib/girepository-1.0:/var/jb/usr/lib/mutter-14`.

## Open items

- Rebuilding the set is still a device job. Bump `xios-gnome-typelibs` when the captured set changes.
- `libatk1.0-0` is now 2.52, matching at-spi 2.52, so the ATK skew that forced the atk-bridge drop in
  gnome-shell is gone. Re-enabling atk-bridge is tracked in gnome-session.md.

## Scripts

All in `x11/linux-build/`:

- `gir-build-ondevice.sh <source.tar> [meson -D opts]`: build a library from source on the device
  with `-Dintrospection=enabled`, build only the typelib targets, install `.gir`/`.typelib`. This is
  the route that works; header scanning does not.
- `gir-build-lib-ondevice.sh`: the same for the Shell closure libraries.
- `gir-build-shell-closure-ondevice.sh`, `gir-build-mutter-ondevice.sh`,
  `gir-build-gnome-shell-ondevice.sh`, `gir-build-accountsservice-ondevice.sh`,
  `gir-build-gdm-ondevice.sh`, `gir-build-session-libs-ondevice.sh`.
- `gir-ondevice.sh` (bootstrap g-i on the device, plus a `scan` subcommand) and `gi-package.sh`.

## Landmines

- **Header scans produce empty stubs.** Scanning an umbrella header gives `Namespace is empty`;
  scanning every header hits `#error Only <x.h> can be included directly`. Build from source instead.
- **Scan against the real dependencies.** St-14/Shell-14 scanned against a stub Atk silently drop
  every method with an `Atk.*` parameter. Re-scan after a dependency typelib changes.
- **Match the installed ABI.** Atspi must be scanned `-Dx11=disabled` like the shipped library, and
  only `ONLY_TL=atspi/Atspi-2.0.typelib` (the bundled atk target links the wrong libatk). A typelib
  describes the installed library, so pango is scanned with CoreText off, as shipped.
- **Per-library flags that mattered:** Gcr 4.2.1 needs `gcrypt.h`/`gpg-error.h` at build time and an
  unversioned `libgcrypt.dylib` link; libgweather 4.4.2 needs its `modules:['gi']` dropped and
  `-Dalloca=__builtin_alloca`; gnome-desktop 44.1 lost its `(out)` annotations when header-scanned.
- **On-device build frictions:** set `DYLD_LIBRARY_PATH=/var/jb/usr/lib`; the device clang targets
  macOS by default, so wrap it with `-target arm64-apple-ios14.0`; pcre2 leaves `_SLJIT_UPDATE_WX_FLAGS`
  undefined, which breaks the giscanner Python extension (inject a no-op shim); fix `#!/bin/sh`
  shebangs to `/var/jb/bin/sh`.
- **Dev packages:** `libmozjs-115-dev 115.12.0+ios1` ships dangling header symlinks and
  `libmozjs-115-jit-dev` puts headers in the wrong directory. Anything that compiles against mozjs
  headers on the device needs those fixed first (see games.md, 0 A.D.).
