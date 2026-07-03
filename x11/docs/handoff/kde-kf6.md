# kde-kf6 — Qt6 modules (DONE) + KF6 + KWin W1 (DONE)

## Ownership
The KDE Plasma flavor: the Qt6 stack + the KDE Frameworks 6 layer, cross-built Linux→iOS in Docker/Procursus. Background priority (iosc + GNOME are the active demos), but a long-running build track.

## Qt6 modules — DONE
- Phase 2 COMPLETE: all 6 modules packaged (11 debs in `x11/linux-build/out/`, ~14:23 timestamps): qt6-shadertools, qt6-declarative (+ QtQuick + Controls iOS style), qt6-5compat, qt6-wayland (libQt6WaylandClient + the wayland QPA plugin `libqwayland-generic.dylib` — puts Qt windows on iosc), qt6-svg, qt6-image-formats — each with -dev pairs. Built vs the round-2 qtbase 6.6.3-2.
- All staged into build_base on `procursus-vol-qt` (the KF6 wave-0 ancestor). Recipe: `x11/linux-build/recipes/qtbase.mk` + the module recipes; build via `build-qt.sh` (NOT raw make). 5 one-time recipe walls fixed + committed (1bc1b6a, cef1068, 9197a3d, f5cf809, 49a34e6 + OOM guard 85aa99a). Memory: x11-qt-modules-build.
- Remaining (not started): on-device Q2 validation (qml -platform offscreen → wayland w/ QT_QUICK_BACKEND=software on iosc → a QtWidgets app); control-Depends audit + minos stamping before any repo publish.

## KF6 / KDE Plasma — DONE
- `x11/linux-build/build-kf6.sh` — 6-wave driver: stage-1 native host tooling (ECM/kcoreaddons/karchive/kconfig/ki18n/kpackage) then the 40-unit cross build (kwin + plasma-nano/mobile closure, an audited subset — NOT all ~80). Recipes code-gen'd from `tools/gen-kf6-recipes.py` TABLE (edit the generator, not the .mk). Plan/audit: `x11/docs/kde-plasma-plan.md`. Memory: x11-kf6-layer.
- Built on `procursus-vol-kf6` (clone of the Qt volume) with `--cpus=8`; latest log is `x11/linux-build/kf6-build.log` and exits 0. The successful final targeted run was `TARGETS="kglobalacceld" bash /work/build-kf6.sh`; it also copied the built KF6/Plasma debs into `x11/linux-build/out/`.
- Output check: 77 KDE/KF6-related debs in `x11/linux-build/out/` across the 40 units (runtime/dev splits plus data-only packages). Key milestones present: `kf6-kirigami`, `kf6-kio`, `kf6-kcmutils`, `kwayland`, `kdecoration`, `layer-shell-qt`, `plasma-activities`, `plasma-wayland-protocols`, `kglobalacceld`.
- Forward-scan fixes folded back into the generator: KIO drops unconditional Qt6Test, treats the Darwin `getxattr()` branch as iOS too, and avoids DiskArbitration; KCMUtils drops unconditional Qt6Test; KGlobalAccelD builds with `-DWITH_X11=OFF` so it skips private `qtx11extras`/`KStartupInfo` paths and the XCB plugin. `kf6-common.mk` pins gettext tools to host `/usr/bin/*` so cross builds do not execute staged iOS gettext binaries.

## KWin W1 — DONE
- `x11/linux-build/build-kwin.sh` now builds and packages the first-light KWin Wayland compositor layer on `procursus-vol-kf6`. Output debs are in `x11/linux-build/out/`: `kwin_6.1.5_iphoneos-arm64.deb`, `kwin-dev_6.1.5_iphoneos-arm64.deb`, plus rebuilt shim packages `libdrm2/libdrm-dev`, `libgbm1/libgbm-dev`, and `libdisplay-info1/libdisplay-info-dev`.
- Verified package contents: runtime `kwin` deb includes the `kwin_wayland` and `kwin_wayland_wrapper` app bundles plus `/var/jb/usr/lib/libkwin.6.1.5.dylib`. Latest pre-device-prep SHA256: `kwin_6.1.5_iphoneos-arm64.deb` = `7d6acf4f3b80880f21f627f4a591ac8a1a9a8e62ec0b38b2c064c3fdf3d706fa`; `kwin-dev_6.1.5_iphoneos-arm64.deb` = `331aa46018e7b9447953cb587e8cb27de470d743e68514f200beba95bbd9fefe`. Note: that pre-prep runtime deb used package-root `/Applications`; the recipe and prep script now rootless-normalize app bundles to `/var/jb/Applications`.
- Entitlement productization is in the recipe: `kwin.mk` signs the runtime package with `iosc-gl-ent.xml` and `nogeneral`, and `ldid -e` on packaged/installed `kwin_wayland` shows the ANGLE/IOSurface platform + IOKit user-client entitlement set. The package split also carries app wrappers under `/var/jb/Applications` so the signed compositor entrypoint is actually installable.
- First-light scope: X11, DRM, virtual, libinput, QPA, KWindowSystem, and IdleTime static plugin paths are trimmed/guarded on Apple; nested Wayland + fake input + KGlobalAccel are kept. The no-OpenGL QtGui compatibility guard remains because the current staged Qt in `procursus-vol-kf6` still reports `QT_FEATURE_opengl -1`; an ANGLE-enabled Qt should naturally take the real OpenGL paths later.
- Forward-scan fixes landed for Darwin runtime APIs and compositor lifetime hazards encountered so far: `_NSGetExecutablePath`, `pipe2`/`accept4`/`SOCK_CLOEXEC` fallbacks, no-op file sealing, mkstemp SHM path on Apple, DRM lease guards, and no-OpenGL QuickView/thumbnail fallbacks.

## Device prep — DONE (not run)
- `x11/linux-build/prep-kde-kwin-device.sh` stages the first-light runtime set from `procursus-vol-kf6`, overlays the latest local KWin/shim debs, pushes to `/var/jb/tmp/kde-kwin-prep`, installs packages, and deliberately does not start iosc/KWin/Plasma. It writes `/var/jb/tmp/kde-kwin-prep/RUN-LATER.txt` as the handoff marker.
- On-device prep completed cleanly: `kwin 6.1.5`, KF6 runtime packages, KGlobalAccelD, KWayland, shims, and Qt runtime modules are installed; `apt-get check` exits cleanly. `kwin` files are under `/var/jb/Applications/KDE/...` and `/var/jb/usr/lib/libkwin*`.
- The prep script guards against stale volume Qt: if a staged deb is older than the installed device version, it is moved to `skipped-newer-installed/`. This preserves the newer ANGLE-enabled `qt6-base 6.6.3-3` and `qt6-wayland 6.6.3-1` from the dev repo instead of downgrading to the old KF6-volume `6.6.3-2`/`6.6.3` builds.
- Rootless app packaging gotcha fixed: KWin app wrappers must live under `/var/jb/Applications`, not package-root `/Applications` (read-only on device). `kwin.mk` now copies staged app bundles into `$(MEMO_PREFIX)/Applications`, and the prep script rootless-normalizes the already-built local deb before pushing.
- Verification after prep: installed `kwin_wayland` has the `iosc-gl-ent.xml` platform/IOSurface/IOKit entitlements; no `kwin` or Plasma process was launched. Existing iOSC shell processes may already be running independently of this prep flow.

## Known KF6 walls pre-staged
- host qtwaylandscanner via QT_HOST_PATH; kguiaddons/kidletime need `-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner` in KF6_CMAKE_FLAGS (same trap qt-modules hit, adopted). if(APPLE) whack-a-mole pre-staged as audited TABLE seds for 5 risky units (3ccd62a). Downward gates already closed: qtbase round-2 printsupport (kxmlgui), qt5compat (KIO).

## Next
- On-device KWin smoke: install `kwin` plus shims, run the nested Wayland app under iosc, and validate socket creation, frame callbacks, compositor teardown, and whether the staged no-OpenGL Qt still forces QPainter-only behavior.
- Plasma Mobile/P comes after that base: `libplasma`/theming/data, then patched `plasma-workspace`, then `plasma-nano` + `plasma-mobile`. Keep extending the entitlement rule from KWin: GL-initializing real processes such as `plasmashell`, `qml`, and future shell helpers need the same iosc GPU/platform entitlement treatment.

## Docker gotchas
- Volume-prune KILLS active builds (transient containers look unmounted between packages) — use builder-prune. VM: 16 CPU / 7.7GiB → default ninja -j18 OOMs big TUs (qmldom) → full-speed pass then -j2 retry.
