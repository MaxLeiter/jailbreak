# Handoff: Wayland extra app wave

Owner scope: the second wave of standalone Wayland/GTK desktop apps requested
after the first app-wave smoke: swaybg, tofi, waybar, swayimg, yad, nwg-look,
Geary/WebKitGTK, Gnumeric, and Transmission. Keep this separate from
`wayland-apps.md`, which owns the already-smoked foot/imv/mpv/fuzzel/dunst/grim
batch and its runtime fixes.

Last touched: 2026-07-06.

## Build Driver

Use `linux-build/build-wayland-extra-apps.sh`. It is opt-in and defaults to the
tractable native batch:

```sh
TARGETS="swaybg-package tofi-package yad-package libgsf-package libxslt-package goffice-package gnumeric-package transmission-package"
```

Run it on a GTK/Wayland-warmed Procursus volume, for example:

```sh
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk-calc:/work/Procursus \
  -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="swaybg-package tofi-package" \
  procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
```

## Target Status

| Target | Intended lane | Status |
|---|---|---|
| swaybg | native Wayland wallpaper utility | recipe/control/patch stack added; `swaybg_1.2.2+ios1_iphoneos-arm64.deb` built |
| tofi | native Wayland launcher/menu | recipe/control/patch stack added; `tofi_0.9.1+ios1_iphoneos-arm64.deb` built |
| waybar | layer-shell status bar | recipe/control skeleton added; blocked on gtkmm3 + GTK3 gtk-layer-shell |
| swayimg | native Wayland image viewer | recipe/control/patch stack added; blocked on LuaJIT package availability |
| yad | GTK dialog utility | recipe/control added; `yad_15.0+ios1_iphoneos-arm64.deb` built |
| nwg-look | GTK settings UI | explicit blocker target; needs Go+cgo iPhoneOS path and xcur2png decision |
| Geary | GNOME mail client | no recipe; blocked on WebKitGTK and mail-app dependency lane |
| WebKitGTK | browser/webview platform | separate research/build lane; see `geary-webkitgtk.md` |
| Gnumeric | GTK spreadsheet | recipe/control added with `libgsf`, `libxslt`, and `goffice`; `gnumeric_1.12.61+ios1_iphoneos-arm64.deb` built |
| Transmission | CLI/daemon BitTorrent client | recipe/control/patch stack added; `transmission_4.1.3+ios1_iphoneos-arm64.deb` built; GTK UI deferred until gtkmm |

## Added Files

- `linux-build/recipes/swaybg.mk`
- `linux-build/recipes/tofi.mk`
- `linux-build/recipes/swayimg.mk`
- `linux-build/recipes/waybar.mk`
- `linux-build/recipes/yad.mk`
- `linux-build/recipes/nwg-look.mk`
- `linux-build/recipes/libgsf.mk`
- `linux-build/recipes/libxslt.mk`
- `linux-build/recipes/goffice.mk`
- `linux-build/recipes/gnumeric.mk`
- `linux-build/recipes/transmission.mk`
- matching controls under `linux-build/build_info/`
- patch stacks under `ports/swaybg/`, `ports/tofi/`, `ports/swayimg/`, and
  `ports/transmission/`
- `docs/handoff/geary-webkitgtk.md`

## Built Packages

Host/container builds completed on 2026-07-06 and copied these debs to
`linux-build/out/`:

- `swaybg_1.2.2+ios1_iphoneos-arm64.deb`
- `tofi_0.9.1+ios1_iphoneos-arm64.deb`
- `yad_15.0+ios1_iphoneos-arm64.deb`
- `transmission_4.1.3+ios1_iphoneos-arm64.deb`
- `libgsf-1-114_1.14.58+ios1_iphoneos-arm64.deb`
- `libgsf-1-dev_1.14.58+ios1_iphoneos-arm64.deb`
- `libxslt1.1_1.1.43+ios1_iphoneos-arm64.deb`
- `libxslt1-dev_1.1.43+ios1_iphoneos-arm64.deb`
- `libgoffice-0.10-10_0.10.61+ios1_iphoneos-arm64.deb`
- `libgoffice-0.10-dev_0.10.61+ios1_iphoneos-arm64.deb`
- `gnumeric_1.12.61+ios1_iphoneos-arm64.deb`

## Port Notes

- Transmission 4.1.3 builds the daemon, CLI, utilities, and web UI with the GTK
  client disabled until gtkmm exists. The iOS patch stack disables Darwin
  install-time RPATH relinking for bundled NAT helper external projects and
  avoids the Foundation-backed UTF-8 helper on iPhoneOS.
- Gnumeric needed `libgsf`, `libxslt`, and `goffice` packages. The build driver
  installs host `intltool` and `xmllint`, routes autotools recipes through
  `cross-pkg-config`, forces host `glib-compile-resources`, uses `zlib-ng` as
  the local zlib provider, and defines the existing `lgamma_r` prototype path
  for this iOS SDK.

## Blocked / Opt-In Targets

- `waybar-package`: needs a target `gtkmm-3.0` stack
  (`glibmm`/`sigc++`/`cairomm`/`pangomm`/`atkmm`) plus GTK3
  `gtk-layer-shell-0`. The existing `gtk4-layer-shell` package is not the right
  library.
- `swayimg-package`: needs a `luajit` runtime/dev package in the warmed
  Procursus volume or a local recipe/control.
- `nwg-look-package`: intentionally exits with a blocker until the repo has a
  Go+cgo iPhoneOS cross-build path for gotk3.
- `geary-package`: do not add until WebKitGTK 4.1 and the mail dependency lane
  are available.

## Policy

- Keep app recipes additive and opt-in until each app has at least one on-device
  launch smoke.
- Disable Linux/session-manager integrations before adding new stub packages.
- Prefer `dunst` over `mako`; the sd-bus path is known to be a bad fit here.
- Publish only after copying the exact smoked debs into top-level `repo/debs/`
  and running the normal repo audit/publish flow.

## Verification

Host/container verification completed on 2026-07-06:

```sh
bash -n linux-build/build-wayland-extra-apps.sh
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk-calc:/work/Procursus \
  -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="swaybg-package tofi-package yad-package transmission-package" \
  procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk-calc:/work/Procursus \
  -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="libgsf-package libxslt-package goffice-package gnumeric-package" \
  procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
docker run --rm --platform linux/arm64 --entrypoint bash \
  -v "$PWD/linux-build/out:/out:ro" \
  procursus-xbuild:bookworm-arm64 \
  -lc 'for f in /out/swaybg_1.2.2+ios1_iphoneos-arm64.deb /out/tofi_0.9.1+ios1_iphoneos-arm64.deb /out/yad_15.0+ios1_iphoneos-arm64.deb /out/transmission_4.1.3+ios1_iphoneos-arm64.deb /out/gnumeric_1.12.61+ios1_iphoneos-arm64.deb; do dpkg-deb -I "$f"; done'
```

The driver now stages collected debs in a fresh temp directory, runs the shared
`libgtkintl` relink pass only on those staged artifacts, then copies them into
`linux-build/out/`. This avoids rewriting unrelated cached GNOME/KDE packages
when running a narrow target.

For graphical Wayland clients, start in classic `iosc` mode and reuse the
existing capture helper:

```sh
x11/bin/xios-device session iosc
x11/bin/iosc-capture-remote.sh swaybg swaybg -i /var/jb/tmp/wallpaper.png
x11/bin/iosc-capture-remote.sh tofi tofi-run
x11/bin/iosc-capture-remote.sh swayimg swayimg /var/jb/tmp/xios-imv-smoke.png
```

Waybar and other long-running layer-shell clients should be checked with process
state plus a compositor screenshot rather than only command exit status.
