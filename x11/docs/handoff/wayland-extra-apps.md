# Handoff: Wayland extra app wave

Owner scope: the second wave of standalone Wayland/GTK desktop apps requested
after the first app-wave smoke: swaybg, tofi, waybar, swayimg, yad, nwg-look,
Geary/WebKitGTK, Gnumeric, and Transmission. Keep this separate from
`wayland-apps.md`, which owns the already-smoked foot/imv/mpv/fuzzel/dunst/grim
batch and its runtime fixes.

Last touched: 2026-07-08.

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
| swaybg | native Wayland wallpaper utility | recipe/control/patch stack added; `swaybg_1.2.2+ios1_iphoneos-arm64.deb` built; on-device classic `iosc` capture passed |
| tofi | native Wayland launcher/menu | recipe/control/patch stack added; `tofi_0.9.1+ios1_iphoneos-arm64.deb` built; focused on-device `iosc` slot capture passed after clamping `wl_seat` binds to v5 and fixing iOS keymap cleanup |
| waybar | layer-shell status bar | recipe/control/patch stack added; GTK3 Wayland `+ios2`, gtkmm3, and `gtk-layer-shell` built; `waybar_0.15.0+ios1_iphoneos-arm64.deb` installed and focused on-device `iosc` slot capture passed with the minimal clock/custom config |
| swayimg | native Wayland image viewer | recipe/control/patch stack added; `swayimg_5.4+ios1_iphoneos-arm64.deb` built; on-device classic `iosc` capture passed |
| yad | GTK dialog utility | recipe/control added; `yad_15.0+ios1_iphoneos-arm64.deb` built; on-device classic `iosc` capture passed (2026-07-08) after a clean re-run with no competing session switch — the earlier "Broken pipe" was a concurrent `xios-session` switch nuking `wayland-0`, not a yad bug |
| nwg-look | GTK settings UI | explicit blocker target; needs shared Go+cgo iPhoneOS path for gotk3; `xcur2png` is optional/deferrable |
| Geary | GNOME mail client | no recipe; blocked on WebKitGTK and mail-app dependency lane; `gmime`, `libstemmer`, and `libytnef` leaf deps are now built |
| WebKitGTK | browser/webview platform | separate research/build lane; see `geary-webkitgtk.md` |
| Gnumeric | GTK spreadsheet | recipe/control added with `libgsf`, `libxslt`, and `goffice`; `gnumeric_1.12.61+ios1_iphoneos-arm64.deb` built and installed; on-device classic `iosc` capture passed (2026-07-08) — full spreadsheet UI renders with the CSV loaded; the earlier invalidation was a session switch losing `wayland-0`, now confirmed clean |
| Transmission | CLI/daemon BitTorrent client | recipe/control/patch stack added; `transmission_4.1.3+ios1_iphoneos-arm64.deb` built; CLI tools passed on-device; GTK UI deferred until gtkmm |

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
- `linux-build/recipes/luajit.mk`
- `linux-build/recipes/libsigcplusplus.mk`
- `linux-build/recipes/glibmm.mk`
- `linux-build/recipes/cairomm.mk`
- `linux-build/recipes/pangomm.mk`
- `linux-build/recipes/atkmm.mk`
- `linux-build/recipes/gtkmm3.mk`
- `linux-build/recipes/gtk-layer-shell.mk`
- `linux-build/recipes/gmime.mk`
- `linux-build/recipes/libstemmer.mk`
- `linux-build/recipes/libytnef.mk`
- `linux-build/recipes/gspell.mk`
- `linux-build/recipes/libpeas.mk`
- matching controls under `linux-build/build_info/`
- patch stacks under `ports/swaybg/`, `ports/tofi/`, `ports/swayimg/`,
  `ports/waybar/`, and `ports/transmission/`
- `docs/handoff/geary-webkitgtk.md`
- `bin/iosc-extra-apps-smoke`

## Built Packages

Host/container builds completed on 2026-07-06 and 2026-07-07 and copied these debs to
`linux-build/out/`:

- `swaybg_1.2.2+ios1_iphoneos-arm64.deb`
- `tofi_0.9.1+ios1_iphoneos-arm64.deb`
- `swayimg_5.4+ios1_iphoneos-arm64.deb`
- `yad_15.0+ios1_iphoneos-arm64.deb`
- `transmission_4.1.3+ios1_iphoneos-arm64.deb`
- `libgsf-1-114_1.14.58+ios1_iphoneos-arm64.deb`
- `libgsf-1-dev_1.14.58+ios1_iphoneos-arm64.deb`
- `libxslt1.1_1.1.43+ios1_iphoneos-arm64.deb`
- `libxslt1-dev_1.1.43+ios1_iphoneos-arm64.deb`
- `libgoffice-0.10-10_0.10.61+ios1_iphoneos-arm64.deb`
- `libgoffice-0.10-dev_0.10.61+ios1_iphoneos-arm64.deb`
- `gnumeric_1.12.61+ios1_iphoneos-arm64.deb`
- `luajit_2.1.1782726002+ios1_iphoneos-arm64.deb`
- `luajit-dev_2.1.1782726002+ios1_iphoneos-arm64.deb`
- `libsigc++-2.0-0v5_2.10.3+ios1_iphoneos-arm64.deb`
- `libsigc++-2.0-dev_2.10.3+ios1_iphoneos-arm64.deb`
- `libglibmm-2.4-1v5_2.66.7+ios1_iphoneos-arm64.deb`
- `libglibmm-2.4-dev_2.66.7+ios1_iphoneos-arm64.deb`
- `libcairomm-1.0-1v5_1.14.5+ios1_iphoneos-arm64.deb`
- `libcairomm-1.0-dev_1.14.5+ios1_iphoneos-arm64.deb`
- `libpangomm-1.4-1v5_2.46.4+ios1_iphoneos-arm64.deb`
- `libpangomm-1.4-dev_2.46.4+ios1_iphoneos-arm64.deb`
- `libatkmm-1.6-1v5_2.28.3+ios1_iphoneos-arm64.deb`
- `libatkmm-1.6-dev_2.28.3+ios1_iphoneos-arm64.deb`
- `libgtkmm-3.0-1v5_3.24.9+ios1_iphoneos-arm64.deb`
- `libgtkmm-3.0-dev_3.24.9+ios1_iphoneos-arm64.deb`
- `libgtk-3-0_3.24.38+ios2_iphoneos-arm64.deb`
- `libgtk-3-dev_3.24.38+ios2_iphoneos-arm64.deb`
- `gtk-3-bin_3.24.38+ios2_iphoneos-arm64.deb`
- `libgtk-layer-shell0_0.9.2+ios1_iphoneos-arm64.deb`
- `libgtk-layer-shell-dev_0.9.2+ios1_iphoneos-arm64.deb`
- `waybar_0.15.0+ios1_iphoneos-arm64.deb`
- `libstemmer0d_2.2.0+ios1_iphoneos-arm64.deb`
- `libstemmer-dev_2.2.0+ios1_iphoneos-arm64.deb`
- `libytnef0_2.1.2+ios1_iphoneos-arm64.deb`
- `libytnef-dev_2.1.2+ios1_iphoneos-arm64.deb`
- `libgmime-3.0-0_3.2.7+ios1_iphoneos-arm64.deb`
- `libgmime-3.0-dev_3.2.7+ios1_iphoneos-arm64.deb`

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
- LuaJIT 2.1 builds through upstream's `TARGET_SYS=iOS` path and satisfies
  swayimg's Lua dependency. swayimg 5.4 now builds with a Meson-1.0 compatibility
  patch for `meson_options.txt`, explicit iOS libc++ cross flags, a header-only
  fmt shim for missing `std::format`, a filesystem hash shim, and a `pipe2`
  fallback for Darwin.
- The gtkmm3 stack now packages through `libsigc++`, `glibmm`, `cairomm`,
  `pangomm`, `atkmm`, and `gtkmm3`. GTK3 was rebuilt as `3.24.38+ios2` with
  the Wayland GDK headers/pkg-config files exported and a runtime
  `libxcomposite1` dependency. The extra-app build driver invalidates stale
  GTK3 caches when `gdk/gdkwayland.h` or `gdk-wayland-3.0.pc` is missing.
- `gtk-layer-shell` now builds against that GTK3 Wayland payload. Waybar 0.15.0
  builds a minimal iOS-first surface with clock/custom modules, Linux
  integrations disabled, Darwin fallbacks for `pipe2`, `wordexp`, realtime
  signals, and inotify, plus a no-session-D-Bus portal fallback.
- Waybar's upstream fallback subprojects (`fmt`, `spdlog`, `jsoncpp`) can leave
  stale static artifacts in `build_base`; the build driver and recipe scrub
  those after install so later packages do not link against accidental fallback
  libraries.
- tofi maps under `iosc` after clamping its `wl_seat` bind to the compositor's
  advertised v5 support. The iOS keymap crash was a real double-cleanup path in
  `wl_keyboard_keymap`; the patch keeps a single shared `munmap`/`close`.
- The Geary leaf-dependency lane has packaged `gmime`, `libstemmer`, and
  `libytnef`. `gspell` and `libpeas` recipe/control skeletons exist but have
  not yet reached validated debs.
- On-device classic `iosc` smoke installed the local extra-app debs and passed
  package state, Transmission CLI, `swaybg`, and `swayimg`. Focused follow-up
  slot smokes now also pass for `tofi` and `waybar`. `yad` and `gnumeric` were
  re-run on 2026-07-08 on a clean `iosc` session with no competing
  `xios-session` switch and both captured green (see
  `artifacts/device-runs/extra-apps-smoke-20260708-193938/`): the earlier `yad`
  "Broken pipe" and `gnumeric` invalidation were both the same failure mode — a
  concurrent session switch nuking `wayland-0` mid-run — not app bugs.

## Blocked / Opt-In Targets

- `yad`/`gnumeric` runtime smoke: RESOLVED 2026-07-08. Both captured green on a
  clean classic `iosc` session with no competing `xios-session` switch
  (`artifacts/device-runs/extra-apps-smoke-20260708-193938/`). The prior `yad`
  `Error reading events from display: Broken pipe` and `gnumeric` invalidation
  were both caused by a concurrent session switch tearing down `wayland-0`
  mid-run, not by the apps.
- `waybar` broader feature surface: the current package intentionally ships the
  minimal bar surface. Sway/River/DWL/Hyprland/Wayfire/taskbar, tray, audio,
  Bluetooth, and other Linux/session-manager integrations remain disabled until
  a target user workflow needs them.
- `nwg-look-package`: intentionally exits with a blocker until the repo has a
  Go+cgo iPhoneOS cross-build path for gotk3. Host Go can target `ios/arm64`,
  but cgo is off by default and the repo has no packageable path that wires
  Go, the iPhoneOS clang wrapper, `cross-pkg-config`, GTK3 `.pc` files, rootless
  rpaths, signing, and package assembly together. `xcur2png` is only a cursor
  preview helper upstream and can be skipped or packaged later; it is not the
  main blocker.
- `geary-package`: do not add until WebKitGTK 4.1 and the remaining mail
  dependency lane are available. `gmime`, `libstemmer`, and `libytnef` are now
  packaged; `gspell`, `libpeas`, `folks`, `gnome-online-accounts`, `gsound`,
  gcr-3/gck-1, and WebKitGTK remain.

## Policy

- Keep app recipes additive and opt-in until each app has at least one on-device
  launch smoke.
- Disable Linux/session-manager integrations before adding new stub packages.
- Prefer `dunst` over `mako`; the sd-bus path is known to be a bad fit here.
- Publish only after copying the exact smoked debs into top-level `repo/debs/`
  and running the normal repo audit/publish flow.

## Verification

Host/container verification completed on 2026-07-06 and 2026-07-07:

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
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk-calc:/work/Procursus \
  -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="luajit-package libsigcplusplus-package glibmm-package cairomm-package pangomm-package atkmm-package gtkmm3-package" \
  procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk-calc:/work/Procursus \
  -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="swayimg-package" \
  procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk-calc:/work/Procursus \
  -v "$PWD/linux-build/build-wayland-extra-apps.sh:/work/build-wayland-extra-apps.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="gtk+3.0-package gtk-layer-shell-package waybar-package" \
  procursus-xbuild:bookworm-arm64 /work/build-wayland-extra-apps.sh
docker run --rm --platform linux/arm64 --cpus=2 \
  -v procursus-vol-gtk:/work/Procursus \
  -v "$PWD/linux-build/build-gnome.sh:/work/build-gnome.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/vapi:/work/vapi:ro" \
  -v "$PWD/linux-build/out:/out" \
  -e TARGETS="libstemmer-package libytnef-package gmime-package" \
  procursus-xbuild:bookworm-arm64 /work/build-gnome.sh
```

`swayimg_5.4+ios1_iphoneos-arm64.deb` metadata and payload were checked with
`dpkg-deb -f` / `dpkg-deb -c`; SHA-256 is
`7020d32850957ba46a73d1e3d568bbc92192fa82eac57ba02ce122de7d6ab760`.
`aarch64-apple-darwin-otool -L` shows the expected runtime links:
`libiosexec`, `fontconfig`, `freetype`, `luajit`, `wayland-client`,
`libxkbcommon`, `libjpeg`, `libpng16`, `libc++`, and `libSystem`.

The final focused follow-up package hashes are:

- `tofi_0.9.1+ios1_iphoneos-arm64.deb`:
  `731f40023d84783a14e27510da53a4185204383e70d3ab0b220606b3cbdf9516`
- `libgtk-3-0_3.24.38+ios2_iphoneos-arm64.deb`:
  `e0a2e1f8ba01c7537d7dc488cb2fa4522fac74142fa06a9a3eb41d20469c5f7b`
- `libgtk-3-dev_3.24.38+ios2_iphoneos-arm64.deb`:
  `73d0bee9b59c80466de4a857214709d48606d83086cadc8f1171dd5459ba54b3`
- `gtk-3-bin_3.24.38+ios2_iphoneos-arm64.deb`:
  `bdf0cbe4043c04a4878476973be1046fa9c3264681a56dcdb506cd2b9e5c7171`
- `libgtk-layer-shell0_0.9.2+ios1_iphoneos-arm64.deb`:
  `2beebfa0375c6c6dfc18f6c54d96ad79ecb0af6bd5e658845a2bd41af677785d`
- `libgtk-layer-shell-dev_0.9.2+ios1_iphoneos-arm64.deb`:
  `56772daee28ce47399cfd3bff4048db586b7f0cf8155828114582f5538130ce3`
- `waybar_0.15.0+ios1_iphoneos-arm64.deb`:
  `957e99dfe356124aecd2d40b1e2d4a3a157297bf8c4d56423318ed41bb229f79`

`dpkg-deb -f` checks confirmed `waybar` depends on `libgtk-3-0`,
`libwayland0`, `libxkbcommon0`, `libglib2.0-0`, `libgtkmm-3.0-1v5`, and
`libgtk-layer-shell0`; `libgtk-3-0 3.24.38+ios2` depends on `libxcomposite1`.

The driver now stages collected debs in a fresh temp directory, runs the shared
`libgtkintl` relink pass only on those staged artifacts, then copies them into
`linux-build/out/`. This avoids rewriting unrelated cached GNOME/KDE packages
when running a narrow target.

`build-gnome.sh` still runs its older broad `/out` relink pass. The
2026-07-06 `libstemmer`/`libytnef`/`gmime` collection therefore scanned the
large local `linux-build/out` cache before exiting successfully.

For graphical Wayland clients, start in classic `iosc` mode and reuse the
existing capture helper:

```sh
x11/bin/xios-device session iosc
x11/bin/iosc-capture-remote.sh swaybg swaybg -i /var/jb/tmp/wallpaper.png
x11/bin/iosc-capture-remote.sh tofi bash -lc "printf 'one\ntwo\n' | tofi --prompt-text 'Xios '"
x11/bin/iosc-capture-remote.sh swayimg swayimg /var/jb/tmp/xios-imv-smoke.png
```

Waybar and other long-running layer-shell clients should be checked with
process state plus a compositor screenshot rather than only command exit
status. The focused Waybar smoke used a dedicated slot and a 5-second capture:

```sh
bin/xios-device session --slot codexwaybar iosc
IOSC_CAP_LOCAL=artifacts/device-runs/waybar-slot-20260706-1955 \
  WAYLAND_DISPLAY=/var/jb/tmp/wayland-codexwaybar \
  XDG_RUNTIME_DIR=/var/jb/tmp \
  IOSC_CAP_WAIT=5 \
  bin/iosc-capture-remote.sh waybar-ios3 \
    env GDK_BACKEND=wayland WAYLAND_DISPLAY=/var/jb/tmp/wayland-codexwaybar \
      XDG_RUNTIME_DIR=/var/jb/tmp waybar --log-level trace
bin/xios-device status --slot codexwaybar
```

The successful artifacts are
`artifacts/device-runs/tofi-ios3-slot-20260706-1844/cap-tofi-ios3.png` and
`artifacts/device-runs/waybar-slot-20260706-1955/cap-waybar-ios3.png`; the
Waybar slot was stopped afterward and active session returned to `iosc`.

The second-wave batch also has a repeatable host-side helper:

```sh
x11/bin/iosc-extra-apps-smoke --install
x11/bin/iosc-extra-apps-smoke --only packages,transmission
```

`--install` stages the exact local runtime debs from `linux-build/out/` onto the
device, installs them with `dpkg -i --force-overwrite`, runs `apt-get check`,
then captures `swaybg`, `tofi`, `swayimg`, `yad`, and `gnumeric` while checking
Transmission's CLI tools. The install set includes `luajit` for `swayimg`. When
a Wayland guard, capture, or final screenshot step fails, the helper writes a
`diagnostics-*.log` with active-session state, geometry, compositor/session
logs, sockets, and a focused process snapshot.

Device verification is now green for the graphical batch. On 2026-07-06 PDT,
`bin/iosc-extra-apps-smoke --install` wrote artifacts to
`artifacts/device-runs/extra-apps-smoke-20260706-173431/`: install,
`apt-get check`, package queries, Transmission CLI, `swaybg`, and `swayimg`
passed. `tofi` and `waybar` passed in focused slot smokes after the client
patches above. `yad` and `gnumeric` — the last two published-but-unverified
apps — passed on 2026-07-08 PDT via
`bin/iosc-extra-apps-smoke --only packages,yad,gnumeric,shot` on a clean
classic `iosc` session with no competing `xios-session` switch; artifacts are in
`artifacts/device-runs/extra-apps-smoke-20260708-193938/` (`cap-yad.png`,
`cap-gnumeric.png`, `results.txt` = all PASS, no `diagnostics-*.log`). The whole
second-wave graphical batch now has at least one green on-device capture.
