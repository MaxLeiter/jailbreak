# KDE Plasma on iOS: build plan and KF6 audit

> **Status (2026-10-25): done and shipped.** This was the original roadmap for the KDE
> flavor. Qt 6, the KF6 subset, KWin (nested, GPU-composited) and Plasma Desktop, Mobile
> and Nano all ship in production as `xios-kde 0.1.21`. Current state, open items and
> landmines are in [`handoff/kde-kf6.md`](handoff/kde-kf6.md). This file is kept for the
> layer K audit (the generator and recipes cite it) and for why the layers were ordered
> the way they were. Notes marked "later" record where reality moved past the plan.

The KDE flavor is KWin plus Plasma on Qt 6 and KDE Frameworks 6, all built from scratch
because Procursus ships no Qt at all.

Why this flavor was structurally easier than GNOME, and where it was not:

- No JS JIT wall. QML runs on the QV4 bytecode interpreter (`FEATURE_qml_jit=OFF`).
- No introspection wall. All Qt codegen (moc, rcc, qmltyperegistrar, qmlcachegen, qsb,
  qtwaylandscanner) runs on the host via `QT_HOST_PATH`.
- The one real wall was Qt on the GPU: QtWayland's EGL integration on ANGLE Metal (Q4).

## Version pins

| Component | Version | Why |
|---|---|---|
| Qt | 6.6.3 | Plasma 6.1 requires Qt >= 6.6.2 |
| KDE Frameworks | 6.3.x | minimum for Plasma 6.1 |
| Plasma | 6.1.x | first Plasma 6 series with Mobile in decent shape |

Single-version rule: host Qt and cross Qt must be the identical version, so any bump is a
coordinated rebuild of host tools, qtbase and every module.

## Layer Q: Qt

### Q1. qtbase round 1

`recipes/qtbase.mk` + `build-qt.sh`. Dylibs, not frameworks; Qt's Darwin platform against
the iPhoneOS SDK; the `CONDITION MACOS` CMake fix; offscreen default QPA. Round 1 was
deliberately minimal (opengl/egl, dbus, icu, xkbcommon, sql and printsupport off).

### Q2. Module ladder

`recipes/qt6-common.mk` (shared Apple flags) plus, in build order:

1. `qtshadertools.mk`: qsb + Qt6ShaderTools, qtdeclarative's build dependency.
2. `qtdeclarative.mk`: QML and QtQuick, JIT off.
3. `qt5compat.mk`: Qt6Core5Compat (QTextCodec) and the `Qt5Compat.GraphicalEffects` QML
   module. KIO 6.3 hard-requires Core5Compat. It sits after qtdeclarative because the QML
   module needs target Qt6Qml/Quick and host qmlcachegen.
4. `qtwayland.mk`: the Wayland QPA, client only.
5. `qtsvg.mk`: Breeze icons and Plasma themes are SVG everywhere.
6. `qtimageformats.mk`: tiff/webp and friends.

KWin also needs `qttools` (UiTools) and `qtsensors`, which are separate modules, not qtbase
components; QtConcurrent is in qtbase.

Driver: `build-qt-modules.sh`. Stage 1 extends the host Qt with host qtshadertools,
qtdeclarative and qtwayland, because cross builds resolve qsb, qmlcachegen,
qmlimportscanner and qtwaylandscanner through `QT_HOST_PATH`. Cross qtwayland also wants
the plain host `wayland-scanner` (apt: libwayland-bin) and wayland-client staged in
build_base.

### Q3. qtbase round 2: dbus, xkbcommon, printsupport, AT-SPI bridge

Required before KF6:

- dbus: KF6 hard-requires QtDBus. Linked against the staged libdbus
  (`FEATURE_dbus_linked=ON`).
- xkbcommon: QtWayland keyboard handling follows QtGui's xkbcommon feature.
- printsupport: kxmlgui links Qt6PrintSupport. There is no platform print engine on iOS,
  which is fine; kxmlgui only needs it to link.
- `accessibility_atspi_bridge`: lets Qt apps publish onto the a11y bus for the AT-SPI to
  VoiceOver track (`a11y-plan.md`).

A feature flip means: change the flags in `qtbase.mk`, remove
`build_work/qtbase/.build_complete` (the build dir is kept, so ninja rebuilds only what
changed), bump `DEB_QTBASE_V`, then rebuild every Q2 module against it (private ABI) and
bump their revisions. ICU stayed off for Qt.

### Q4. GL on ANGLE (later: shipped)

Plain ANGLE cannot speak Wayland. The iosc EGL shim, installed by the `angle` package as
`/var/jb/lib/angle/libEGL.dylib`, makes clients think they use Wayland EGL while it creates
an ANGLE Metal display and swaps IOSurface-backed Wayland buffers. Qt round 3 enables
ES2/EGL against ANGLE and keeps stock QtWayland `wayland-egl`; the private plugin fallback
was never needed. Details and the load-bearing EGL sequence are in
[`qtwayland-angle-iosurface.md`](qtwayland-angle-iosurface.md).

## Layer K: KDE Frameworks 6 (subset)

The K0 audit (2026-07-01) pulled the `find_package` graphs of kwin 6.1.5,
plasma-nano/plasma-mobile 6.1.5, libplasma 6.1.5 and every KF 6.3.0 framework in their
closure, and reduced them to **40 build units** (33 KF6 frameworks + ECM + 5
Plasma-released libraries + plasma-wayland-protocols). Pins: KF 6.3.0, Plasma libs 6.1.5,
plasma-wayland-protocols 1.13.0.

Everything is generated: `tools/gen-kf6-recipes.py` holds the audit TABLE (per-unit deps,
feature cuts, patches, packaging) and emits `recipes/<unit>.mk` and
`build_info/<deb>.control`; `recipes/kf6-common.mk` holds shared flags; `build-kf6.sh` is
the driver. Regenerate, don't hand-edit the `.mk` files.

### The audited subset (build DAG = wave order)

Each wave's dependencies are all in earlier waves. The generator prints the canonical
`TARGETS` string; keep `build-kf6.sh` in sync.

- **wave 0** (Qt-only or self-contained): extra-cmake-modules, plasma-wayland-protocols,
  kcoreaddons, karchive, kcodecs, kconfig, kwidgetsaddons, kitemviews, kitemmodels,
  kdbusaddons, kglobalaccel, kguiaddons, kwindowsystem, kidletime, ki18n, solid, sonnet,
  kirigami, breeze-icons, **kwayland**, **plasma-activities**, **layer-shell-qt**.
- **wave 1**: kauth, kcrash, kcolorscheme, kservice, kpackage, knotifications,
  kcompletion, **kdecoration**.
- **wave 2**: kconfigwidgets, kjobwidgets, ksvg.
- **wave 3**: kiconthemes, kbookmarks, ktextwidgets.
- **wave 4**: kxmlgui, kio.
- **wave 5**: kcmutils, kglobalacceld.

(Bold = Plasma-released, not a `frameworks/` repo.) The widget/KIO chain, not KWin, is
what drags in the widest frameworks: kcmutils pulls kxmlgui and kio, which pull bookmarks,
textwidgets (sonnet), completion, iconthemes, jobwidgets, notifications, service, solid
and auth. plasma-mobile's extra wants (KirigamiAddons, QCoro, KF6Screen, LibKWorkspace)
were left to the shell layer.

### Deliberate exclusions at K0

- **KDeclarative, NewStuff, KDED, kirigami-addons**: not in the KWin closure. Later: all
  four were built in the Plasma waves (`kf6-declarative`, `kf6-newstuff`, `kf6-kded`,
  `kf6-kirigami-addons`).
- **KWallet**: later built API-only (`BUILD_KWALLETD=OFF`).
- **KScreenLocker**: still not built.
- **KDocTools**: hard-disabled everywhere (`CMAKE_DISABLE_FIND_PACKAGE_KF6DocTools`).

### Feature cuts and patches (in the generator TABLE)

- **karchive**: bzip2/xz backends off; zip and gzip are all KPackage and KIconThemes need,
  and the extra backends would add blind Depends.
- **kauth**: FAKE backend. The real one needs polkit-qt6-1, and there is no privilege
  boundary to broker here.
- **knotifications**: Canberra demoted from REQUIRED, the freedesktop/DBus branch forced
  over the `if(APPLE)` NSUserNotification backend (absent on iPhoneOS), and the matching
  `.mm` source and AppKit link dropped.
- **ktextwidgets**: `WITH_TEXT_TO_SPEECH=OFF` (ON pulls the whole qtspeech module).
- **kio**: ACL and KF6DocTools off. Requires Qt6Core5Compat. Later rebuilds let iOS use
  KIOCore's Unix QtDBus branch (for the Workspace `desktop:/` worker) while keeping the
  AppKit `kiod` and DiskArbitration paths off.
- **kwindowsystem / kguiaddons / kidletime**: X11 forced off, Wayland forced on. Each
  carries `-setup` seds that keep the Wayland option alive through the platform guards
  and delete the macOS backends (kguiaddons AppKit colour-scheme watcher, kidletime
  Carbon probe and osx poller). Their protocol codegen runs the host qtwaylandscanner,
  and `build-kf6.sh` hard-gates on `${HOSTQT}/libexec/qtwaylandscanner` so a pre-modules
  volume clone fails fast.
- **Plain wayland-scanner trap**: the W0 deb stages an arm64 iOS `wayland-scanner` into
  build_base, and the cross find-root prefers it over `/usr/bin` ("Exec format error").
  `KF6_CMAKE_FLAGS` pins `-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner`.
- **qtbase private headers** gated `UNIX AND NOT MACOS` (e.g. qgenericunixthemes) are not
  staged. A unit that includes one needs a source patch in its TABLE seds, not a qtbase
  round.
- **solid**: the K0 cut was fakehw only (the `elseif(APPLE)` IOKit branch is macOS-only).
  Later: that left PowerDevil reading 0% battery. `solid-ios-fixes.sh` now swaps the
  Apple branch to the UPower backend, shipped as `kf6-solid 6.3.0+ios2`.
- **breeze-icons**: `BINARY_ICONS_RESOURCE=OFF` (plain files); wave 0 because KIconThemes
  requires it at build time.

### Gates this layer opened against lower layers

1. qtbase round 2 is a hard prerequisite: KF6 needs QtDBus throughout and kxmlgui needs
   QtPrintSupport. `build-kf6.sh` refuses to start if the staged qtbase lacks
   `Qt6DBusConfig.cmake` or `Qt6PrintSupportConfig.cmake`.
2. qt6-5compat (Core5Compat for KIO) depends on qt6-declarative because the same deb ships
   the GraphicalEffects QML module.

### Recipe mechanics

CMake + ECM with `KF6_CMAKE_FLAGS` (= `QT6_MODULE_CMAKE_FLAGS` + KDE install-dir pins +
`KF6_HOST_TOOLING`). kconfig, kcoreaddons and kpackage ship build-time tools
(kconfig_compiler_kf6, desktoptojson, kpackagetool6) that every downstream CMake runs, so
`build-kf6.sh` stage 1 builds ECM and those (plus karchive and ki18n) natively into
`build_tools/kf6-host`, and cross builds find them through `-DKF6_HOST_TOOLING`, the same
branch Android KDE builds take. `kf6-common.mk` pins gettext tools to host `/usr/bin/*` so
cross builds never execute staged iOS gettext binaries.

## Layer W: KWin

- **W1, nested** (done): `kwin_wayland` with its Wayland backend as an iosc client. First
  light was the QPainter scene over a CPU copy of client IOSurfaces, built with X11 off
  (the mutter lesson: keep the xcb closure out of the link or dyld kills the library).
- **W2, GL compositing** (done): KWin renders through libepoxy dispatching to ANGLE,
  imports client IOSurfaces as EGL textures and renders into IOSurface pbuffers. Shipped
  since `kwin 6.1.5+ios27`.
- **W3, native backend** (not done, not needed so far): a KWin backend rendering straight
  into the Xios IOSurface, parallel to MetaBackendIOS. Nested KWin under iosc works well
  enough that this has not been worth doing.

libinput, udev and DRM-native paths are trimmed; `libdrm2`, `libgbm1` and
`libdisplay-info1` exist as shim packages because KWin links them.

## Layer P: Plasma (done)

- P0 theming and data: breeze-icons, Breeze, plasma-integration, libplasma,
  plasma-activities and activities-stats.
- P1 plasma-workspace: the biggest patch surface of the track. kscreenlocker,
  NetworkManager-qt, PipeWire and logind are cut; plasmashell runs under nested KWin.
- P2 shells: the real upstream Plasma Desktop, Plasma Mobile and Plasma Nano.
- P3 polish: the iOS keyboard reaches KDE through a `zwp_input_method_v1` bridge that KWin
  launches (`--inputmethod`, `ios-inputd --proxy`), not qtvirtualkeyboard or maliit; see
  `osk-plan.md`, "KDE flavor". System Settings ships a KCM subset.

## GPU entitlements on every GL-touching binary

Any process that creates the ANGLE Metal display must carry the GPU IOKit user-client
entitlements (`AGXDeviceUserClient`, `IOGPUDeviceUserClient`) and must not carry
`com.apple.private.security.no-container`, or `MTLCreateSystemDefaultDevice` returns nil
and display creation fails silently. The entitlement goes on the executable the kernel
execs; the Procursus `SIGN` macro signs dylibs and bundles with a bare `ldid -S` and plain
executables with `entitlements/$(2)`, so library recipes need no change. In practice that
is `kwin_wayland`, `plasmashell`, `systemsettings`, the `qml` smoke launcher and any
GL-initializing helper. The shipped recipes use `$(call
SIGN,<pkg>,iosc-gl-ent.xml,,,nogeneral)`, then the host DER finalizer; see the signing
section of `handoff/kde-kf6.md`.
