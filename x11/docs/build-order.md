# xios build order

There is no top-level orchestrator. Each `x11/linux-build/build-*.sh` is run by hand
via the `docker run` spelled out in its own header comment, and most assume a WARM named
volume populated by an earlier driver. This doc is the missing ordering + volume map.
Building from scratch means: fresh clone, fresh named volume(s), staged SDKs, then the
chain below in order. Volume names and driver facts here were verified against the
script headers on 2026-07-01.

## Inputs you must supply (gitignored by design)

- iOS SDK staged where the driver's `docker run` mounts it, plus a macOS SDK for the
  native host-tool stages (see `linux-build/` headers for the exact `-v` lines).
- The device (iPad, Procursus native toolchain) for the on-device stages — typelibs and
  the gobject-introspection/gjs debs cannot be produced under cross-build.
- Network: drivers `apt-get install` host tools at runtime; `build-gjs.sh` bootstraps
  `rustup` + `cbindgen` UNPINNED (reproducibility gap, see below).

## Docker driver chain (order matters)

Volume column is the value mounted at `/work/Procursus` per the script header. Note the
same physical "GTK base" volume is called `procursus-vol-gtk` by the GNOME-era drivers
even though `build-gtk.sh`'s own header seeds a volume it calls `procursus-vol`; clone or
rename accordingly. The `procursus-vol-shell` and `procursus-vol-qt` volumes are clones of
the warm GTK volume, made so long-running tracks don't race the active GNOME agents.

| # | Driver | Volume | Produces | Depends on |
|---|--------|--------|----------|------------|
| 1 | `run.sh` → `build.sh` | `procursus-vol` | tigervnc/Xvnc, Xios DDX, Xvfb | SDKs only (self-contained, self-checking) |
| 2 | `build-wayland.sh` | `procursus-vol-wayland` | epoll-shim, wayland, wayland-protocols, libxkbcommon | cold-volume-safe |
| 3 | `build-gtk.sh` | `procursus-vol` (the GTK base; later drivers mount it as `procursus-vol-gtk`) | glib→gtk3, graphene→gtk4, libgtkintl | seeds the GTK base every later GNOME driver assumes |
| 4 | `build-gnome.sh` | `procursus-vol-gtk` | GNOME apps (~9) | WARM: GTK base from #3; wayland-track libxkbcommon |
| 5 | `build-icu.sh` | `procursus-vol-gtk` | libicu74, icu-devtools | native-then-cross (`--with-cross-build`); MAKEFLAGS re-pin gotcha |
| 6 | `build-gjs.sh` (+ `build-gjs-manual.sh` ON DEVICE) | `procursus-vol` | mozjs115, gjs | WARM GTK base; rustup/cbindgen bootstrap; GAP: does not stage `ports/mozjs/patches` |
| 7 | `build-gtk4-layer-shell.sh` | `procursus-vol-gtk` | gtk4-layer-shell | WARM #3 (GTK4 + wayland stack); for the iosc shell clients |
| 8 | ANGLE (Mac-side, NOT Docker) | none — `/private/tmp/angle-ios-build` | `angle_*.deb` → `out/` | `ports/angle/build-angle.sh` + `package-angle-es3.sh`; INPUT for #9/#10 |
| 9 | `build-mutter.sh` | `procursus-vol-gtk` | libmutter-14-0 + ~18 debs | WARM; stages the non-`+es3` `out/angle_*.deb` into the cross sysroot (hard req); GAP: `integrate-ios-backend.sh` not called → stock mutter, no MetaBackendIOS |
| 10 | `build-xwayland.sh` | `procursus-vol-wayland` (or `-gtk`, warmest) | xwayland, libxcvt, libxshmfence, libdrm shim | stages the non-`+es3` `out/angle_*.deb`; pin xwayland ≤ 23.2 |
| 11 | `build-shell.sh` | `procursus-vol-gtk` (or an isolated clone → the `procursus-vol-shell` used downstream) | gnome-shell + St/Shell/Gvc/Shew | WARM; reconstructs build base from `out/` debs; hand-synthesizes `mozjs-115.pc` |
| 12 | `build-shell-libs.sh` | `procursus-vol-shell` | libupower-glib, geocode-glib, libgweather-4, libgeoclue | WARM #11; gnome-shell boot-blocker client libs (typelibs generated on-device) |
| 13 | `build-session.sh` | `procursus-vol-shell` | gnome-session, gsd, session glue | WARM from #11 |
| 14 | `build-eds.sh` | `procursus-vol-shell` | EDS, libical, tracker-FTS | WARM; needs ICU from #5 |
| 15 | `build-audio-server.sh` | `procursus-vol-shell` | pulseaudio daemon debs, module-xios-sink/source | WARM (pulseaudio client + libsndfile + glib present) |
| 16 | `build-qt.sh` then `build-qt-modules.sh` | `procursus-vol-qt` | qtbase 6.6.3, Qt6 modules | qt.sh stage 1 builds a native host Qt 6.6.3 into the volume (`QT_HOST_PATH`, one-time ~25 min); modules NEVER concurrent with qt.sh |
| 17 | `build-kf6.sh` | `procursus-vol-qt` | KF6 wave debs | #16; NEVER concurrent with another build on the volume |

## Off-device compile-checks / de-risks (not part of the shipping chain)

- `build-backend-check.sh` — strict-flag compile check of the MetaBackendIOS pieces
  (`src/backends/ios/*.c`) against the mutter 46 tree; not yet wired into meson.
- `build-cogl-smoke.sh` — cross-builds the Cogl-on-ANGLE-ES3 de-risk binary against the
  already-built libmutter-cogl-14 in `procursus-vol-gtk`.

## On-device stages (cannot run in Docker — by design)

- `gi-package.sh`, `build-gjs-manual.sh` (shebang `/var/jb/bin/sh`): gobject-introspection
  + gjs debs.
- `gir-ondevice.sh` bootstrap, then `gir-build-ondevice.sh` /
  `gir-build-mutter-ondevice.sh` / `gir-build-gnome-shell-ondevice.sh` /
  `gir-build-accountsservice-ondevice.sh`: ALL typelibs (g-ir-scanner can't run against a
  Mach-O target under cross-build).
- Docker alone can never produce a bootable GNOME stack; the iPad is a build stage.

## Post-build closure passes (host side, after any batch)

- `recipes/relink-gtkintl.sh /out` — idempotent intl relink (already chained in the GNOME
  drivers).
- `tools/weaken-deb.sh` (+ `tools/macho-weaken.py`) — flip dead X11/xcb `LC_LOAD_DYLIB`
  entries to weak so libmutter loads on iOS; MANUAL today (GAP: wire it).
- `tools/stamp-minos.py` — MinimumOSVersion floor stamp; idempotent, byte-identical
  data.tar; MUST run LAST, after `out/` stops churning.
- `bin/lib/make-repo.py` + `bin/publish-repo.sh` — repo generation (separate `repo/` tree).

## Cascade TARGETS lists

- `build-mutter.sh` default cascade: `TARGETS="${TARGETS:-lcms2 libxcomposite libxkbcommon colord}"`.
- `build-shell-libs.sh` default cascade: `upower-package geocode-glib-package
  gweather4-package …` (geocode-glib before gweather4, its build dep; gdm added if the
  lead confirms).
- Other Procursus base libs (libmpc3/libmpfr6/libunistring5/libxcb-render0/cairo/glib/…)
  came from ad-hoc `make <pkg>-package` runs; re-derive from `out/` contents if needed.

## Open reproducibility gaps (2026-07-01 audit)

1. `integrate-ios-backend.sh` orphaned — mutter builds without MetaBackendIOS. Owner: mutter track.
2. `libxkbcommon-dev` weaken is manual. Owner: wayland track.
3. `build-gjs.sh` doesn't stage `ports/mozjs/patches` into the build. Owner: mozjs/gjs track.
4. `rustup`/`cbindgen` unpinned network bootstrap in `build-gjs.sh`.
5. Version-suffix conventions (`+wl1`, `+rootless1`, `+es3`) encoded nowhere but repo metadata.
