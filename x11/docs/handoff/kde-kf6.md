# kde-kf6: the KDE Plasma flavor (Qt 6, KF6, KWin, Plasma)

The KDE flavor: Qt 6.6.3, a KDE Frameworks 6.3 subset, KWin and Plasma 6.1.5, and the
KDE apps, cross-built Linux to iOS in Docker on the Procursus toolchain. Everything here
is shipped and in production; this file is what you need to keep it working and change it.

Versions below are from the committed `repo/Packages` (which is what production serves),
checked 2026-10-25.

## Current state

### What ships

`xios-kde 0.1.21` (`x11/packages/meta/xios-kde/DEBIAN/control`) depends on `xios-core
(>= 0.1.13)`, `iosc (>= 0.9.43)`, `xios-session (>= 1.0.82)`, `xios-desktop-theme`,
`libjpeg62-turbo`, and pins the KDE parts at their published builds:

| Part | Published |
|---|---|
| KWin | `kwin 6.1.5+ios33` (`kwin-dev +ios30`) |
| Shells | `plasma-workspace +ios14`, `plasma-desktop +ios10`, `plasma-mobile +ios23`, `plasma-nano +ios3` |
| Settings / system | `systemsettings +ios8`, `kscreen` and `libkscreen +ios2`, `powerdevil +ios2`, `kf6-kded 6.3.0+ios2`, `breeze +ios2`, `kf6-breeze-icons` |
| Apps | Konsole, Dolphin, KCalc, Ark, Gwenview `24.08.0+ios1`; KWrite `+ios3`; Okular `+ios3`; Kate `+ios4` |
| Qt | `qt6-base 6.6.3-5+ios1`, `qt6-declarative 6.6.3+ios2`, `qt6-wayland 6.6.3-1+ios3` |

The index carries 103 `kf6-*` packages. The full closure is about 176 packages and about
610 MB installed (measured for `xios-kde 0.1.11`). The iOS 16.5 floor comes from KWin's
`libdrm2` / `libgbm1` / `libdisplay-info1` shim chain.

### How to run it

- `xios-session kde` (same as `kde-desktop`), `kde-mobile`, `kde-nano`, or the KDE Plasma,
  Plasma Mobile and Plasma Nano rows in the Xios picker. `--slot <name>` runs a parallel
  session. `xios-session presets` lists what can start.
- Since `xios-session 1.0.82` a switch to KDE is preflighted first: if iosc,
  `kwin_wayland`, `plasmashell` or `xios-setsid` is missing, it exits 69 and leaves the
  running desktop alone. The preflight and slot model are documented once, in
  `session-launcher.md`.
- `bin/xios-kde-smoke [desktop|mobile|nano]` is the reusable device smoke: launch,
  optional `--drawer`, `--app NAME`, `--launcher kickoff|kicker --query TEXT`, input
  probes, screenshot and collect, and `--slot <name>` so it does not take over the shared
  display. Use it instead of hand-written KWin/Plasma blocks.

### How the session is put together

`x11/wayland/run-kde-plasma.sh` (shipped in `xios-session`) builds a nested stack:

- iosc owns the output IOSurface (2880x2160 landscape) and talks to the Xios app.
- `kwin_wayland --wayland-display <iosc> --socket kwin-ios-test --scale 2.75` runs as an
  iosc client. `KWIN_XIOS_HOST_OUTPUT_SCALE=2` (an Xios-only contract added in `kwin
  +ios33`) keeps KWin's buffer at iosc's fixed physical mode while the 2.75 scale only
  sets Plasma's logical geometry. Override with `XIOS_KDE_OUTPUT_SCALE` (host) and
  `XIOS_KDE_DEFAULT_SCALE` (Plasma).
- `kactivitymanagerd`, `kded6 --replace` and the GPU-entitled `plasmashell` run on KWin's
  socket and one session bus. `KDE_PLASMA_FLAVOR=desktop|nano|mobile` picks the shell
  package. Desktop sets `IOSC_FULLSCREEN_TOPLEVELS=1`; Mobile also sets
  `IOSC_NO_OUTPUT_TRANSFORM=1` and sizes KWin from the foregrounded Xios orientation.
- iosc and the KWin tree start through `$LIBEXEC/xios-setsid` from `xios-session-stubs`,
  falling back to `setsid`, and fail early with an install hint if neither exists
  (2026-10-25, e2670012; it used `nohup` + `setsid` and a python3 shim before).
- When KWin exits, the launcher marks only its own status record `down` and clears the
  active marker only if it still names its preset (`xios-session 1.0.78`, device-checked
  2026-07-30).

Rendering is GPU end to end: KWin's nested backend creates ANGLE Metal EGL contexts,
renders its output into IOSurface pbuffers, and imports client IOSurfaces directly as EGL
textures (`BufferType::Iosc`, orientation from the `IOSC_IOSURFACE_FORMAT_FLAG_TOP_LEFT`
flag). The CPU row-copy path survives only as the `map()` fallback. KWin ships 37 builtin
effects, scripted effects, scripts, Aurorae, the NightLight plugin and its KCMs; on device
(`+ios26`) KWin's D-Bus reported `blur` and `contrast` active with no GL failures.

The iOS keyboard works through KWin: the launcher starts KWin with `--inputmethod` and
`ios-inputd --proxy` (shipped in the iosc package) as its input method, which registers as
iosc's input-method proxy. KWin filters `zwp_input_method_v1` to the child it launches, so
ios-inputd cannot run beside it. `KDE_AUTO_KEYBOARD=0` turns it off. Details in
`../osk-plan.md`.

Defaults the launcher and `xios-desktop-defaults 1.1.14` set: tablet mode on
(`[Input] TabletMode=on`), a 16-logical-px cursor (KWin multiplies by the scale),
Breeze Dark, a 48 px minimum bottom panel, locale `LANG=C` / `LC_CTYPE=UTF-8` /
`FC_LANG=en`. Plasma Desktop's stock layout is one bottom panel; top or side panels are
user configuration, not a missing default.

### Open items

- **`kwin +ios34` is built in the recipe but not published.** `kwin.mk` is at `+ios34`,
  which carries d8934cbd (2026-08-02): KWin deallocated an IOSurface's mach send right
  before iosc had extracted it, so a cursor-swapchain rebuild (arrow to I-beam) could make
  iosc fail the import and kill KWin with every Plasma client. Ownership now moves to a
  `wl_display` sync callback. The iosc half (an import failure is no longer a protocol
  error) shipped with iosc 0.9.47, so production is protected from the crash but can
  still drop a frame. Publishing `+ios34` needs a build, staging and a device check.
- **Brightness does not reach the panel.** `powerdevil +ios2` exports
  `org.kde.Solid.PowerManagement.Actions.BrightnessControl` through
  `XiosBacklightDetector` (`linux-build/recipes/powerdevil-xiosbacklight.{h,cpp}`) and writes the
  synthetic sysfs node, but `BKSDisplayBrightnessSet` is inert outside SpringBoard on
  iPadOS 17.6.1. The brightness applet stays out on purpose. See `polish.md` #15.
- **Plasma Nano is first light only**: it starts and stays up but shows a deliberately
  sparse surface (the stock Mycroft layout crashed). Add a panel back one shipped applet
  at a time.
- **Not built**: kscreenlocker; the keyboard, mouse, touchpad, tablet and touchscreen
  KCMs (they need KWin's libinput-only `InputDevice` interface, and input comes from iosc);
  the fonts KCM (its preview engine is Xft); the `systemmonitor` and `devicenotifier`
  applets (no KSysGuard port), `cameraindicator` (KPipeWire). Dolphin has no Baloo
  search or metadata editing. Konsole's inline audio/video escape is compiled out (no Qt
  Multimedia); inline images and the bell work.
- **Log noise**: repeated `QKqueueFileSystemWatcherEngine::addPaths` misses. Non-fatal.

## Gotchas and landmines

### Signing and GPU

- The entitlement belongs on the executable that creates the ANGLE Metal display, not on
  libraries. `kwin.mk`, `plasma-workspace.mk` and `systemsettings.mk` sign with
  `wayland/iosc-gl-ent.xml` plus `nogeneral`. Never merge the general no-container set:
  with it, `MTLCreateSystemDefaultDevice` returns nil and EGL fails silently.
- Signatures made inside the build container are XML-visible but DER-less. That made
  `task_for_pid` fail with `0x5` in KWin's IOSurface import and Qt clients report
  `EGL not available`. Run the host finalizer `linux-build/resign-graphics-packages.py`
  on the debs before any install or publish. It now skips binaries that are already
  final and rejects a re-sign that still lacks DER slot 7. Finalize a clean directory,
  since stale old debs in `linux-build/out/` can trip it.
- An early note said `platform-application` broke plasmashell's EGL (`plasma-workspace
  +ios4`). The shipped tier includes that key and works, so do not treat that note as a
  rule.
- **`EGL_NO_DISPLAY` with `eglGetError() == EGL_SUCCESS` (logged `3000`) means ANGLE
  refused a second Metal display in the same process**, not resource exhaustion. KWin's
  backend made one and Qt's Wayland QPA asked for another. Fixed by 4ef068ab (2026-07-29),
  which caches the process display in `wayland/iosc_egl_shim.c`; device-checked over five
  KDE launches on 2026-08-06. The `0x3003` (`EGL_BAD_ALLOC`) on plasmashell's surface
  that follows is downstream; do not chase it.
- `/var/jb/tmp/iosc.log` is written only by a non-slot iosc. In a slot session it holds
  leftover text from an earlier run, so confirm from `ps` which compositor you are looking
  at before reading it. A whole investigation (2026-08-02) went wrong on this.

### KWin build

- The epoxy vs iOS `OpenGLES.framework` header collision is solved by the force-included
  gl-coexist shim in `kwin-ios-compat.h` (generated by `kwin-ios-fixes.sh`): include
  `<epoxy/gl.h>` first, then pre-define the OpenGLES include guards so Qt's `qopengl.h`
  defers to epoxy. It is scoped with `target_compile_definitions(kwin PRIVATE
  KWIN_IOS_GL_COEXIST=1)`; putting it in global `CMAKE_CXX_FLAGS` breaks CMake's GLESv2
  probe and cascades Qt6Gui/Qt6Quick to NOT-FOUND. `KWIN_IOS_QT_NO_OPENGL` is now only a
  capability fallback the header sets when `QT_FEATURE_opengl < 0`.
- Fixers must be idempotent. A retried build reran `kwin-ios-fixes.sh` on the existing
  tree and an unanchored pattern turned the QPA OpenGL capability back off (61087ff8).
- `linux-build/recipes/xios-cache-fingerprint.sh` only hashes what a recipe names. Helpers
  reached indirectly (`kwin-ios-gpu/`, the powerdevil backlight sources, `kate-ios-fixes.sh`)
  were added as inputs in b0e506bb; add new indirect helpers there or edits will not
  rebuild.
- `kwin-ios-gpu-backend.sh` and `linux-build/recipes/kwin-ios-gpu/` own the GPU backend and QPA
  sources on top of the Darwin pass in `kwin-ios-fixes.sh`. The static QPA plugin gets
  IOSurfaces through the exported `GraphicsBuffer` interface, not `IoscClientBuffer` RTTI
  across the `libkwin` dylib boundary. `glFinish()` stays at the three cross-process
  present points until a native fence path is proven on device.
- X11, DRM-native, virtual and libinput backends are trimmed; nested Wayland, fake input
  and KGlobalAccel stay.

### Keep-lists hide whole features

Three times a first-light keep-list silently dropped a large feature, and each looked like
a missing port until someone read the fixer:

- `kwin-ios-fixes.sh` overwrote `src/plugins/CMakeLists.txt` with two entries, so KWin
  shipped no effects, scripts or decorations until `+ios26` restored upstream's file.
- `plasma-desktop-ios-fixes.sh` skipped `kcms/` wholesale; `+ios9` brought back 10 KCMs.
- `plasma-workspace-ios-fixes.sh` commented out most applets behind
  `ios-firstlight-skip`, which is why there was no battery readout and the tray showed a
  `?` badge; `+ios13` restored ten.

Before calling a KDE feature missing, check the unit's `-ios-fixes.sh` keep-list.

### Darwin/iOS traps in KDE source

- **`MACOSX_BUNDLE` defaults ON** in the iOS CMake toolchain. Any `add_executable`
  without `ecm_mark_nongui_executable` becomes an `.app`, installs to `/Applications/KDE`
  and silently vanishes from the deb, or leaves a D-Bus `Exec=` pointing at nothing. Fix:
  `set_target_properties(<tgt> PROPERTIES MACOSX_BUNDLE FALSE)` in the fixer.
  `kscreen-doctor` lives in libkscreen (fixed in `libkscreen +ios2`); Dolphin's
  `servicemenuinstaller` had the same problem.
- **Qt defines `Q_OS_DARWIN` and `Q_OS_IOS` but not `Q_OS_MACOS`**, so upstream's macOS
  exclusions miss iOS. Kate's `daemon()` guard did exactly that: Kate forked, the parent
  exited 0, and the child's stderr went to `/dev/null`. KWrite owns `libkateprivate`, so a
  fix to Kate alone changes nothing at runtime; patch both.
- KConfig stores user config under `/var/root/Library/Preferences` (`kwinrc`,
  `kwinoutputconfig.json`, applet rc files), and Qt app data under `Library/Application
  Support`. The system XDG `kwinrc` was not merged in the live session, so the launcher
  seeds `TabletMode` with `kwriteconfig6` when the user file has no choice, and links
  selected Application Support paths to `/var/jb/usr/share`. A stale applet rc file looks
  like a packaging bug; `run-kde-plasma.sh` migrates known first-light fingerprints and
  keeps a `.before-xios-*` backup.
- App bundles go under `/var/jb/Applications/KDE`, never package-root `/Applications`.
- `KSharedDataCache` hit an `EXC_GUARD` in `munmap`; `kf6-coreaddons +ios2` routes it to
  the non-mmap backend.
- QtQuick `Flickable` SIGBUSed in its constructor. `qt6-declarative 6.6.3+ios2`
  (`qtdeclarative-ios-fixes.sh`) avoids the Darwin QPA style-hint QVariant path. Plasma
  Mobile's MobileShell QML is embedded in its plugin through qrc/qmlcache, so it has to be
  patched in source before CMake snapshots it. `linux-build/tools/scan-qml-shim-api.py`
  and `linux-build/check-plasma-ios-providers.sh` check the Mobile provider surface.
- `libjpeg62-turbo 3.1.1+ios1` fixed Qt's `Wrong JPEG library version: library is 62,
  caller expects 80` crash.
- Konsole's ICU lookup resolved to the build container's host ICU when none was staged;
  `build-kde-apps.sh` now stages ICU the way `build-qt.sh` does. Headers and runtime must
  match because ICU bakes the major version into every symbol (`ucol_open_74`).

### Hardware and session

- **PowerDevil reads batteries through Solid, not UPower.** `kf6-solid 6.3.0+ios1` shipped
  only the fakehw backend, so Plasma read 0% and raised "Battery Critical". `+ios2`
  builds the UPower backend. Quick check of a build: `strings -a libKF6Solid.6.3.0.dylib |
  grep -c org.freedesktop.UPower` (0 means the backend is missing). Solid uses
  `QDBusConnection::systemBus()`, which the launcher aliases to the session bus, so set
  `DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"` when probing by hand.
- KWin's stock `KWinDisplayDetector` skips every SDR output in 6.1 and `BacklightDetector`
  needs libudev, so without `XiosBacklightDetector` (registered first) no detector sees the
  panel.
- **Scale.** Nested KWin's upstream configure path sized its buffer as host logical size
  times the saved scale, and iosc's fit then cancelled the enlargement. The
  `KWIN_XIOS_HOST_OUTPUT_SCALE` contract fixes that. Separately, at fractional scales KWin
  tags `buffer_scale = ceil(s)` but reads inbound coordinates in fractional logical space,
  so clicks landed short; the `ios-bringup-fractional-scale` patch in `kwin-ios-fixes.sh`
  rescales by `ceil(s)/s` and adds the missing touch output origin. iosc also implements
  KDE output management for tools that talk to it directly (`../kde-output-management.md`).
  To recover from a bad saved scale, delete `kwinoutputconfig.json` and the kscreen output
  directory and restart the session.
- Finger taps double-activated in Plasma until Xios consumed pointer emulation for direct
  `wl_touch` in `kde`/`kde-*` presets. A later "taps do nothing" report was version skew
  (iosc 0.9.43 against a stream-v2 app), not a KDE bug; see `xios-app.md`.
- **Running KDE binaries by hand over SSH**: nothing sets `XDG_RUNTIME_DIR` outside the
  session scripts, so export `XDG_RUNTIME_DIR=/var/jb/tmp/xios-kde-runtime` (append
  `-<slot>` for a slot) first. `bin/xios-kde-smoke` goes through `xios-session` and does
  not need this.
- Xios keeps showing the last IOSurface after a session stops. Trust `bin/xios-device
  status` and `ps` over the frame on screen.
- Do not clear another session's lock unless its recorded owner is confirmed dead.

## Building

All of this runs in Docker on the `procursus-vol-kf6` volume (cloned from the Qt volume).

- **Qt**: `linux-build/build-qt.sh` (qtbase, `linux-build/recipes/qtbase.mk`) then
  `build-qt-modules.sh` (shadertools, declarative, 5compat, wayland, svg, imageformats,
  later tools and sensors for KWin). Host and cross Qt must be the identical version.
  Round 3 enables ES2/EGL against ANGLE; see `../qtwayland-angle-iosurface.md`.
- **KF6**: `linux-build/build-kf6.sh`, six waves over 40 audited units. Stage 1 builds ECM,
  kcoreaddons, karchive, kconfig, ki18n and kpackage natively so cross builds use them
  through `-DKF6_HOST_TOOLING`. Recipes are generated: edit the TABLE in
  `linux-build/tools/gen-kf6-recipes.py`, not the `.mk` files. `KF6_CMAKE_FLAGS` pins
  `-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner`, because the staged arm64
  wayland-scanner otherwise wins and fails with "Exec format error". `kf6-common.mk` pins
  gettext tools to the host for the same reason. The audit and its feature cuts are in
  `../kde-plasma-plan.md`.
- **KWin**: `linux-build/build-kwin.sh` (`linux-build/recipes/kwin.mk`, `kwin-ios-fixes.sh`,
  `kwin-ios-gpu-backend.sh`, `kwin-ios-gpu/`). It refuses to build without a staged ANGLE
  deb (8f9be36e made that guard actually fire).
- **Plasma**: `linux-build/build-plasma-desktop.sh` (libplasma, workspace, desktop, nano,
  mobile, support wave). `XIOS_BUILD_JOBS` lowers parallelism for plasma-workspace.
- **Apps**: `linux-build/build-kde-apps.sh`; `TARGETS` lists exiv2, phonon,
  ksyntaxhighlighting, ktexteditor, ark, gwenview, kwrite, kate, kcalc, kpty, konsole,
  dolphin.
- **Install**: follow the publish procedure in the top-level `AGENTS.md` (stage, publish
  to staging, install from dev.repo). `linux-build/prep-kde-kwin-device.sh
  --stage-only|--install` builds an offline bundle in `linux-build/kde-kwin-device-prep/`;
  that bundle was last frozen around `xios-kde 0.1.9` and is older than production.
- Docker: `docker volume prune` deletes active build volumes (transient containers look
  unmounted between packages); use `builder prune`. Large translation units (qmldom) can
  OOM at high `-j`; rerun at `-j2`.

## History (short)

- 2026-07-01 to 07-03: KF6 audit, Qt module ladder, KF6 waves, KWin first light (QPainter
  over a CPU copy of client IOSurfaces), first app batch (Ark, Gwenview, KWrite, QCoro6)
  published. `qcoro6` is a hard dependency of plasma-workspace.
- 2026-07-04 to 07-06: real upstream Plasma Desktop shell (KIO `desktop:` worker, package
  structures, task manager, pager, tray), Plasma Mobile with Xios-backed providers and the
  Folio drawer, KScreen and System Settings, Breeze, detached launcher, slot sessions.
- 2026-07-08: epoxy/OpenGLES collision fixed; iosc gains KDE output management; scale bug
  fixed.
- 2026-07-18 to 07-19: KWin GL runtime on ANGLE with IOSurface import; damage tracking.
- 2026-07-28 to 07-30: effects, KCMs, PowerDevil, Konsole, Dolphin, Kate, KCalc, Okular;
  `xios-kde 0.1.11` pulls every app; battery via Solid; tablet mode; scale contract and
  iPad defaults (`kwin +ios33`, `plasma-desktop +ios10`, `xios-session 1.0.77`).
- 2026-08-06: the "KWin ANGLE fails after restarts" report closed as the second-display
  bug, already fixed.
- 2026-10-25: `xios-kde 0.1.21` pins `xios-core 0.1.13` and `xios-session 1.0.82` (which now
  depends on `xios-session-stubs`, so KDE sessions get `xios-sysintd` and `xios-setsid`).
