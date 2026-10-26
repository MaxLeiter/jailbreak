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

## Qt 6.10 / KF6 6.30 / Plasma 6.7 lane: device test plan (2026-10-25)

Branch `claude/kde-67` (draft PR) carries the lane from `claude/update-plans` onto
`origin/main`, minus the WebKitGTK commits. Plan and port notes: `x11/docs/kde-qt68-plasma64-plan.md`
(sections 9 and 10). Nothing here is published. The first device run (2026-10-25) failed; see
"Device run 1" and "Device run 1 fixes" at the end of this section before installing it again. Run 2
installs the fixed set (`xios-kde 0.1.24`, 21 repacked debs), not the staged one described next.

### What gets installed
The staged set is the 200 `.deb`s listed in `x11/linux-build/out/KDE67-STAGED.txt` in the
`claude/kde-67` worktree on the build Mac (`/Users/max/Documents/jailbreak/.claude/worktrees/agent-a61ed2a7976e087b4`;
name, version, SHA256, file; `KDE67-STAGED.paths` is
the same list as paths). Superseded duplicates were moved to `out/superseded-kde67/`; anything else
in `out/` is a seed copy of a published dependency and is not part of the test. It is the whole lane: Qt 6.10.3, KF6 6.30.0, Plasma 6.7.5,
Gear 26.08.1, poppler 25.11.0, plus `libwayland0`/`libwayland-dev 1.24.0+ios2` (KWayland 6.7
imports `_wl_fixes_interface`, a 1.24-only symbol; the recipe is `claude/upd-wave-core`'s,
cherry-picked here) and `xios-kde 0.1.23` (0.1.24 in the fixed set), which pins every lane runtime unit with `>=` so the
upgrade is one transaction. Everything GPU-entitled in it has been through
`resign-graphics-packages.py` on the Mac (a second dry run reports 0 changes), so the bytes are
what a publish would ship. Runtime pieces published elsewhere that this stack runs on: `angle`
`es3-16`, `libepoxy` `+angle2` (main's 2026-10-25 release), `libdrm2`, `libgbm1`; every
`_drm*`/`_gbm*`/`_wl_*` import of the new `libkwin` resolves against the published dylibs
(`_wl_fixes_interface` from KWayland is the one 1.24-only symbol in the set).

Not rebuilt, stays at the published version: `gwenview 24.08.0+ios1` (26.08 needs Qt
Multimedia; this is the one Qt 6.6 / KF6 6.3-built binary left in the closure) and
`qt-wayland-gl-smoke 0.1.0` (not in `xios-kde`; it links `libQt6WaylandClient`, which now comes
from `qt6-base`). `libpoppler-glib8 25.11.0+ios1` replaces the published 24.08 build for the GNOME
users of it too (papers, zathura-pdf-poppler, gimp); same soname.

### Built vs rebuilt in this pass
Reused unchanged from the 2026-10-02 build in `procursus-vol-kde610` (their cache fingerprints
still match the committed recipes): the Qt 6.10.3 modules, most of KF6 6.30, and most of Plasma
and Gear. Rebuilt on that volume: `kwin` (main's two fix-script corrections), `kf6-kio`
(`-DUSE_DBUS=ON`: the 6.30 build had silently lost kiod6/kioexec/KDirNotify), `kf6-i18n`
(the libgtkintl relink had pointed at the wrong directory), `layer-shell-qt`, `libplasma`,
`plasma-workspace`, `plasma-mobile`, `powerdevil`, `kwrite` (stale fingerprints), and
`kf6-kirigami-addons 1.3.0+ios2` / `phonon4qt6 4.12.0+ios2` (the lane had rebuilt them against
Qt 6.10 under the published `+ios1` version). Repackaged only: `qt6-base` (new `Breaks:` on
pre-6.10 Qt modules and the KDE units that use Qt private API), `kwayland`
(`libwayland0 (>= 1.24.0)`), `okular` (`libpoppler154`, the control still named 140).

### Preconditions
1. Nobody else owns the device: `tail -n 40 /var/jb/var/log/apt/history.log`, `ls -lt /var/jb/tmp | head`,
   `xios-session status`. If another session is up, stop and ask; do not clear its lock.
2. Snapshot for rollback (the stack does not upgrade partially, so the rollback is all or nothing):
   ```sh
   ssh root@$IP 'mkdir -p /var/jb/tmp/kde67-rollback && cd /var/jb/tmp/kde67-rollback &&
     dpkg --get-selections > selections.txt &&
     dpkg-query -W -f="\${Package}=\${Version}\n" > versions.txt'
   ```
   The rollback debs are the published ones (`repo.maxleiter.com`, every version in
   `versions.txt` is still served; production `.deb`s are immutable). Fetch them before
   installing: `apt-get download $(grep -E "^(qt6-|kf6-|plasma|kwin|kdecoration|kwayland|kglobalacceld|layer-shell-qt|libplasma|libkscreen|kscreen|breeze|milou|powerdevil|systemsettings|kactivitymanagerd|qcoro6|phonon4qt6|libpoppler|libwayland|libdisplay-info|konsole|dolphin|kate|kwrite|kcalc|okular|ark|xios-kde)" versions.txt)`.

### Install (one dpkg transaction, no apt resolver)
Run 2 uses the fixed set (`KDE67-SET.txt`, see "Device run 1 fixes" below), not the staged one.
Use a fresh directory: `/var/jb/tmp/kde67/` still holds run 1's debs.
```sh
ssh root@$IP 'mkdir -p /var/jb/tmp/kde67r2'
scp $(cat x11/linux-build/out/KDE67-SET.paths) root@$IP:/var/jb/tmp/kde67r2/   # from the worktree root that holds out/kde67-set
ssh root@$IP 'cd /var/jb/tmp/kde67r2 && shasum -a 256 *.deb > got.sha256'   # compare with KDE67-SET.txt
ssh root@$IP 'cd /var/jb/tmp/kde67r2 && dpkg -i $(ls *.deb | grep -v "^qt6-base_") qt6-base_*.deb && apt-get check'
```
One `dpkg -i` with every file; qt6-base goes LAST on the command line. dpkg unpacks in
command-line order and checks `qt6-base`'s `Breaks:` (pre-6.10 `qt6-declarative`, `-svg`,
`-tools`, ... and the KDE units that use Qt private API) at that moment against whatever is
still installed. In glob order `qt6-base_` sorts before `qt6-declarative`, `qt6-svg`, `qt6-tools`,
`qt6-wayland` and the others, so those are still 6.6 when it unpacks and dpkg refuses ("installing
qt6-base would break qt6-wayland, and deconfiguration is not permitted"). No relation can change that
(a versioned Depends from `xios-kde` is only checked at configure time, and `Breaks` is the only thing
that makes apt upgrade the old modules together with qt6-base), so the fix is the order. A plain
`dpkg -i *.deb` in glob order also works if you add `--auto-deconfigure`; both were run against a
fake 6.1.5 dpkg root and ended with all 200 packages configured. No `apt-get -f`, no
`dist-upgrade`. If `dpkg -i` reports an unmet dependency, stop: the set is wrong, the fix is on
the build side. `apt-get check` must print nothing. Then
`dpkg -l | grep -E "^ii +(qt6-base|qt6-wayland-dev|kwin|plasma-workspace|kf6-kio|libwayland0|xios-kde) "` shows
`6.10.3-2+ios1`, `6.10.3-1+ios2`, `6.7.5+ios1`, `6.7.5+ios14`, `6.30.0+ios1`, `1.24.0+ios2`, `0.1.24`.

### AMFI / signature check (before starting a session)
A host-signed binary can be SIGKILLed with zero output (exit 137); see `x11/docs/device-testing.md`.
Run each GPU-entitled binary once outside a session and look for exit 137 (any other non-zero
exit, e.g. "no Wayland display", is fine: the binary ran):
```sh
for b in /var/jb/Applications/KDE/kwin_wayland.app/kwin_wayland \
         /var/jb/Applications/KDE/kwin_wayland_wrapper.app/kwin_wayland_wrapper \
         /var/jb/Applications/KDE/plasmashell.app/plasmashell \
         /var/jb/Applications/KDE/systemsettings.app/systemsettings \
         /var/jb/Applications/KDE/konsole.app/konsole /var/jb/Applications/KDE/dolphin.app/dolphin \
         /var/jb/Applications/KDE/kate.app/kate /var/jb/Applications/KDE/kwrite.app/kwrite \
         /var/jb/Applications/KDE/okular.app/okular /var/jb/Applications/KDE/ark.app/ark \
         /var/jb/Applications/KDE/kcalc.app/kcalc \
         /var/jb/usr/libexec/xdg-desktop-portal-kde.app/xdg-desktop-portal-kde \
         /var/jb/usr/libexec/org_kde_powerdevil.app/org_kde_powerdevil \
         /var/jb/usr/libexec/kscreen_osd_service.app/kscreen_osd_service; do
  "$b" --version >/dev/null 2>&1; echo "$? $b"
done
```
Any `137` is an AMFI reject: re-sign that binary on the device with its own entitlements
(`ldid -e "$b" > /var/jb/tmp/e.xml && ldid -S/var/jb/tmp/e.xml "$b"`), note which one, and
report it. The full list is under "Signing coverage" below.

### Session and what proves success
```sh
ssh root@$IP 'IOSC_EGL_DEBUG=1 QT_LOGGING_RULES="kwin_wayland_backend.info=true" xios-session kde'
x11/bin/xios-kde-smoke --no-session desktop --out .artifacts/kde67-desktop
```
Pass criteria, all from the device:
1. **KWin on the GPU path.** `/var/jb/tmp/kde-plasma.log` contains `ios-gpu: ANGLE Metal EGL initialized`
   from `kwin_wayland` and no `Could not initialize ANGLE Metal EGL`, `IOSurface pbuffer failed`,
   `failed to export mandatory Metal acquire fence`, or a fallback to QPainter compositing.
   With `IOSC_EGL_DEBUG=1`, the kwin_wayland pid logs `ANGLE Metal display = 0x... (err 0x3000)`
   and `eglInitialize -> ok=1`, and no `display creation failed` / `EGL not available`.
2. **plasmashell up.** `pgrep -x plasmashell`, `pgrep -x kwin_wayland`, `pgrep kactivitymanagerd`
   alive after 60 s; `xios-session status` says `kde-desktop`/`up`; the smoke capture is
   non-black with the bottom panel and wallpaper. plasmashell logs `bound iosc_iosurface` and a
   3-buffer window surface (its QtQuick runs on ANGLE, not software).
3. **Scale contract.** KWin still launches with `--scale 2` host scale and Plasma at 2.75
   (the 6.1.5 behaviour, see the 2026-07-29 snapshot above); the panel is about 50 points tall.
4. **Apps open.** `x11/bin/xios-kde-smoke --no-session desktop --app konsole`, then the same for
   `dolphin`, `kate`, `systemsettings`, `okular`, `gwenview` (the one Qt 6.6-built app left).
   Each window maps, draws, and the process is still alive 10 s later. Kickoff search:
   `--launcher kickoff --query kwrite --activate`.
5. **Mobile and Nano.** `x11/bin/xios-kde-smoke mobile --drawer` and `... nano` reach a
   non-black capture with kwin_wayland and plasmashell alive.
6. **No AMFI rejects.** No exit 137 from step "AMFI", and
   the device log shows no AMFI/amfid denial naming these paths (iOS has no `log show`: use
   `idevicesyslog` from the Mac during the launch and grep for `AMFI`/`amfid` plus the binary
   name).
7. `kiod6` starts on demand (`pgrep kiod6` after opening Dolphin) — KIO is back to DBus
   (prod 6.3 had it; the first 6.30 build silently lost it).

Things expected to differ from 6.1.5 (do not chase in the first run): the desktop:/ KIO
worker and notification sounds are compiled out, the Print portal is gone, Plasma Mobile's
record tile and flashlight helper are dropped, polkit-kde-agent-1 is not built.

### Rollback
`dpkg -i` the debs fetched in step 2 of the preconditions (all of them in one command), then
`apt-get check`. Do not `apt-get remove` the new packages: the old set replaces them in place.
Packages that exist only in the new lane (`libpoppler154`, `libdisplay-info2`, `knighttime`,
`qt6-positioning`, `qt6-location`, `kf6-prison`, `kf6-holidays`, `libqrencode4`,
`vulkan-headers`, `kde-cli-tools`, `xdg-desktop-portal-kde`) can stay; nothing old links them.
`libwayland0` goes back to 1.23.1, which the old KWayland is fine with.

### Signing coverage (host side)
Every binary whose entitlements carry a GPU/IOSurface marker was re-signed by
`resign-graphics-packages.py` (44 binaries, 15 packages), with the same profiles as the
published 6.1.5 / 24.08 builds:

- platform-gl (`iosc-gl-ent.xml`): kwin (`kwin_wayland`, `kwin_wayland_wrapper`,
  `kwin-applywindowdecoration`), plasma-workspace (`plasmashell`, `plasmawindowed`,
  `plasma-shutdown`, `ksmserver-logout-greeter`, `kcolorschemeeditor`, `plasma-apply-*` x4,
  `plasma-changeicons`), powerdevil (`org_kde_powerdevil` and the three kauth helpers),
  systemsettings, xdg-desktop-portal-kde.
- gpu-client (`iosc-gpu-client-ent.xml`, now with the `com.max.xios.metal-event-broker`
  mach-lookup): ark, dolphin (+ `servicemenuinstaller`, two kconf_update helpers), kate, kwrite,
  kcalc, konsole, okular, kscreen_osd_service, kde-cli-tools (11 tools), qt6-declarative-dev
  (`qml`, `qmlscene`, `qmleasing`).

Nothing that was GPU-entitled in production lost its entitlements. Two previously entitled
binaries are gone upstream (`power_profile_osd_service`; `kiod6.app` is now a plain
`libexec/kf6/kiod6`, matching its DBus service file). Executables that open no window
(`kded6`, `kglobalacceld`, `knighttimed`, `kactivitymanagerd`, `kcmshell6`, ...) keep the
Procursus `general.xml` set, as in production. Qt/KDE plugins are dylibs loaded into these
processes and carry no entitlements of their own.

The host-ldid AMFI landmine bit `iosc` only, but `kwin_wayland` and `plasmashell` carry the
same `iosc-gl-ent.xml` set, so the AMFI step above is not optional.

### Device run 1 (2026-10-25): failed, rolled back
Logs, dpkg output, a capture and KWin's support information are in
`x11/artifacts/device-runs/kde67-20261025/` in the main checkout (not tracked). The 200 staged
debs and the rollback set are still on the iPad in `/var/jb/tmp/kde67/` and
`/var/jb/tmp/kde67-rollback/`.

Install problems (all build/packaging side):
- `qt6-base`'s new `Breaks:` made the single `dpkg -i` refuse until `--auto-deconfigure` was added.
  Either document that flag in the install step or let `xios-kde` carry the ordering.
- File conflicts dpkg stopped on: `powerdevil` vs `plasma-mobile`
  (`brightnesscontrolplugin/qmldir`), `kwrite` vs `kate` (`kio_kateexec.so`), and
  `libdisplay-info-dev` vs `libdisplay-info1` (`libdisplay-info.dylib`). Each needs the file
  moved to one owner or a `Replaces:`/`Breaks:` pair.
- No `qt6-wayland-dev` in the set, so 28 `-dev` packages stayed unconfigured. Qt 6.10 folded
  Wayland client into `qt6-base`; ship a transitional `qt6-wayland-dev` that depends on
  `qt6-base-dev`.
- `libKF6BreezeIcons.6.30.0.dylib` (27 MB) was unsigned and was ad-hoc signed on the device to
  get further. The host signing pass skips it, probably on size or because it holds no code
  entitlements; it is the only unsigned Mach-O in the set.

Runtime problems:
- **KWin fell back to QPainter.** The log has `Failed to open drm node`, `couldn't find dev node
  for drm device` and `kwin_wayland_backend: Could not initialize rendering context`, and never
  `ios-gpu: ANGLE Metal EGL initialized`. KWin 6.7 takes its DRM/GBM path and never reaches the
  iOS ANGLE hook that 6.1.5 has, so the port's EGL backend patch needs re-applying to the 6.7
  backend layout. This is the blocker.
- The desktop did not fill the screen (black border). `supportInformation` reports
  `Geometry: 0,0,1360x1000`, `Scale: 2`. 6.1.5 launches KWin at the same 1360x1000 logical size
  and fills the screen, so the border is more likely the QPainter path than the size itself.
  Recheck once the GPU path works.
- A visible `Unknown protocol 'desktop'` error: the desktop:/ worker is compiled out (expected),
  but the default folder view still points at it. Point the default containment at a plain
  path, or keep the worker.
- `kf6-i18n 6.30` was rebuilt with the corrected relink; confirm with `otool -L` that it links
  `@rpath/libgtkintl.dylib` before the next run (see the prod note below).

Rollback worked as written (`dpkg -i` of the fetched set, `apt-get check` clean), plus removing
66 lane-only packages. It exposed one prod bug: the published `kf6-i18n 6.3.0+ios1` linked
`@rpath/libintl.dylib` while importing `_g_libintl_*`, so KWin 6.1.5 aborted in dyld on any
device that had not relinked it locally. Fixed on prod as `kf6-i18n 6.3.0+ios2` (same payload,
`relink-gtkintl.sh`), and a scan of all 622 published debs found no other binary with that
mismatch.

Session cleanup bug seen along the way: when KWin aborts at launch, `xios-session` reports the
failure but leaves `iosc` and `kded6` running, and the next `SESSION` for that slot fails with
`slot ... already has a display` until `xios-session --slot NAME stop`.

### Device run 1 fixes (packaging side, 2026-10-25)
The install problems above are fixed in the recipes and in a repacked set that needs no rebuild:
`x11/linux-build/tools/repack-kde67-run1.sh <dir with the staged debs>` writes the 21 changed debs to
`out/kde67-fixed/` (`KDE67-FIXED.txt`: name, version, sha256, file, which staged deb each supersedes),
and `tools/assemble-deb-set.py` builds the full 200-deb install set from the staged list plus those
(`out/kde67-set/`, `KDE67-SET.txt` / `.paths`). `tools/audit-deb-set.py <dir>` is the pre-flight for
any set: duplicate paths, directories-only debs, unsigned Mach-O, `_g_libintl_*` without libgtkintl.
It reports all of run 1's findings on the staged set and nothing on the fixed one.

Root causes:
- **`brightnesscontrolplugin/qmldir` (powerdevil vs plasma-mobile).** `plasma-mobile-ios-qml-stubs.sh`
  wrote a pure-QML `ScreenBrightnessControl` into the module powerdevil 6.7 now builds for real. Nothing
  in Plasma Mobile 6.7 imports it (its `BrightnessItem` uses `mobileshell.screenbrightnessplugin`), so
  the stand-in is gone (plasma-mobile `+ios24`) and powerdevil owns the module (`+ios3`, `Replaces:
  plasma-mobile (<< 6.7.5+ios24)` for an upgrade that unpacks it first).
- **`kio_kateexec.so` (and `bin/exec_inspect.sh`), kwrite vs kate.** Both apps come out of the same
  `apps/lib` install; `kio_kateexec` links `libkateprivate`, which kwrite already owns (kate.mk already
  dropped libkateprivate and the locale catalogs for that reason, just not these). kate `+ios2` drops
  them (plus the doubled `plugins/plugins/` copy), kwrite `+ios2` `Replaces: kate (<< 26.08.1+ios2)`.
- **`libdisplay-info.dylib` (-dev vs libdisplay-info1).** The 0.1.1 link-only shim put the unversioned
  dylib in the runtime package; 0.2.0 correctly puts the symlink in -dev, but nothing retired the
  still-installed `libdisplay-info1 0.1.1+ios1`. `libdisplay-info-dev 0.2.0+ios2` `Replaces:
  libdisplay-info1 (<< 0.2.0)` (libdisplay-info2 moved to `+ios2` too, they share the version variable).
  libdisplay-info1 is left with no files and dpkg retires it.
- **"qt6-wayland-dev missing".** It was in the set. Its README sat in `share/doc`, which PACK replaces
  with the licence files, so the deb held only directories; dpkg treats such a package as completely
  replaced and dropped it right after unpacking ("Noting disappearance of qt6-wayland-dev"), and every
  -dev that depends on it stayed unconfigured. The same run dropped `kscreen-dev`, `plasma-desktop-dev`,
  `plasma-mobile-dev`, `plasma-nano-dev`, `plasma-pa-dev` and `systemsettings-dev` (dev debs with no headers).
  `qt6-wayland` / `qt6-wayland-dev` `6.10.3-1+ios2` keep their README in `share/xios-transitional/`, and
  `KF6_COPY_DEV` now writes a marker file when a -dev would be empty; those six -dev debs and their
  runtimes moved up one revision (the dev pins the runtime with `=`).
- **Unsigned `libKF6BreezeIcons.6.30.0.dylib`.** `breeze-icons` is a `data_only` entry in
  `gen-kf6-recipes.py` ("no SIGN"), true for 6.3 and wrong since 6.30 builds a real dylib. The generator
  now emits a SIGN for it (`sign=True`); `kf6-breeze-icons 6.30.0+ios2` is signed with `ldid -Cadhoc -S`
  like its siblings. No size or file-type filter was involved. A scan of all 200 staged debs found no
  other unsigned Mach-O (only 8 static-plugin `.o` object files in `qt6-base` / `qt6-declarative`, which are
  never loaded).
- **`Unknown protocol 'desktop'`.** `org.kde.desktopcontainment`'s `main.xml` defaults the folder view to
  `desktop:/`, which needs the kio_desktop worker that plasma-workspace-ios-fixes.sh compiles out.
  `plasma-desktop-ios-qml-fixes.sh` now defaults to `~/Desktop` (FolderModel expands the tilde; plasmashell
  runs with `HOME=<prefix>/var/root`) and the deb ships that directory (plasma-desktop `+ios11`).
- **kf6-i18n.** The staged `6.30.0+ios1` links `@rpath/libgtkintl.dylib`; no binary in the 200 debs
  imports `_g_libintl_*` without it.

`--auto-deconfigure`: see Install. `qt6-base`'s `Breaks:` list is correct as written (each bound sorts
old < bound <= new and the Plasma units that use Qt private API are all on it), so it is unchanged;
the install step now puts `qt6-base` last instead. The KF6 units that read
`QGuiApplicationPrivate::platform_theme` (`kf6-colorscheme`, `-configwidgets`, `-iconthemes`, `-kio`) are
not on it; that symbol is stable, so a partial upgrade is not expected to break them.

### Device run 2 (2026-10-25): KWin 6.7 on the GPU, desktop fills the screen
Installed the fixed 200-deb set (`KDE67-SET.txt`, xios-kde 0.1.24, `dpkg -i $(ls *.deb | grep -v '^qt6-base_') qt6-base_*.deb`,
no force flags) with `kwin 6.7.5+ios2` swapped in for `+ios1`. Started from ioscd (`SESSION\tkde\t\t1440\t1080\t176\tkde-4df9`).
`supportInformation`: Compositing Type `OpenGL ES 2.0` (KWin's label for any GLES), `OpenGL ES 3.0 (ANGLE 2.1.28223)`,
`ANGLE Metal Renderer: Apple A10 GPU`, GLSL ES 3.00, Geometry `1047x785`, Scale `2.75`, `blur` active. plasmashell binds
`iosc_iosurface` and renders desktop and panel into 3-buffer IOSurface swapchains. konsole and dolphin map and draw.
The folder view shows `~/Desktop` (= `/var/jb/var/root/Desktop`, the session HOME) with no desktop:/ error.

Root causes, all fixed in the kwin recipes (`+ios2`):
- **ES 2.0 context.** KWin asks for `EGL_CONTEXT_CLIENT_VERSION 2` and expects the driver to hand out the newest
  version; ANGLE gives exactly 2.0, and 6.7's `EglContext::checkSupported()` rejects that silently (3D textures need
  ES 3 or `GL_OES_texture_3D`). The only log line was `Could not initialize rendering context`. The DRM node warnings
  are harmless. Fix: an ES 3 candidate first on Apple (`ios-gpu-gles3-context`), plus a log line naming the failed
  requirement (`ios-gpu-checksupported-diag`).
- **Spec-strict GLSL.** ANGLE errors on `#if GL_OES_standard_derivatives` (an undefined identifier in `#if`), which
  broke every `base.frag` variant: now `#if defined(...)`. The blur downsample shader (and two colour shaders) say
  `#version 140` but call `texture2D`; GLES core shaders get `#define texture2D texture`.
- **Black border.** 6.7's `WaylandOutput::init()` sends `xdg_toplevel.unset_fullscreen`; iosc answers with a
  default-size (1360x1000) configure, which became the mode. 6.1 never sent it. Also 6.7 sizes the host surface by
  viewport (`mode / scale`) and copies the host's preferred fractional scale (2) into KWin's scale. With
  `KWIN_XIOS_HOST_OUTPUT_SCALE` set, the host surface is now `mode / hostScale`, KWin keeps its `--scale`, and input
  is rescaled by `hostScale / scale` (the old `ceil(s)/s` factor assumed 6.1's buffer-scale path).

Left as is:
- A 1px black column/row at the right/bottom edge: 2880/2.75 and 2160/2.75 are not integers and KWin rounds the
  logical size down (1047x785 -> 2879x2159 px). Upstream behaviour; a scale that divides both (2.25 or 2.5)
  removes it.
- Displays KCM scale changes are not applied to the nested output (upstream 6.7 ignores them there too); the scale
  is the launcher's `--scale`.
- `qt.qpa.wayland: EGL not available` comes from `kactivitymanagerd` (no GPU entitlement, no window), not plasmashell.

### Run 3 (2026-10-25): rotation and tap latency, kwin 6.7.5+ios3
Max reported Plasma not following a portrait-to-landscape rotation (slot kde-0b85; the right quarter was KWin's
black background) and taps that "don't seem to work, or are slow".

- **Fixed: host presentation clock.** KWin 6.7 completes nested-output frames only from wp_presentation `presented`
  and feeds the timestamp to RenderLoop, which runs on `steady_clock` (CLOCK_UPTIME_RAW on Darwin). iosc stamps
  CLOCK_MONOTONIC, which keeps counting through sleep. On the test boot it was 11.8 s behind, so KWin ran on its
  "GPU was idle for 100+ frames" path every frame. When CLOCK_MONOTONIC is ahead, which an earlier boot measured
  at +204 s, RenderLoop schedules the next composite that far ahead and KWin stops repainting after each presented
  frame. Plasma still gets the input and the new output size, but nothing reaches the screen. `+ios3` maps the
  timestamp onto steady_clock at receipt (`ios-presentation-clock-map` in `kwin-ios-gpu-backend.sh`). Afterwards the
  perf CSV (`KWIN_LOG_PERFORMANCE_DATA=1`, written to `/var/jb/tmp`) shows pageflip timestamps within a few ms of
  their targets, a 3-9 ms safety margin and a ~20 ms render prediction. Plasma popups open in 330-800 ms (were
  630-1700) and close in ~700 ms (were ~1250).
- **Not reproduced: the stuck rotation.** I tried synthetic XIOS_IN_OUTPUT rotations (`/var/jb/tmp/xin.py`,
  `rotseq.py`): single, 30-300 ms bursts, Kickoff open, a cold Kickoff loading, and a replay of the launch
  sequence (ioscd SESSION at 1440x1080, then portrait before KWin maps, with both KWin `--width/--height`
  orders). Plasma followed every time, in ~140 ms. Max's own log ends with Plasma importing 2879x2159 buffers
  after his last rotation. The clock bug above produces exactly that picture: KWin has the new geometry but has
  not redrawn Plasma's new buffers. That is the likely cause, but I could not confirm it was active in his session.
- **Input mapping** after rotation is right in both orientations: taps on the panel clock open the calendar in
  portrait (1886,2784 px) and landscape (2610,2088 px), including with a 6-16 px finger drift.
- **Where tap latency goes** (renderloop logs + per-process CPU via `proc_pid_rusage`):
  - iosc to KWin to client is fast: konsole's menu responds in 120-170 ms, measured through a ~100 ms grim poll.
  - Plasma popups are CPU-bound in plasmashell: 250-600 ms of polish and QML work at 100% of one A10 core,
    because QML is interpreted on iOS (no V4 JIT). A cold Kickoff takes ~2.5 s. Animations then run at ~30 fps,
    matching the app's display clock.
  - The remaining lever looked like QML/JS execution, for example trying Qt's V4 JIT with the mmap+mprotect(RX)
    path that works for bun. That is now done (see "QML JIT" below) and buys only about 10-15% of plasmashell CPU.
- `qt.qpa.wayland: wl_output.name received after output has been initialized` comes from a Qt client of iosc when
  iosc re-advertises its outputs on rotation (iosc re-sends `name` to existing resources). It is cosmetic.
- Seen once in five SSH launches: plasmashell came up without its panel (no `PanelView` in the log). The next
  launch was fine. Not investigated.

### QML JIT (2026-10-26): qt6-declarative 6.10.3+ios2
QV4's baseline JIT (and the Yarr regexp JIT) now run on the device. Built and device-tested, not published.

**Why it was off.** `qtdeclarative.mk` said the JIT would need W^X juggling and that `Q_OS_IOS` disables it at
runtime. Neither was the real reason. Two things kept it off, and neither is an iOS rule:
- `src/qml/configure.cmake` allows arm64 JIT only for `ANDROID OR LINUX OR IOS OR ...`. We configure as Darwin,
  where CMake's `IOS` is false, so `-DFEATURE_qml_jit=ON` would have been refused.
- `masm/wtf/OSAllocatorPosix.cpp` maps JIT chunks with `MAP_JIT` on Darwin, and `canAllocateExecutableMemory()`
  probes with `MAP_JIT`. `MAP_JIT` is `EINVAL` for our fakesigned processes, so the engine fell back to the
  interpreter without saying so.

The JIT itself already does the right thing for this device: with `ENABLE_ASSEMBLER_WX_EXCLUSIVE` every link
mprotects its page range RW, writes, flushes the icache and flips it to RX. That is the mmap RW -> write -> mprotect
RX pattern that also works for bun and mozjs (see `linux-build/probes-bun-jit/README.md`).

**What changed** (`linux-build/recipes/qtdeclarative-ios-jit.patch`, applied in `qtdeclarative-setup`):
- `configure.cmake`: an extra `arm64 AND APPLE` entry. Real macOS arm64 stays off through
  `QT_QML_JIT_SUPPORTED_IMPL`, which keys on `Q_OS_MACOS`.
- `OSAllocatorPosix.cpp`: no `MAP_JIT` on iOS (chunks are plain RW anonymous memory). `canAllocateExecutableMemory()`
  on iOS is a real test, run once per process: two RW -> write `mov w0,#n; ret` -> RX -> call rounds on one page,
  under a SIGBUS/SIGSEGV/SIGILL handler that only catches faults on the probing thread. If it faults or returns the
  wrong value, the engine interprets as before. It costs about 40 us.
- `MathExtras.h`: the old Mac OS X `#define ceil(x) wtf_ceil(x)` is skipped on iOS. It renamed `std::ceil` in
  `qjsnumbercoercion.h` and broke `YarrJIT.cpp`, which is only compiled with the JIT on.
- `qv4executableallocator.cpp`: `QV4_JIT_PROBE_LOG=1` prints the probe verdict and every new code chunk. A failed
  probe is always printed.

The rebuild also needed `-DCMAKE_DISABLE_FIND_PACKAGE_Qt6Test=ON`, `-DCMAKE_DISABLE_FIND_PACKAGE_Qt6Svg=ON` and
`-DFEATURE_quick_vectorimage=OFF`: Qt6Test and Qt6Svg were staged into `procursus-vol-kde610` after +ios1 was built,
and they turn on QuickTest and VectorImage, whose host tools (`qmltestrunner`, `svgtoqml`) the host Qt lacks. The
+ios2 runtime deb has exactly the +ios1 file list. No entitlement changes: plasmashell and KWin keep their GPU sets,
and neither needs `dynamic-codesigning`.

**Knobs.** `QV4_FORCE_INTERPRETER=1` turns the JIT off; `QV4_JIT_CALL_THRESHOLD` (default 3) sets how many
interpreted calls a function gets before it is compiled. QV4 has no on-stack replacement, so a function only runs
JIT code from its 4th call.

**How to tell it is on.** `linux-build/probes-qv4-jit/vmrx.py <pid>` counts VM regions with tag 64
(`VM_TAG_FOR_EXECUTABLEALLOCATOR_MEMORY`, how QV4 tags its chunks). After a fresh start plasmashell had 28-34 r-x
chunks (460-580 KiB) with +ios2 and none with +ios1. KWin had none: its QML did not reach the call threshold.

**Device results** (A10, landscape, slot kde-0b85, fresh session each; plasmashell CPU from `proc_pid_rusage`):

| | +ios1 interpreter | +ios2 JIT |
|---|---|---|
| `jsbench2.qml` pure JS (fib 25 x6 / int loop) | 87-89 / 193-194 ms | 64-66 / 106 ms |
| `jsbench.qml` QML-scope mix, total | 1391-1434 ms | 1179-1201 ms |
| plasmashell CPU, start + 60 s idle | 10.9-11.5 s | 10.3-11.0 s |
| first Kickoff open, plasmashell CPU | 676-880 ms | 590-595 ms |
| warm Kickoff open, CPU | 146-168 ms | 129-154 ms |
| first clock popup open, CPU | 1.2-1.7 s | 1.1-1.3 s |
| warm clock open / close, CPU (mean) | 396 / 660 ms | 358 / 575 ms |
| 15-popup sequence, CPU | 9.3-11.7 s | 8.6-9.7 s |

So the JIT gives 1.4-1.8x on plain JS but only 10-15% of plasmashell's CPU per popup. Most of the popup cost is not
JS: it is object creation, bindings plumbing, layout and text in C++, plus functions that never reach the call
threshold. Wall-clock times from this run are not usable: the Xios app was not presenting (iosc paced itself,
`pacing=event-loop`), and fileproviderd, photoanalysisd and mediaanalysisd used 1-2 cores the whole time, so cold
opens ranged from 1 to 15 s on both builds. The next lever needs a profile of plasmashell's main thread, not more JS
speed.

**Stability.** No SIGBUS or JIT-related crash: 4 fresh sessions on +ios2, 30+ timed popups, a 125-popup soak
(plasmashell and KWin pids unchanged), and `qml` runs of both benches. The only crash reports are the
`kwin_wayland` SIGABRTs (`QMessageLogger::fatal`) written whenever a slot is stopped. Those happen identically on
+ios1 and predate this work.

**Install the way it was tested.** `dpkg -i` both debs (dpkg renames into place, so nothing is overwritten while
mapped), then re-sign every Mach-O on the device: copy to a new file, `ldid -S` with the file's own entitlements,
`mv` over. `probes-qv4-jit/` has the scripts (`abrun.sh` is one full measurement pass).
