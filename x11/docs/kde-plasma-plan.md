# KDE Plasma Mobile on iOS: build roadmap

The KDE flavor of the distribution chooser (see `x11-distribution-chooser` memory and
`docs/iosc-desktop-env.md`): KWin + Plasma Mobile on Qt 6 / KDE Frameworks 6, all built
from scratch because Procursus ships no Qt at all. Multi-week track; this doc maps it.

Why this flavor is structurally easier than GNOME, and where it is not:

- No JS-JIT wall. QML runs on the QV4 bytecode interpreter (`FEATURE_qml_jit=OFF`);
  nothing like the mozjs cross-compile saga.
- No introspection wall. All Qt codegen (moc, rcc, qmltyperegistrar, qmlcachegen, qsb,
  qtwaylandscanner) runs on the HOST via `QT_HOST_PATH`; nothing like g-ir-scanner
  needing to execute target code.
- The one real wall: Qt-on-GPU means qtwayland's EGL integration on ANGLE-Metal, the
  same problem the GTK4 gdk-wayland-on-ANGLE shim is working through right now (phase
  Q4 below). Everything before that wall runs on a software path that is fully useful.

## Version pins

| Component | Version | Why |
|---|---|---|
| Qt | 6.6.3 | qtbase already targeting it; Plasma 6.1 requires Qt >= 6.6.2 |
| KDE Frameworks | 6.3.x | minimum for Plasma 6.1 |
| Plasma | 6.1.x | first Plasma 6 series with mobile in decent shape; matches the pins above |

Single-version rule: the host Qt and the cross Qt must be the identical version, so any
bump is a coordinated rebuild of host tools + qtbase + every module.

## Layer Q: Qt

### Q1. qtbase round 1 (IN FLIGHT, kde-plasma agent, procursus-vol-qt)

`recipes/qtbase.mk` + `build-qt.sh`. Dylibs not frameworks, Qt's Darwin platform against
the iPhoneOS SDK, the `CONDITION MACOS` cmake fix, offscreen default QPA. Deliberately
minimal: opengl/egl, dbus, icu, xkbcommon, sql, printsupport all OFF.
Done criteria: `qt6-base` + `qt6-base-dev` debs in `out/`, `Qt6Config.cmake` staged into
`build_base` for the module builds.

### Q2. Module ladder (recipes written, this doc's companion; build gated on Q1)

`recipes/qt6-common.mk` (shared Apple/Darwin flags) plus, in build order:

1. `qtshadertools.mk` - qsb + Qt6ShaderTools; qtdeclarative's build dep. Bundled
   glslang/SPIRV-Cross, no new external deps.
2. `qtdeclarative.mk` - QML + QtQuick, the big one. JIT off; QtQuick renders via the
   software scenegraph adaptation until Q4.
3. `qtwayland.mk` - the wayland QPA, client only (`FEATURE_wayland_server=OFF`).
   Round 1 is wl_shm buffers; that still exercises xdg-shell, seats, clipboard, DnD
   against iosc.
4. `qtsvg.mk` - Breeze icons and Plasma themes are SVG everywhere.
5. `qtimageformats.mk` - tiff/webp (bundled), tga/icns/wbmp.

Driver: `build-qt-modules.sh` (separate from `build-qt.sh` on purpose, so the in-flight
qtbase build's mounted script is never edited). Stage 1 extends the host Qt with host
qtshadertools, qtdeclarative and qtwayland, because the cross builds resolve qsb,
qmlcachegen/qmlimportscanner and qtwaylandscanner through `QT_HOST_PATH`. The cross
qtwayland additionally wants the plain `wayland-scanner` on the host (apt: libwayland-bin)
and wayland-client staged in build_base (W0 debs; the driver gates on both).

On-device validation for Q2, in order:
1. `qml -platform offscreen` evaluates a Hello.qml (proves QV4 + type registration).
2. `qml -platform wayland` with `QT_QUICK_BACKEND=software` shows a window on iosc
   (proves the QPA end to end: buffers, frame callbacks, input).
3. A QtWidgets app on wayland (proves raster path + cursor/decoration plugins).

### Q3. qtbase round 2: +dbus, +xkbcommon

KF6 hard-requires QtDBus (KDBusAddons, KGlobalAccel, KNotifications, KWin's own
interfaces), and qtwayland keyboard handling follows QtGui's xkbcommon feature, so both
go ON before any KF6 work. The dbus daemon and libxkbcommon0 debs already exist (GNOME
and W0 tracks). Qt's private ABI means the Q2 modules get rebuilt afterwards; same
recipes, bump the deb revision. ICU stays off for now (Qt falls back to its own tables;
revisit if text segmentation bugs show up in Plasma).

### Q4. GL on ANGLE: the wall, and the plan

Naive qtwayland-EGL cannot work here: ANGLE's Metal backend has no real wayland-egl,
and its window surfaces want a CAMetalLayer (see `hardware-gles-angle-metal-cli`; GDK
hit the identical config wall on X11, and the gdk-wayland-on-ANGLE shim that
iosc-protocols is debugging now is the same problem one stack over).

Qt's escape hatch is cleaner than GTK's: the client buffer path in qtwayland is a
designed plugin interface (`wayland-graphics-integration-client`). Plan:

- qtbase round 2.5: `FEATURE_egl` + `FEATURE_opengles2` ON, pointed at
  `/var/jb/lib/angle/{libEGL,libGLESv2}.dylib`. Qt links EGL directly (it does not use
  epoxy), so this is cmake-level lib/include hints, not a loader shim.
- Write an `iosurface` client-buffer-integration plugin: QtQuick's RHI renders GLES
  through ANGLE into `EGL_ANGLE_iosurface_client_buffer` pbuffers (one-call API,
  validated on the A10), and the plugin hands the IOSurface to iosc over the existing
  zero-copy protocol instead of wl_egl_window.
- Coordinate with the gdk shim work in both directions; the EGL display bring-up
  (`EGL_PLATFORM_WAYLAND` vs `EGL_PLATFORM_ANGLE` on Metal) and the
  buffer-commit/fence details should end up shared knowledge, possibly shared code in
  the iosc glue.

This phase is not a gate for K/W1/P below; the software path carries them.

## Layer K: KDE Frameworks 6 (subset)

K0 first: pull the kwin, plasma-workspace and plasma-mobile 6.1 tarballs and audit the
actual `find_package` graphs before building anything. The lists below are the expected
shape, not gospel.

- extra-cmake-modules (ECM): first, trivial (cmake-only).
- Tier 1 (Qt-only deps): KConfig, KCoreAddons, KWidgetsAddons, KWindowSystem (wayland
  half), KIdleTime, KDBusAddons, KCrash, KGuiAddons, KItemViews, KCodecs, KArchive,
  KI18n (gettext via the proxy-libintl/libgtkintl precedent).
- Tier 2/3 for KWin + shell: KAuth (polkit deb already built), KService, KPackage,
  KSvg, KColorScheme, KConfigWidgets, KIconThemes, KNotifications, KCMUtils,
  KDeclarative, Kirigami, KGlobalAccel bits (kglobalacceld moved into the Plasma
  release set in 6; audit), Solid (expect heavy stubbing, it probes hardware),
  KScreenLocker (stub first; iosc already implements session-lock for later).
- Plasma-side libs released with Plasma, built in this layer: KDecoration3,
  KWayland, plasma-wayland-protocols, layer-shell-qt (iosc already speaks
  zwlr_layer_shell_v1 v4).

Recipe mechanics are uniform: cmake + ECM, `QT6_MODULE_CMAKE_FLAGS`-style Apple seeds,
host tools from `QT_HOST_PATH`. Expect the KF6 recipes to be near-clones of the Qt
module recipes with ECM added; the cost is count (~20 repos), not novelty.

## Layer W: KWin

- W1, nested first: `kwin_wayland` with its wayland backend running as an iosc client,
  compositing with the QPainter backend (`KWIN_COMPOSE=Q`) over wl_shm. Zero GL, zero
  DRM. This is the KDE analogue of mutter-on-iosc and the main de-risk gate: once a
  KWin-managed window shows up inside iosc, everything after is breadth, not depth.
  Build with X11 support OFF (mutter lesson: keep the xcb closure out of the link or
  dyld kills the library on device).
- W2, GL compositing: KWin renders through libepoxy, and our libepoxy0 already
  dispatches to ANGLE (`1.5.7+angle1`). The nested case then needs the same
  EGL-on-wayland answer as Q4; reuse the iosurface integration.
- W3, native backend: modeled on KWin's virtual backend, rendering into an IOSurface
  via ANGLE and presenting through libxios_glue, parallel to MetaBackendIOS (monitor
  manager, input from the Xios touch/pencil path, login1 stub reuse). Endgame; nested
  KWin is a perfectly usable intermediate since iosc stays the root compositor.
- Expected Linux-isms to patch or stub at W0 audit: libinput (nested KWin takes input
  from the host compositor; make sure the build can drop libinput), udev, logind
  (stub exists from the mutter work), libdrm (deb exists from the Xwayland track if a
  header-level dep survives).

## Layer P: Plasma Mobile

- P0 theming/data: breeze-icons, breeze style, plasma-integration, libplasma,
  plasma-activities (+ kactivities-stats).
- P1 plasma-workspace, patched down. The biggest patch surface of the whole track,
  treat it like the gnome-shell EDS patch-out: kscreenlocker stubbed (wire to iosc
  session-lock later), NetworkManager-qt off, PipeWire/screencast off, systemd/logind
  stubbed, geolocation off, appstream on (recipe exists). Deliverable is plasmashell
  starting under nested KWin.
- P2 the mobile shell: plasma-nano + plasma-mobile on top of plasmashell.
- P3 polish: virtual keyboard (qtvirtualkeyboard or maliit, or lean on the Xios
  tap+type injection path first), a settings-modules subset, session entry in the
  chooser with the stamp-minos floor computed over the KDE closure.

## Runtime plumbing (shared with the GNOME track)

dbus deb (built), fontconfig + fonts (xios-desktop-defaults), icon theme repack
pipeline, XDG_RUNTIME_DIR conventions from iosc, login1 stub, and the chooser gate
itself (`stamp-minos.py --json` closure floors).

## Risks, ranked

1. plasma-workspace patch surface: breadth risk, likely weeks of whack-a-mole.
2. qtwayland-on-ANGLE (Q4): the one depth risk; mitigated by the software-first
   sequencing, the plugin-shaped integration point, and the gdk shim solving the same
   problem in parallel.
3. KWin Linux-isms in the native (W3) path: libinput/udev/DRM assumptions.
4. KF6 repo count: mechanical but long; each unit is small compared to a GNOME module.
5. Rebuild churn from qtbase feature rounds (Q3, Q4): private ABI forces module
   rebuilds; batch the feature flips to keep rounds at two.

## Sequencing and rough effort

Q2 half a week once qtbase lands; Q3 half a week (batch with the Q2 rebuild); K one and
a half to two weeks; W1 one week; Q4+W2 one to two weeks, parallel to K/W1; P two to
three weeks. K tier 1 can start the moment Q2 debs exist.

## Coordination

procursus-vol-qt belongs to the kde-plasma agent until qtbase is done; the module
builds take the volume after an explicit handoff (or run on a clone, vol-qtmod), never
concurrently. Phase 2 gate: kde-plasma reports qtbase-package done and Qt6Config staged
in build_base. Device installs and on-device validation are owned by team-lead. Never
touch procursus-vol-gtk, -shell, or -xwl from this track.
