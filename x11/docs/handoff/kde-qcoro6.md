# kde-qcoro6 - host-side Plasma Desktop dependency slice

> **Current status (2026-07-03): resolved.** `qcoro6` is now built, integrated into the KDE
> staging/install set, and published with the first KDE app batch. Keep this file only as the
> original dependency note; use [`kde-kf6.md`](kde-kf6.md) for current Plasma/KDE status.

## Scope

QCoro6 is a small host-side packaging step toward `plasma-workspace`. The
Plasma 6.1.5 workspace tarball requires `find_package(QCoro6 REQUIRED
COMPONENTS Core DBus)`, so this package builds only the Qt 6 Core and DBus
QCoro libraries for the current `procursus-vol-kf6` stack.

## Files

- `linux-build/recipes/qcoro.mk`
- `linux-build/build_info/qcoro6.control`
- `linux-build/build_info/qcoro6-dev.control`

## Historical Integration Note

This was the missing integration step before Plasma Workspace packaging. It has since been wired
into the KDE staging/install path, and `qcoro6` is part of the deployed runtime set.

## Historical Desktop Gates Seen From Plasma Workspace 6.1.5

At the time, `plasma-workspace` probed several unbuilt or intentionally deferred
packages beyond libplasma and QCoro6: Plasma5Support, KF6KDED,
KF6NetworkManagerQt, KF6KirigamiAddons2, KF6QuickCharts, KSysGuard, KF6Screen,
KScreenLocker, ScreenSaverDBusInterface, Phonon4Qt6, Breeze, AppStreamQt,
UDev, PackageKitQt6, PolkitQt6-1, KExiv2Qt6, KIOExtras, and KIOFuse. Several
of these were optional in upstream CMake; the first-light workspace recipe chose the iOS cuts
documented in [`kde-kf6.md`](kde-kf6.md).
