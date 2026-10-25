# GNOME apps: recipe chain and dependency map

**Status:** the chain is built and most apps are published. This file is the dependency rationale
and build order for the GTK4/libadwaita app stack. Per-app launch status and fixes for apps that do
not map a window are in [handoff/wayland-apps.md](handoff/wayland-apps.md); the GNOME Shell session
is in [handoff/gnome-session.md](handoff/gnome-session.md).

Apps run as Wayland clients on any flavor (iosc, GNOME Shell, KDE) or as their own iPad windows
under `xios-native`.

## Published (repo/Packages, 2026-10-25)

| App | Version | Notes |
|---|---|---|
| `gnome-console` | 46.0+ios1 | lightest GTK4 smoke test; recommended by `xios-gnome` |
| `gnome-text-editor` | 46.3+ios1 | recommended by `xios-gnome` |
| `gnome-calculator` | 46.2+ios1 | the first Vala app; recommended by `xios-gnome` |
| `nautilus` | 46.4+ios1 | heaviest tree (tracker, portal, gnome-desktop); recommended by `xios-gnome` |
| `gnome-font-viewer` | 46.0+ios1 | |
| `baobab` | 46.0+ios1 | Vala |
| `file-roller` | 44.7+ios1 | |
| `d-spy` | 1.10.0+ios1 | |
| `hitori` | 44.0+ios1 | GTK3 |
| `gnome-control-center` | 46.4+ios1 | |
| `geary` | 46.0+ios1 | needs WebKitGTK, see handoff/geary-webkitgtk.md |
| `thunar` | 4.16.11+ios1 | GTK3, XFCE |

Libraries: `libadwaita-1-0 1.5.0`, `libvte-2.91-gtk4-0 0.76.6`, `libgtksourceview-5-0 5.12.1`,
`libtracker-sparql-3.0-0 3.7.3`, `libgnome-desktop-4-2 44.1`, `libgtk-4-1 4.14.5`.

Not built: `gnome-terminal` (GTK3; a recipe exists but it is not the GNOME app path), `gedit`
(see below). gjs apps such as `gnome-characters` or `gnome-weather` are no longer blocked by
typelibs, since gjs and on-device scans work, but none has been packaged.

## Recipe table

All in `x11/linux-build/recipes/`, control templates in `x11/linux-build/build_info/`. Versions are
the GNOME 46 generation, matching GTK 4.14.5. libadwaita 1.5 requires AppStream 1.0, which forced
`libappstream4` to `libappstream5`.

| Recipe | Packages | Version | Target deps |
|---|---|---|---|
| `libxmlb.mk` | libxmlb2, -dev | 0.3.14 | glib (+ lzma/zstd) |
| `appstream.mk` | libappstream5, -dev | 1.0.3 | glib, libxml2, libyaml, libxmlb |
| `libadwaita.mk` | libadwaita-1-0, -dev | 1.5.0 | gtk4, appstream, fribidi |
| `vte.mk` | libvte-2.91-gtk4-0, -dev | 0.76.6 | gtk4, libxml2, pcre2, gnutls, icu4c |
| `gtksourceview5.mk` | libgtksourceview-5-0, -dev | 5.12.1 | gtk4, libxml2, pcre2 |
| `enchant.mk` | libenchant-2-2, -dev | 2.6.1 | glib |
| `json-glib.mk` | libjson-glib-1.0-0, -dev | 1.8.0 | glib |
| `gnome-autoar.mk` | libgnome-autoar-0-0, -dev | 0.4.5 | glib, libarchive, gtk4 |
| `libportal.mk` | libportal1, -gtk4-1, -dev | 0.7.1 | glib, gtk4 |
| `tracker.mk` | libtracker-sparql-3.0-0, -dev | 3.7.3 | glib, sqlite3, json-glib, icu4c |
| `gnome-desktop.mk` | libgnome-desktop-4-2, -dev | 44.1 | gtk4, gsettings-desktop-schemas, iso-codes, libxkbcommon (with xkbregistry) |
| `iso-codes.mk` | iso-codes | 4.15.0 | data |
| `gnome-console.mk` | gnome-console | 46.0 | gtk4, libadwaita, vte |
| `gnome-text-editor.mk` | gnome-text-editor | 46.3 | gtk4, libadwaita, gtksourceview5, enchant |
| `gnome-font-viewer.mk` | gnome-font-viewer | 46.0 | gtk4, libadwaita, gnome-desktop |
| `nautilus.mk` | nautilus | 46.4 | gtk4, libadwaita, gnome-desktop, gnome-autoar, libportal, tracker |
| `libpsl.mk` | libpsl5, -dev | 0.21.5 | |
| `libsoup3.mk` | libsoup-3.0-0, -dev | 3.4.4 | glib, libpsl, nghttp2, sqlite3 |
| `libgee.mk` | libgee-0.8-2, -dev | 0.20.8 | glib (Vala library) |
| `gnome-calculator.mk` | gnome-calculator | 46.2 | gtk4, libadwaita, gtksourceview5, libsoup3, libgee, mpfr/mpc |

Facts that shaped the chain:

- libadwaita hard-requires AppStream, which drags in `appstream` and `libxmlb`.
- vte is built GTK4-only (`-Dgtk3=false`). `-Dgtk3=true` plus the commented libvte-2.91-0 packaging
  block brings the GTK3 widget back if gnome-terminal is ever wanted.
- nautilus: `-Dextensions=false` drops gexiv2/gstreamer, `-Dcloudproviders=false` and
  `-Dpackagekit=false` drop those. tracker-sparql has no opt-out; the localsearch indexer stays
  optional, so search is just inert.
- gnome-desktop-4 needs libxkbregistry, so the shared `libxkbcommon` recipe builds with
  `-Denable-xkbregistry=true`.

Build-host tools (in the Docker image, not recipes): `sassc` (libadwaita SCSS), `itstool`,
`desktop-file-utils`, `valac`. Every package that installs GSettings schemas runs
`glib-compile-schemas` in its postinst.

## Build order

```
dbus -> gsettings-desktop-schemas -> dconf
gdk-pixbuf -> graphene -> gtk4        libxkbcommon (xkbregistry on)
libxmlb -> appstream -> libadwaita
json-glib, vte, gtksourceview5, enchant, gnome-autoar, libportal, iso-codes
tracker (json-glib, sqlite3, icu4c)
gnome-desktop (gsettings-desktop-schemas, iso-codes, libxkbcommon)
apps: gnome-console, gnome-text-editor, gnome-font-viewer, nautilus
Vala: libpsl -> libsoup3, libgee -> gnome-calculator, baobab
```

The driver is `x11/linux-build/build-gnome.sh`. It needs the GTK4 base (`build-gtk.sh`) and the
xkbregistry `libxkbcommon` already built in the same Procursus volume; `TARGETS=...` narrows it
(for example `gnome-console-package`).

## Vala

Vala apps cross-compile fine: `valac` is a host transpiler that emits C for the cross compiler and
never runs target code. It only needs each dependency's `.vapi`, which is a platform-independent API
description. Since our libraries build with `-Dvapi=false`, version-matched vapis are vendored from
Ubuntu 24.04 (GTK 4.14.5, libadwaita 1.5) into `share/vala/vapi/`; see
`x11/linux-build/vapi/README.md`. gnome-calculator's math deps (gmp, mpfr, mpc) come prebuilt from
Procursus. `glib-networking` is optional at runtime (only online currency rates need TLS).

## gedit: skipped

gedit 46 is GTK4 on the `libgedit-*` forks plus `libpeas-2`, a plugin engine that loads plugins
through typelibs. gnome-text-editor covers the same need with a much smaller tree.
