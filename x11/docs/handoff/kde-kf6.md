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
"Device run 1" at the end of this section before installing it again.

### What gets installed
The staged set is the 200 `.deb`s listed in `x11/linux-build/out/KDE67-STAGED.txt` in the
`claude/kde-67` worktree on the build Mac (`/Users/max/Documents/jailbreak/.claude/worktrees/agent-a61ed2a7976e087b4`;
name, version, SHA256, file; `KDE67-STAGED.paths` is
the same list as paths). Superseded duplicates were moved to `out/superseded-kde67/`; anything else
in `out/` is a seed copy of a published dependency and is not part of the test. It is the whole lane: Qt 6.10.3, KF6 6.30.0, Plasma 6.7.5,
Gear 26.08.1, poppler 25.11.0, plus `libwayland0`/`libwayland-dev 1.24.0+ios2` (KWayland 6.7
imports `_wl_fixes_interface`, a 1.24-only symbol; the recipe is `claude/upd-wave-core`'s,
cherry-picked here) and `xios-kde 0.1.22`, which pins every lane runtime unit with `>=` so the
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
```sh
ssh root@$IP 'mkdir -p /var/jb/tmp/kde67'
scp $(cat x11/linux-build/out/KDE67-STAGED.paths) root@$IP:/var/jb/tmp/kde67/   # from the claude/kde-67 worktree root
ssh root@$IP 'cd /var/jb/tmp/kde67 && shasum -a 256 *.deb > got.sha256'   # compare with KDE67-STAGED.txt
ssh root@$IP 'dpkg -i /var/jb/tmp/kde67/*.deb && apt-get check'
```
One `dpkg -i` with every file lets dpkg order the unpack itself. No `apt-get -f`, no
`dist-upgrade`. If `dpkg -i` reports an unmet dependency, stop: the staged set is wrong, the
fix is on the build side. `apt-get check` must print nothing. Then
`dpkg -l | grep -E "^ii +(qt6-base|kwin|plasma-workspace|kf6-kio|libwayland0|xios-kde) "` shows
`6.10.3-2+ios1`, `6.7.5+ios1`, `6.7.5+ios14`, `6.30.0+ios1`, `1.24.0+ios2`, `0.1.22`.

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
