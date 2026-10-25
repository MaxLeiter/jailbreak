# Handoff: second Wayland app wave

Scope: the second batch of standalone Wayland/GTK apps (swaybg, tofi, waybar,
swayimg, yad, nwg-look, Geary/WebKitGTK, Gnumeric, Transmission) and the
libraries they pulled in. The first batch and its runtime fixes are in
`wayland-apps.md`. Geary and WebKitGTK have their own file,
`geary-webkitgtk.md`.

Last checked against `repo/Packages`: 2026-10-25.

## Current state

Every app below is published on `repo.maxleiter.com` and has at least one
green on-device capture in `iosc`.

| Package (indexed) | What it is | Notes |
|---|---|---|
| `swaybg 1.2.2+ios1` | wallpaper | |
| `tofi 0.9.1+ios1` | launcher/menu | `wl_seat` bind clamped to v5; keymap double-cleanup fixed |
| `waybar 0.15.0+ios1` | layer-shell bar | minimal build: clock and custom modules only |
| `swayimg 5.4+ios1` | image viewer | needs `luajit 2.1.1782726002+ios1` |
| `yad 15.0+ios1` | GTK dialogs | |
| `nwg-look 1.1.1+ios1` | GTK settings UI | Go 1.25 cgo for `ios/arm64`; `xcur2png` optional |
| `gnumeric 1.12.61+ios1` | spreadsheet | with `libgsf-1-114`, `libgoffice-0.10-10`, `libxslt1.1` |
| `transmission 4.1.3+ios1` | BitTorrent daemon + CLI + web UI | GTK client not built |
| `geary 46.0+ios1` | mail | see `geary-webkitgtk.md` |

Supporting libraries, all indexed: the gtkmm3 stack (`libsigc++-2.0-0v5`,
`libglibmm-2.4-1v5`, `libcairomm-1.0-1v5`, `libpangomm-1.4-1v5`,
`libatkmm-1.6-1v5`, `libgtkmm-3.0-1v5 3.24.9+ios1`), `libgtk-layer-shell0
0.9.2+ios1`, and the Geary leaves (`libgmime-3.0-0`, `libstemmer0d`,
`libytnef0`, `libgspell-1-2`, `libpeas-1.0-0`, Folks, gcr-3/gck-1, the GOA
client library).

Open, none of it blocking:

- waybar ships only the minimal surface. Sway/River/Hyprland/taskbar, tray,
  audio and Bluetooth modules stay off until someone actually needs them.
- Transmission's GTK client is still disabled. It was waiting on gtkmm, which
  now exists, so it is unblocked but not attempted.

## Port notes

- **Transmission** builds daemon, CLI, utilities and web UI. The patch stack
  turns off Darwin install-time RPATH relinking for the bundled NAT helpers and
  avoids the Foundation-backed UTF-8 helper on iPhoneOS.
- **Gnumeric** needed `libgsf`, `libxslt` and `goffice`. The driver installs
  host `intltool` and `xmllint`, routes autotools through `cross-pkg-config`,
  forces host `glib-compile-resources`, uses `zlib-ng` as the zlib provider, and
  defines the `lgamma_r` prototype this SDK lacks.
- **swayimg** uses LuaJIT built through upstream's `TARGET_SYS=iOS`, plus a
  Meson 1.0 compatibility patch for `meson_options.txt`, iOS libc++ flags, a
  header-only fmt shim for the missing `std::format`, a filesystem hash shim,
  and a `pipe2` fallback.
- **GTK3** was rebuilt (`+ios2`, now `+ios3`) to export the Wayland GDK headers
  and `.pc` files, with a runtime `libxcomposite1` dependency. The driver
  invalidates stale GTK3 caches when `gdk/gdkwayland.h` or
  `gdk-wayland-3.0.pc` is missing.
- **waybar** gets Darwin fallbacks for `pipe2`, `wordexp`, realtime signals
  and inotify, plus a portal fallback for when there is no session bus. Its
  upstream fallback subprojects (`fmt`, `spdlog`, `jsoncpp`) can leave stale
  static libraries in `build_base`; the recipe scrubs them so later packages
  don't link them by accident.
- **libpeas** stages the published `libgirepository-1.0-1`/`-dev` debs instead
  of rebuilding the whole GI and target-Python toolchain. gspell links ICU 78.
- **GOA is client-only.** Manual IMAP/SMTP is the credible iOS path for Geary.
  The Linux provider daemon and browser OAuth are not claimed.

## Gotchas

- **A "Broken pipe" mid-smoke is usually a session switch.** The yad
  `Error reading events from display: Broken pipe` and the Gnumeric
  invalidation were both a concurrent `xios-session` switch removing
  `wayland-0`. Both apps were fine on a clean rerun. Run smokes in a dedicated
  slot.
- **Long-running layer-shell clients** (waybar) need process state plus a
  screenshot, not just a command exit status.
- **`build-gnome.sh` still relinks all of `/out`**, so a narrow run through it
  scans the whole local package cache. `build-wayland-extra-apps.sh` instead
  stages collected debs in a temp dir and relinks only those.

## Build

`linux-build/build-wayland-extra-apps.sh` is opt-in. Its default `TARGETS` is
the native batch:

```sh
TARGETS="swaybg-package tofi-package yad-package libgsf-package libxslt-package goffice-package gnumeric-package transmission-package"
```

Run it on a GTK/Wayland-warmed Procursus volume:

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

Other target groups used: `luajit-package libsigcplusplus-package
glibmm-package cairomm-package pangomm-package atkmm-package gtkmm3-package`,
`swayimg-package`, `gtk+3.0-package gtk-layer-shell-package waybar-package`,
`gspell-package libpeas-package` (copy the published `libgirepository-1.0-*`
debs into `linux-build/out/` first), and, through `build-gnome.sh`,
`libstemmer-package libytnef-package gmime-package`. The nwg-look target
installs a pinned Go 1.25 toolchain into the volume, enables cgo for
`ios/arm64`, and signs the binary with the GPU-client profile.

## Verify on device

Start the classic desktop and reuse the capture helper from the first wave:

```sh
x11/bin/xios-device session iosc
x11/bin/iosc-capture-remote.sh swaybg swaybg -i /var/jb/tmp/wallpaper.png
x11/bin/iosc-capture-remote.sh tofi bash -lc "printf 'one\ntwo\n' | tofi --prompt-text 'Xios '"
x11/bin/iosc-capture-remote.sh swayimg swayimg /var/jb/tmp/xios-imv-smoke.png
```

For waybar, use a slot so nothing else touches the socket:

```sh
bin/xios-device session --slot codexwaybar iosc
WAYLAND_DISPLAY=/var/jb/tmp/wayland-codexwaybar XDG_RUNTIME_DIR=/var/jb/tmp IOSC_CAP_WAIT=5 \
  bin/iosc-capture-remote.sh waybar \
    env GDK_BACKEND=wayland WAYLAND_DISPLAY=/var/jb/tmp/wayland-codexwaybar \
      XDG_RUNTIME_DIR=/var/jb/tmp waybar --log-level trace
```

The batch helper:

```sh
x11/bin/iosc-extra-apps-smoke --install
x11/bin/iosc-extra-apps-smoke --only packages,yad,gnumeric,shot
```

`--install` copies local runtime debs from `linux-build/out/` to the device,
installs them with `dpkg -i --force-overwrite`, runs `apt-get check`, then
captures swaybg, tofi, swayimg, yad and gnumeric and checks Transmission's CLI.
On a failed step it writes a `diagnostics-*.log` with session state, geometry,
logs, sockets and a process snapshot. Now that everything is published, prefer
installing from the repo over `--install` unless you are testing a rebuild.

## History

Built 2026-07-06 and 07-07, device-smoked through 2026-07-08 (yad and Gnumeric
last, after the session-switch false failures), nwg-look finished 2026-07-29,
and the gspell/libpeas leaves were rebuilt against ICU 78 on 2026-07-29. The
whole wave reached production by the scoped 2026-07-30 publish.
