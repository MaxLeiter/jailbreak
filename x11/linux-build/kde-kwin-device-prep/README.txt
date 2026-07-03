KDE/KF6/KWin/Plasma first-light device prep bundle.

Created by: linux-build/prep-kde-kwin-device.sh
Remote path: /var/jb/tmp/kde-kwin-prep

Contents:
- debs/: runtime Qt6, KF6, KWayland/KWin, Plasma Workspace, xios-session, and shim packages
- install-on-device.sh: installs the package set and writes RUN-LATER.txt

This bundle deliberately excludes xios-kde, plasma-mobile, and plasma-nano.
It does not launch any compositor or session process.
