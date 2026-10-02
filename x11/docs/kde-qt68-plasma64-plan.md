# KDE lane: Qt 6.10 / KF6 6.30 / Plasma 6.7 / Gear 26.08

Status: plan, 2026-10-01 (rev 2). Max retargeted the lane from Qt 6.8 / Plasma 6.4 to **Qt 6.10 / Plasma 6.7**
(rev 1 of this doc, same file name, is in git history). The file keeps its first name to keep links stable.
Every floor below was read from the upstream CMakeLists at the named tag. Where the earlier audit differed, this says so.

## 1. Targets

| Piece | Target | Verified floor / note |
|---|---|---|
| Qt | **6.10.3** (newest 6.10.x; plain `qt*-everywhere-src-6.10.3.tar.xz`, `archive/qt/6.10/6.10.3`) | Plasma 6.7.5 floor is Qt 6.10.0. |
| KF6 | **6.30.0** (newest) | Plasma 6.7.5 needs KF >= 6.26. KF 6.25-6.30 need Qt 6.9 (we have 6.10) and **CMake >= 3.29**: ship cmake 3.31 inside the volume (image has Debian 3.25; no image edit). Includes the KShell fix (CVE-2026-41526, fixed in 6.25): no backport. Fallback if Plasma 6.7.5 will not build on 6.30: 6.26. |
| Plasma | **6.7.5** (newest 6.7) | kwin/plasma-workspace/libplasma Qt 6.10, KF 6.26. |
| plasma-wayland-protocols | 1.21.0 (kwin, libkscreen, plasma-workspace floor; 1.23.0 exists) | |
| Gear | **26.08.1** | dolphin floor KF 6.23; kate/konsole/ark/okular/gwenview/kcalc floors <= KF 6.9, Qt 6.6. |
| poppler | **25.11.0** (+qt6, +glib) | last C++20 poppler (26.01+ is C++23); soname `libpoppler.154`. Moves to 26.x once the C++23 lane exists (it will, see 2). |
| libdisplay-info | 0.2.0 | kwin floor `>=0.2.0` (we ship 0.1.1). |
| pulseaudio-qt | 1.6.0+ | plasma-pa 6.4.6 floor; re-read plasma-pa 6.7.5 floor at build. |
| qcoro6 / phonon4qt6 / kirigami-addons | rebuilt, versions kept unless a build says otherwise | |
| exiv2 / exempi | NOT ours (`upd-wave-gnome` bumps them) | build gwenview/okular against its newest output. |

New pieces vs the 6.6 lane: **qtpositioning + qtlocation** (plasma-workspace REQUIRES Qt6::Location/Positioning; Ladybird's Qt UI also
`find_package(Qt6 6.10 Positioning)`), **KDecoration3** (replaces KDecoration2), **KNightTime** (new Plasma lib, kwin and
plasma-workspace REQUIRE it), **Vulkan headers** (kwin 6.7 `find_package(Vulkan REQUIRED)`, deep in `core/renderdevice`,
`drm_formats.h`, `src/vulkan/`), libdisplay-info 0.2.0.

**Ladybird Qt frontend needs** (read from upstream `UI/Qt/CMakeLists.txt`): Qt6 6.10 `Core Widgets Gui(+Private)` and `Positioning`
(non-Apple branch; our masquerade is APPLE=1 so Positioning would be skipped by upstream, but we build it anyway for Plasma). Qt Wayland client is now in qtbase (below). No Network/Multimedia required by that file. Covered by the module set.

### Side-by-side: 6.8/6.4 vs 6.10/6.7

| | Qt 6.8.4 / KF 6.24 / Plasma 6.4.6 | **Qt 6.10.3 / KF 6.30 / Plasma 6.7.5** |
|---|---|---|
| Qt floor, newest patch | 6.8.0; 6.8.4 (opensource tarball name) | 6.10.0; 6.10.3 |
| KF floor / newest on that Qt | 6.14 / 6.24 (6.25+ needs Qt 6.9) | 6.26 / 6.30 |
| CMake | 3.27 (KF 6.23/6.24) | 3.29 (in-volume 3.31 either way) |
| C++ std, kwin | 23 | 23 |
| libc++ features needed | `<expected>` (5 uses), `<format>` (2) in kwin/libkscreen: **polyfillable** | `<expected>`, `<format>`, `<print>`, `std::ranges::to` x30, `views::zip`, `ranges::contains`, `unreachable` in kwin/libkscreen/(plasma-workspace C++23, knighttime C++23): **not polyfillable, needs libc++-19 headers** |
| Wayland / protocols | libwayland 1.23 (have 1.23.1), wp 1.44 (have 1.49) | **libwayland 1.24 (have 1.23.1)**, wp 1.48 (have 1.49) |
| New libs beyond the 6.6 lane | qtpositioning, qtlocation, KDecoration3, libdisplay-info 0.2 | same + KNightTime, Vulkan headers, Qt Wayland client merged into qtbase |
| qtbase port delta | all 9 qtbase.mk hunks' anchors still match | same anchors match, **plus** the Wayland QPA moved into qtbase: `FEATURE_wayland` build, host `qtwaylandscanner` from host qtbase, `qtwayland-ios-fixes` re-homed to `qtbase/src/plugins/platforms/wayland/...`, `qt6-wayland` deb becomes transitional |
| Qt CVE diffs | 16 diffs to carry, all apply | 11 to carry, all apply, 3 already in 6.10.3 |
| KWin port | fix script aborts at the touch hunk | aborts earlier (pointer-motion hunk): more drift |
| Plasma fix scripts hard-failing | plasma-workspace, plasma-desktop, libkscreen, kscreen, powerdevil, kde-cli-tools, kactivitymanagerd | same seven |
| Risk | KF 6.24 vs Plasma 6.4.6 (10 minors apart) | KF 6.30 vs Plasma 6.7.5 (closer); toolchain risk much higher (needs libc++-19 lane); wayland 1.24 bump touches a shared base lib |
| Security | Qt via diffs, KShell needs a backport, 6.4 gets backports for a while | Newest everything; one fewer backport; Plasma 6.7 is current, so future advisories land here |
| Unblocks Ladybird Qt UI | no | **yes** |

## 2. Compiler / C++ needs vs our toolchain

Toolchain: Debian clang 14 via the cctools wrapper, iPhoneOS 16.5 SDK libc++ 15.0.6. Image also has clang-19 (Ladybird).
`x11/docs/webkitgtk-toolchain-plan.md` (webkit-toolchain worker) now exists: clang-19 opt-in wrappers, libc++ order A (SDK), **B (LLVM-19 libc++
headers + availability annotations, system dylib)**, C (static). It will write `x11/linux-build/tools/xios-clang19-env.sh`.

| Unit | Needs |
|---|---|
| Qt 6.10, KF6 6.30, Gear, libplasma, powerdevil, kscreen, plasma-desktop | C++17/20, libc++ 15 features (ranges algos, span, optional). clang-14 wrapper, to be proven in the pilot (Qt 6.10 enables C++20 via `QT_FEATURE_cxx20` if the probe passes). |
| **kwin, libkscreen, plasma-workspace, knighttime** | C++23 with `<expected>`, `<format>`, `<print>`, `ranges::to`, `views::zip` ... **hard dependency on the webkit-toolchain lane's libc++ mode B** (or A+patches, which is not realistic for this volume of use). |
| poppler 26.x | C++23, later |

This is a dependency on another worker, not a stop: Qt, KF6, all Plasma libs and Gear proceed on the existing toolchain;
the C++23 group is gated on mode B. **Request to main: relay `xios-clang19-env.sh` + the mode-B probe result as soon as it lands.** I will not edit toolchain files.
P0 probe (my side, minutes): `-fsyntax-only` + link of the 6.7 headers' actual TUs (`iccprofile.cpp`, `libkscreen/.../abstractbackend.h`, a `<print>` user) under mode B.

## 3. Fate of our port work (measured on host: 6.1.5 tree vs 6.4.6 vs 6.7.5; Qt 6.6.3 vs 6.8.4 vs 6.10.3)

| Item | Result | Decision |
|---|---|---|
| qtbase.mk hunks 1-9 + feature flags | every anchor present in 6.10.3 (11 `CONDITION MACOS` blocks, one new gui OpenGL block auto-disabled) | **Carry**; Darwin-masquerade approach **kept**. |
| qtwayland module | **client moved into qtbase 6.10** (`src/plugins/platforms/wayland`); module keeps compositor only | **Rework**: enable `FEATURE_wayland` in qtbase.mk (+ synth `Wayland` find like XKB, host wayland-scanner pin, ANGLE EGL flags, `FEATURE_wayland_server` stays off); re-home `qtwayland-ios-fixes.sh` (popup `attachPopup`, `surfaceRole` void*, qgenericunixthemes seds); drop the qtwayland module build; host build needs `-DFEATURE_wayland=ON` for `qtwaylandscanner` (KF6 gate in `build-kf6.sh` retargets). |
| qtdeclarative-ios-fixes.sh | hard fails: initialiser now uses `platformTheme()->themeHint` | **Rework** (same constants). |
| other Qt modules | no patches | carry + CVE diffs. |
| gen-kf6-recipes.py TABLE, kf6-common.mk | version vars/URLs change; Qt6GuiPrivate finds; knotifyconfig `Qt6Multimedia REQUIRED` unless Canberra (demote, as knotifications already does) | **Carry + edit generator**; re-audit every `if(APPLE)` sed against 6.30 anchors. |
| kwin-ios-fixes.sh + gpu-backend + `kwin-ios-gpu/` | aborts at the pointer-motion hunk on 6.7.5; plus new: Vulkan REQUIRED, KNightTime, Wayland 1.24, Canberra systembell plugin (drop), C++23 | **Rework**: biggest item. Layered port with hard "anchor missing" failures; owned GPU backend files diffed against 6.7's `wayland_egl_backend`/renderdevice API. |
| plasma-workspace/desktop, libkscreen, kscreen, powerdevil, kde-cli-tools, kactivitymanagerd fix scripts | hard fail on 6.7.5 | **Rework**, small each except workspace/desktop. |
| plasma-mobile (+stubs), plasma-nano, libplasma, systemsettings, plasma5support, plasma-integration, plasma-pa, polkit-kde-agent-1, xdg-desktop-portal-kde, layer-shell-qt | run without error, changed-line counts shift (mobile 2236 -> 1101) so hunks silently no-op | **Carry then audit**; add a changed-lines/marker assertion per script first. |
| Gear fix scripts (kate, konsole, kpty) | not yet run | carry, re-verify. |
| Device contracts (host output scale, IOSurface) | depend on KWin internals | re-prove on device after the port. |

First task of execution: a per-script "applied marker / min changed lines" wrapper so nothing applies by matching nothing.

## 4. Security

| Item | Status |
|---|---|
| Qt CVEs | Qt publishes an official `6.10` diff each. On 6.10.3: 11 to carry (qtbase 19248, 76151, 78253; qtdeclarative 79616; qtsvg 6210, 8168 x5; qt5compat 9499); 12385/14576 already in 6.10.3. Stored in `x11/ports/qt610-cve/`, applied in each `-setup` with `patch -N` and a `.rej` check. |
| KShell CVE-2026-41526 | Fixed in KF 6.25+: **closed** by KF 6.30. |
| konsole 49091, dolphin 41525, ark 57966, okular fax x5 | Fixed by Gear 26.08.1. |
| poppler | 25.11 closes the 2025 advisories; later ones wait for the C++23 bump. |

## 5. Packaging and upgrade path

Names stay (`qt6-base`, `kf6-*`, `kwin`, ...), so debs upgrade in place on identical paths; **a partial upgrade is a broken stack**.
- Versions: `qt6-*: 6.10.3-1+ios1` (base) / `6.10.3+ios1`, `kf6-*: 6.30.0+ios1`, plasma `6.7.5+ios1`, Gear `26.08.1+ios1`, poppler `25.11.0+ios1`. All sort above current: filenames change.
- Package changes: `libpoppler140` -> `libpoppler154` (new package; old kept for rollback); `kdecoration` -> KDecoration3 soname; `libdisplay-info1` -> new soname (only kwin depends); new `qt6-positioning`, `qt6-location`, `knighttime`; **`libQt6WaylandClient` + the `wayland` QPA/shell/decoration/graphics plugins move from `qt6-wayland` into `qt6-base`** (so `qt6-base` gets `Replaces/Breaks: qt6-wayland (<< 6.10)`, `qt6-wayland` becomes a transitional dependency package).
- Rebuild set: the 175 packages reachable from `qt6-*` in `repo/Packages` (all `kf6-*`, plasma/kwin family, `phonon4qt6`, `qcoro6`, `qt-wayland-gl-smoke`, Gear apps, `xios-kde`).
  Poppler: only `okular` links `libpoppler.140`. **`papers`, `zathura-pdf-poppler`, `gimp` link only `libpoppler-glib.8` (checked with `otool -L`): no rebuild**, they pick up the new `libpoppler-glib8`/`libpoppler154`; I `otool`/`nm`-check the new glib wrapper for removed symbols. Nothing GNOME-pinned is touched.
- **libwayland 1.24 (flag for main/Max)**: kwin, libkscreen, kwayland 6.7 want `find_package(Wayland 1.24)`; we ship 1.23.1 (`wayland.mk`, shared by iosc, GNOME, GTK, Ladybird...). Same soname, additive API, but it is not mine to bump. Options: (a) bump `wayland` (their rebuild is optional, ABI-compatible; it must reach the device with the KDE stack), (b) lower the floor in kwin/libkscreen/kwayland if the code does not use 1.24 API (verify by build). I plan (b) first, (a) only if a symbol is missing; flagged.
- Co-upgrade: generated `Breaks: <every KDE pkg> (<< new)` on the new `qt6-base` + new `xios-kde` with `>=` Depends on every unit, so one `apt-get install xios-kde` is one transaction. Device path (to propose before use): save current debs to a rollback dir, `dpkg --get-selections`, `apt-get -s` as sanity only, one transaction, no `dist-upgrade`/`--fix-broken`, rollback = `dpkg -i` the saved set. No device work until cleared.
- Host DER re-sign via `resign-graphics-packages.py`; minos stamping + dyld-load audit over the whole set. `upstream-version-policy.json` tracks move to (6.10, 6.30, 6.7, 26.08, pwp 1.21) at the end.

## 6. Build order, volumes, resources

Volume `procursus-vol-kde610` = clone of `procursus-vol-qt`, then purge staged Qt/KDE files from `build_base`, `host-qt-6.6.3`, and build_work/stage/dist for Qt/KDE units (own units only). 6.6 volumes untouched. Debs of this lane go to this worktree's
`x11/linux-build/out/` (seeded with copies of the dependency debs from the main `out/`, read-only). Recipes are bumped in place on this branch; main keeps 6.6.
Max's standing approval (old build_work/build_stage and old debs of the package being bumped inside a volume) is used and every removal is listed in the slot report.

Disk: Mac ~73 GiB free. Clone ~9 GB -> ~12 GB after Qt; KF6+Plasma+Gear ~+15-20 GB. **~30-35 GB new.** `procursus-vol-kf6-closure-20260719` (12.9 GB) is the reclaim candidate (Max's call). RAM: VM 27.4 GiB; keep the `-j2` retry for qtdeclarative/KWin.

Waves: **W0** volume + cmake 3.31 + probes | **Q** host Qt (qtbase with wayland, shadertools, declarative, tools host bits) -> cross qtbase -> shadertools, declarative, 5compat, svg, imageformats, tools, sensors, positioning, location (no qtwayland module) | **P** pwp 1.21, libdisplay-info 0.2, vulkan-headers, pulseaudio-qt, qcoro6, phonon, KDecoration3, KNightTime | **K** KF6 6.30 host tooling + 40-unit set | **W** layer-shell-qt, kglobalacceld, kwayland, kwin (needs mode B) | **PL** libplasma, activities, plasma5support, libkscreen, kscreen, kactivitymanagerd, plasma-workspace (mode B), plasma-desktop, integration, pa, powerdevil, systemsettings, milou, breeze, nano, mobile, polkit-agent, xdg-portal, cli-tools | **G** poppler, Gear | **S** packaging.

Pilot go/no-go: (1) qtbase 6.10.3 incl. Wayland client configures, builds, packages; feature summary equals 6.6's plus wayland; (2) `otool -L`/`nm` clean, CVE diffs applied with no `.rej`; (3) the module ladder builds and `qt-wayland-gl-smoke` links. No-go: structural qtbase changes beyond what this doc lists, clang-14 cannot compile Qt 6.10, or the Wayland client cannot be made to build without a toolchain change.

## 7. Risks
1. KWin 6.7 port plus the libc++-19 dependency (the critical path; Qt/KF6/Gear are independent of it).
2. Wayland client merged into qtbase (new walls: Wayland find under no-pkg-config, host scanner, EGL integration flags).
3. Silent no-op hunks in Plasma fix scripts. 4. libwayland 1.24. 5. Disk. 6. Atomic device upgrade.

## 8. Flags for Max (not acted on)
- libwayland 1.24 (shared base lib) vs lowering kwin's floor.
- KWin/plasma-workspace 6.7 cannot build on the 6.6-era compiler lane; they wait for webkit-toolchain mode B.
- Poppler 25.11 now, 26.x later.
- Reclaiming `procursus-vol-kf6-closure-20260719` if disk tightens.

## 9. Host-side port status (2026-10-01, no Docker used)

Fix scripts were re-run on the host against pristine Plasma 6.1.5 and 6.7.5 trees (GNU-sed shim for macOS; harness not committed).

| Script | 6.7.5 status |
|---|---|
| libkscreen, kscreen, powerdevil, kactivitymanagerd, kde-cli-tools | **Ported** (apply cleanly to 6.7.5 and still to 6.1.5). powerdevil gets a 6.7 variant of `xiosbacklight` (`DisplayBrightness` gained `id/label/isInternal`, `setBrightness(int,bool)`, `externalBrightnessChangeObserved`). Compile-unverified. Note: powerdevil 6.7 also has a Wayland `kde-external-brightness-v1` path that may replace our sysfs detector later. |
| libplasma, systemsettings, plasma5support, plasma-integration, plasma-pa, polkit-kde-agent-1, xdg-desktop-portal-kde, layer-shell-qt | Apply with unchanged changed-file counts. |
| plasma-nano (3 of 5 files), plasma-mobile (26 of 41) | **Partial**: `desktoptoolbox/*.qml`, `volumeosd/*`, `quicksettings/*`, folio `*.qml` and others were moved/removed upstream. `run-fixes.sh` fails these two loudly (min = 6.1.5 count) until re-ported. Plasma Mobile is a deeper QML rework. |
| plasma-workspace, plasma-desktop | **Not ported**: hard-fail (`substring not found`; taskmanager `qmldir` moved). Needs a compile loop. |
| kwin | **Not ported.** `kwin-ios-fixes.sh` now reports every silent perl no-op (`pperl`, `KWIN_FIXES_REPORT=1` lists, default fails): on 6.1.5 only 2 harmless no-ops; on 6.7.5 **23 perl hunks match nothing** plus 2 python hunks fail (nested-backend fractional-scale and fixed-host-pixel-size). Classification: *obsolete in 6.7* (input.cpp libinput x5, cursor.cpp xcb include, X11 find_package, main_wayland x2); *inert with our OpenGL Qt, drop on this lane* (offscreenquickview x8, the QT_NO_OPENGL cleanup); *to rework* (tabletmodemanager x2, qpa/integration.cpp x3, which the gpu-backend script later re-adds; wayland_backend/wayland_output python hunks). The qpa "first-light trim then re-add" dance should be removed rather than ported. Cheapest next step is the compile loop in Docker. |

New guard: `recipes/run-fixes.sh` + `fix-min-files.txt` (applied to 15 recipes) fail a build when a fix script changes fewer files than the version it was ported on.
Poppler 25.11.0 recipes are done (`libpoppler154`); okular/gwenview recipes still need their Gear 26.08.1 bump with the Gear wave.
