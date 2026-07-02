# kde-kf6 — Qt6 modules (DONE) + KF6 / KDE Plasma build (in progress)

## Ownership
The KDE Plasma flavor: the Qt6 stack + the KDE Frameworks 6 layer, cross-built Linux→iOS in Docker/Procursus. Background priority (iosc + GNOME are the active demos), but a long-running build track.

## Qt6 modules — DONE
- Phase 2 COMPLETE: all 6 modules packaged (11 debs in `x11/linux-build/out/`, ~14:23 timestamps): qt6-shadertools, qt6-declarative (+ QtQuick + Controls iOS style), qt6-5compat, qt6-wayland (libQt6WaylandClient + the wayland QPA plugin `libqwayland-generic.dylib` — puts Qt windows on iosc), qt6-svg, qt6-image-formats — each with -dev pairs. Built vs the round-2 qtbase 6.6.3-2.
- All staged into build_base on `procursus-vol-qt` (the KF6 wave-0 ancestor). Recipe: `x11/linux-build/recipes/qtbase.mk` + the module recipes; build via `build-qt.sh` (NOT raw make). 5 one-time recipe walls fixed + committed (1bc1b6a, cef1068, 9197a3d, f5cf809, 49a34e6 + OOM guard 85aa99a). Memory: x11-qt-modules-build.
- Remaining (not started): on-device Q2 validation (qml -platform offscreen → wayland w/ QT_QUICK_BACKEND=software on iosc → a QtWidgets app); control-Depends audit + minos stamping before any repo publish.

## KF6 / KDE Plasma — IN PROGRESS, needs a status check
- `x11/linux-build/build-kf6.sh` — 6-wave driver: stage-1 native host tooling (ECM/kcoreaddons/karchive/kconfig/ki18n/kpackage) then the 40-unit cross build (kwin + plasma-nano/mobile closure, an audited subset — NOT all ~80). Recipes code-gen'd from `tools/gen-kf6-recipes.py` TABLE (edit the generator, not the .mk). Plan/audit: `x11/docs/kde-plasma-plan.md`. Memory: x11-kf6-layer.
- Was launched on a `procursus-vol-kf6` CLONE of vol-qt (keeps the Qt tree pristine), --cpus=8, log `x11/linux-build/kf6-build.log`. Stage-1 host tooling had 3 fixed walls (drop ecm_install_po_files_as_qm, host QML off, karchive WITH_*=OFF).
- **CURRENT: no container running (checked ~01:35) → the build finished, died, or stalled. FIRST ACTION: read `x11/linux-build/kf6-build.log`** — completed all waves (exit 0)? hit a wall (Exec format / undefined / CMake Error)? OOM-killed (cc1plus killed = the 16-CPU/8GB VM OOM → retry -j2, gotcha 85aa99a)? Report how many of the 40 units are in out/, then restart if stalled (OOM-guard full-speed-then-j2) and confirm `docker ps` shows it UP.

## Known KF6 walls pre-staged
- host qtwaylandscanner via QT_HOST_PATH; kguiaddons/kidletime need `-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner` in KF6_CMAKE_FLAGS (same trap qt-modules hit, adopted). if(APPLE) whack-a-mole pre-staged as audited TABLE seds for 5 risky units (3ccd62a). Downward gates already closed: qtbase round-2 printsupport (kxmlgui), qt5compat (KIO).

## Docker gotchas
- Volume-prune KILLS active builds (transient containers look unmounted between packages) — use builder-prune. VM: 16 CPU / 7.7GiB → default ninja -j18 OOMs big TUs (qmldom) → full-speed pass then -j2 retry.
