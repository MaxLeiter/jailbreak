# kde-kf6 — Qt6 modules (DONE) + KF6 / KDE Plasma build (DONE)

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

## Known KF6 walls pre-staged
- host qtwaylandscanner via QT_HOST_PATH; kguiaddons/kidletime need `-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner` in KF6_CMAKE_FLAGS (same trap qt-modules hit, adopted). if(APPLE) whack-a-mole pre-staged as audited TABLE seds for 5 risky units (3ccd62a). Downward gates already closed: qtbase round-2 printsupport (kxmlgui), qt5compat (KIO).

## Next
- KWin W1 is next: nested `kwin_wayland` as an iosc client, X11 OFF, QPainter/wl_shm first. New Qt module gaps before KWin: `qttools` (UiTools) and `qtsensors`; QtConcurrent is already in qtbase, and QtQuick Controls/Layouts/Window come from qtdeclarative.
- Plasma Mobile/P comes after that base: `libplasma`/theming/data, then patched `plasma-workspace`, then `plasma-nano` + `plasma-mobile`. Since QtWayland + ANGLE is now set up, keep the GPU entitlement rule from `docs/kde-plasma-plan.md`: GL-initializing executables such as `kwin_wayland`, `plasmashell`, and `qml` need the iosc GPU client entitlement.

## Docker gotchas
- Volume-prune KILLS active builds (transient containers look unmounted between packages) — use builder-prune. VM: 16 CPU / 7.7GiB → default ninja -j18 OOMs big TUs (qmldom) → full-speed pass then -j2 retry.
