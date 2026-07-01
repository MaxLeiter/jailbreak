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

Naive qtwayland-EGL cannot work here: ANGLE's Metal backend has no wayland platform at
all, and its window surfaces want a CAMetalLayer (see `hardware-gles-angle-metal-cli`;
GDK hit the identical config wall on X11). This is the ONE real depth risk in the track.

Qt's escape hatch is cleaner than GTK's: the client buffer path in qtwayland is a
designed plugin interface (`wayland-graphics-integration-client`), so the QPA creates the
ANGLE Metal display itself and never asks ANGLE for a wayland platform.

The concrete EGL bring-up below is transferred VERBATIM from team-lead's on-device P0.1
validation of the GTK4/gdk-wayland-on-ANGLE path (2026-07-01); it is `xios_egl.c`'s exact
sequence and must be matched byte-for-byte in the qtwayland integration plugin:

1. Display bring-up (the big one): the CORE `eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE)`
   returns `EGL_NO_DISPLAY` with `err=SUCCESS` on this ANGLE build — a silent no-op. ONLY
   the EXT entrypoint works: resolve `eglGetPlatformDisplayEXT` via `eglGetProcAddress`,
   call it with an `EGLint` attrib list (NOT `EGLAttrib`) =
   `{EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE}` and
   `native_display = EGL_DEFAULT_DISPLAY`. Do NOT pass the `wl_display` as the native
   display — ANGLE cannot make a Metal display from it (also `NO_DISPLAY`). Entrypoint and
   attrib width are both load-bearing; they are not spec-interchangeable here.
2. There is NO `EGL_PLATFORM_WAYLAND` use anywhere. Surfaces come from `wl_egl_window` +
   `EGL_ANGLE_iosurface_client_buffer` (the one-call pbuffer API, validated on the A10);
   the plugin hands the resulting IOSurface to iosc over the existing zero-copy protocol.
3. Swap barrier: `EGL_KHR_fence_sync` works on the A10 (validated) — use it, not
   `glFinish`.
4. Packaging is not optional (this cost team-lead hours): the process needs GPU IOKit
   entitlements — `AGXDeviceUserClient` + `IOGPUDeviceUserClient` — or
   `MTLCreateSystemDefaultDevice` returns nil and the ANGLE Metal display creation fails
   with `NO_DISPLAY`, silently. See the packaging note below; this is baked into the KDE
   flavor from the start, not bolted on at Q4.

Build side, qtbase round 2.5: `FEATURE_egl` + `FEATURE_opengles2` ON, pointed at
`/var/jb/lib/angle/{libEGL,libGLESv2}.dylib`. Qt links EGL directly (it does not use
epoxy), so this is cmake-level lib/include hints, not a loader shim.

This phase is not a gate for K/W1/P below; the software path carries them.

## Layer K: KDE Frameworks 6 (subset)

K0 audit is DONE (2026-07-01). The `find_package` graphs of kwin 6.1.5,
plasma-nano/plasma-mobile 6.1.5, libplasma 6.1.5 and every KF 6.3.0 framework in their
closure were pulled from invent.kde.org and reduced to the minimal subset below. The
result is **40 build units** (33 KF6 frameworks + ECM + 5 Plasma-released libraries +
plasma-wayland-protocols). Pins: KF 6.3.0, Plasma libs 6.1.5, plasma-wayland-protocols
1.13.0. Everything is code-generated: `tools/gen-kf6-recipes.py` holds the canonical
audit TABLE (per-unit deps, feature cuts, patches, packaging) and emits
`recipes/<unit>.mk` + `build_info/<deb>.control`; `recipes/kf6-common.mk` holds the
shared flags/macros; `build-kf6.sh` is the driver. Regenerate, don't hand-edit the .mk
files.

### The audited subset (build DAG = wave order)

`build-kf6.sh` runs these in wave order (each wave's deps are all in earlier waves). The
generator prints the canonical `TARGETS` string; keep the two in sync.

- **wave 0 — no KF6 deps** (Qt-only, or self-contained): extra-cmake-modules,
  plasma-wayland-protocols, kcoreaddons, karchive, kcodecs, kconfig, kwidgetsaddons,
  kitemviews, kitemmodels, kdbusaddons, kglobalaccel, kguiaddons, kwindowsystem,
  kidletime, ki18n, solid, sonnet, kirigami, breeze-icons, **kwayland**,
  **plasma-activities**, **layer-shell-qt**.
- **wave 1**: kauth, kcrash, kcolorscheme, kservice, kpackage, knotifications,
  kcompletion, **kdecoration**.
- **wave 2**: kconfigwidgets, kjobwidgets, ksvg.
- **wave 3**: kiconthemes, kbookmarks, ktextwidgets.
- **wave 4**: kxmlgui, kio.
- **wave 5**: kcmutils, kglobalacceld.

(Bold = Plasma-released, not a `frameworks/` repo.) What each direct consumer forces:
plasma-nano pulls kwindowsystem/ki18n/kservice/kitemmodels + libplasma + kwayland;
libplasma pulls the archive/config/globalaccel/guiaddons/i18n/iconthemes/kio/
windowsystem/notifications/package/kirigami(Platform)/kcmutils/svg set + plasma-activities
+ plasma-wayland-protocols; kwin pulls auth/colorscheme/config/configwidgets/coreaddons/
crash/dbusaddons/globalaccel/guiaddons/i18n/idletime/package/service/svg/widgetsaddons/
windowsystem + kwayland + kdecoration + kglobalacceld (+ notifications, screenlocker
stubbed). **The widget/KIO chain, not kwin, is what drags the widest frameworks in**:
kcmutils→kxmlgui+kio→(bookmarks, textwidgets→sonnet, completion, iconthemes, jobwidgets→
notifications, service, solid, auth). plasma-mobile additionally wants KIO, KirigamiAddons,
QCoro, KF6Screen, NetworkManagerQt, ModemManagerQt, LibKWorkspace — **deferred to layer P**
(shell layer), not part of this KWin-enabling KF6 tier.

### Deliberate exclusions (audited, not oversights)

- **KDeclarative**: kwin references it only under `KWIN_BUILD_KCMS`; we build KCMs off for
  bring-up, so it drops out of the KWin-enabling set (re-add with the KCM subset in P).
- **NewStuff, XmlGui-for-KCMs, KScreenLocker**: KCM/store/lock features, off for W1.
- **KWallet, KDED, KDocTools, kirigami-addons**: not in the KWin closure; KDocTools is
  hard-disabled everywhere (`CMAKE_DISABLE_FIND_PACKAGE_KF6DocTools`).
- **PlasmaActivities daemon / KActivities-stats, kglobalaccel daemon extras**: the client
  libs are in; the daemons wait for layer P.

### Feature cuts and patches the audit found (baked into the generator TABLE)

- **karchive**: bzip2/xz backends OFF — zip+gzip is all KPackage/KIconThemes need, and
  the extra backends would add blind Depends (the libsqlite3-1 naming lesson).
- **kauth**: FAKE backend — the real one needs polkit-qt6-1 (unbuilt) and the jailbreak
  has no privilege boundary to broker.
- **knotifications**: two `-setup` seds — Canberra demoted from REQUIRED (no
  libcanberra chain; code already guards on the target), and the freedesktop/DBus branch
  forced over the `if(APPLE)` NSUserNotification backend (absent on iPhoneOS).
- **ktextwidgets**: `WITH_TEXT_TO_SPEECH=OFF` — ON would pull the whole qtspeech module.
- **kio**: ACL + KF6DocTools disabled; Darwin spares us LibMount (Linux-guarded) and X11
  (APPLE-guarded). **Requires Qt6Core5Compat** (QTextCodec) → a qt6-5compat module gap.
- **kwindowsystem / kguiaddons / kidletime**: X11 forced off, Wayland forced on. The
  `if(APPLE)` idle/keys/window backends target macOS AppKit/ApplicationServices, absent on
  iPhoneOS — expect phase-2 src/CMakeLists patches to force the wayland backends (same
  class as the knotifications fix).
- **solid**: on APPLE the backend is IOKit (macOS framework); if it won't compile on the
  iPhoneOS SDK, patch the backend list down to fake/empty (KIO only needs the lib to link).
- **breeze-icons**: `BINARY_ICONS_RESOURCE=OFF` (plain files, friendlier to the icon
  repack pipeline); it's in wave 0 because KIconThemes REQUIREs it at build.

### Two gates this layer opens against lower layers

1. **qtbase round 2 is a hard prerequisite** (plan Q3): KF6 needs QtDBus throughout, and
   **kxmlgui needs QtPrintSupport** — qtbase round 1 built both OFF. So Q3's flag flip is
   `dbus + xkbcommon + printsupport` (cups stays OFF). `build-kf6.sh` refuses to start if
   the staged qtbase lacks `Qt6DBusConfig.cmake` / `Qt6PrintSupportConfig.cmake`.
2. **Qt module gaps for KDE** (report to qt-modules): **qt5compat** (Qt6Core5Compat, hard
   KIO dep) is not in the current module ladder — it needs adding. kwin itself also wants
   Concurrent/Core5Compat/UiTools/Sensors from qtbase and a couple of QML modules; those
   are qtbase-config / qtdeclarative-module questions for the W layer, flagged early here.

### Recipe mechanics (uniform)

cmake + ECM, `KF6_CMAKE_FLAGS` (= `QT6_MODULE_CMAKE_FLAGS` + KDE install-dir pins +
`KF6_HOST_TOOLING`). The one novelty over the Qt module recipes is KDE's **host tooling
cross mechanism**: kconfig/kcoreaddons/kpackage ship build-time tools
(kconfig_compiler_kf6, desktoptojson, kpackagetool6) that every downstream cmake runs, so
`build-kf6.sh` stage 1 builds ECM + those (+ their deps karchive/ki18n) NATIVELY into
`build_tools/kf6-host` and the cross builds resolve them through `-DKF6_HOST_TOOLING`
(the same Config.cmake branch Android KDE builds take). Qt host codegen keeps flowing
through `QT_HOST_PATH`. There is still **no introspection/on-device-scan wall** anywhere
in the KDE track.

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

### GPU entitlements on every GL-touching binary (mandatory, P0.1-validated)

Any process that creates the ANGLE Metal display must be signed with the GPU IOKit
entitlements (`AGXDeviceUserClient` + `IOGPUDeviceUserClient`; the full client set is
`x11/wayland/iosc-gpu-client-ent.xml`) and must NOT carry
`com.apple.private.security.no-container`, or `MTLCreateSystemDefaultDevice` returns nil
and display creation fails silently. Team-lead confirmed the exact model on-device (P0.1,
kgx): the GPU entitlement went on the EXECUTABLE (`/var/jb/usr/bin/kgx`) while the EGL
shim and ANGLE dylibs stayed bare `ldid -S`; no bundle re-sign. It lands on executables
because entitlements are a property of the Mach-O the kernel exec's, and the Procursus
`SIGN` macro already signs dylibs/bundles with a bare `ldid -S` (no entitlements) while
signing plain executables with `entitlements/$(2)`. So the Qt/KF6 module recipes need no
change. The rule of thumb: whatever initializes the QtQuick/QRhi OpenGL context is the
process that needs the entitlement — for the runtime that is the compositor
(`kwin_wayland`) and the shell (`plasmashell`), plus the `qml` launcher for smoke tests,
and any GL-initializing Qt tool/daemon we ship. Practical steps for the W/P recipes: copy
`iosc-gpu-client-ent.xml` into `build_misc/entitlements/` and call
`$(call SIGN,<pkg>,iosc-gpu-client-ent.xml)` for the executable's package. Bake this in
from the first KWin recipe; do not defer it to Q4.

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
