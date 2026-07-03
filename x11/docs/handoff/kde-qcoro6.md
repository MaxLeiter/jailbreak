# kde-qcoro6 - host-side Plasma Desktop dependency slice

## Scope

QCoro6 is a small host-side packaging step toward `plasma-workspace`. The
Plasma 6.1.5 workspace tarball requires `find_package(QCoro6 REQUIRED
COMPONENTS Core DBus)`, so this package builds only the Qt 6 Core and DBus
QCoro libraries for the current `procursus-vol-kf6` stack.

## Files

- `linux-build/recipes/qcoro.mk`
- `linux-build/build_info/qcoro6.control`
- `linux-build/build_info/qcoro6-dev.control`

## Integration Note

`linux-build/build-plasma-desktop.sh` does not copy the QCoro recipe yet. To
integrate it into the desktop lane, add `qcoro.mk` to the recipe copy list,
`qcoro6*.control` to the control copy list, include `qcoro-package` before the
future `plasma-workspace-package` target, and collect `qcoro6_*.deb` plus
`qcoro6-dev_*.deb` into `/out`.

Until that orchestration change is made, build it with an explicit Docker
command that mounts the existing recipe/control directories and runs
`make qcoro-package` inside the `procursus-vol-kf6` Procursus tree.

## Remaining Desktop Gates Seen From Plasma Workspace 6.1.5

`plasma-workspace` still probes several unbuilt or intentionally deferred
packages beyond libplasma and QCoro6: Plasma5Support, KF6KDED,
KF6NetworkManagerQt, KF6KirigamiAddons2, KF6QuickCharts, KSysGuard, KF6Screen,
KScreenLocker, ScreenSaverDBusInterface, Phonon4Qt6, Breeze, AppStreamQt,
UDev, PackageKitQt6, PolkitQt6-1, KExiv2Qt6, KIOExtras, and KIOFuse. Several
of these are optional in upstream CMake, but the first workspace recipe will
need to decide which ones to package and which integrations to patch out for
iOS first-light.
