# KDE lane: Qt 6.8 / KF6 6.24 / Plasma 6.4 / Gear 26.08

Status: plan, 2026-10-01. Replaces the "hand-backport onto Qt 6.6.3 / KF6 6.3.0 / Plasma 6.1.5 /
Gear 24.08" option. Every floor below was read from the upstream CMakeLists at the named tag, not
from summaries. Where an earlier audit differed, this doc says so.

## 1. Targets

| Piece | Target | Why / verified floor |
|---|---|---|
| Qt | **6.8.4** (opensource tarballs, `qt*-everywhere-opensource-src-6.8.4.tar.xz`) + official 6.8 CVE diffs | 6.8.4 is the newest OSS 6.8 tarball (`archive/qt/6.8/6.8.4`); 6.8.3 uses the plain `-everywhere-src-` name, so the URL macro changes. Plasma 6.4.6 floor is Qt 6.8.0. |
| KF6 | **6.24.0** | **Correction to the audit:** kcoreaddons/kirigami `REQUIRED_QT_VERSION` is 6.7 for 6.14-6.19, 6.8 for 6.20-6.24, **6.9 from 6.25**. Newest KF on Qt 6.8 is 6.24, not 6.27. Plasma 6.4.6 needs KF >= 6.14. 6.23/6.24 need CMake >= 3.27 (image has Debian's 3.25): ship cmake 3.31 inside the volume, not in the shared image. Fallback if Plasma 6.4 will not build on 6.24: KF 6.19 (the KF Plasma 6.4.6 shipped with; cmake 3.16). |
| Plasma | **6.4.6** (last 6.4, `Attic/plasma/6.4.6`) | Qt 6.8.0 / KF 6.14 floors in kwin, plasma-workspace, libplasma, etc. `plasma-wayland-protocols` -> 1.18.0 (kwin, powerdevil). |
| Gear | **26.08.1** | dolphin floor KF 6.23 / Qt 6.4; kate, konsole, ark, okular, gwenview, kcalc floors all <= KF 6.9, Qt 6.6. Fits KF 6.24. Fallback if KF drops to 6.19/6.22: Gear 25.12.3 (dolphin KF 6.9). |
| poppler | **25.11.0** (core + qt6 + glib) | Last C++20 poppler; 26.01+ are `CMAKE_CXX_STANDARD 23`. Soname `libpoppler.154`. Fixes CVE-2025-43718/52886/52885 (fixed by 25.10). Bump to 26.x only once a C++23 lane exists (see 2). |
| libdisplay-info | 0.2.0 | kwin 6.4 floor is `libdisplay-info>=0.2.0` (we have 0.1.1). |
| pulseaudio-qt | 1.6.0 (floor for plasma-pa 6.4.6) | verify Qt floor at build. |
| qcoro6, phonon4qt6, kirigami-addons | unchanged versions, rebuilt | plasma-workspace/powerdevil need QCoro6; fall back to qcoro 0.12.0 if 0.10.0 fails against Qt 6.8. |
| exiv2 / exempi | NOT ours | being bumped by `upd-wave-gnome` (same soname); build gwenview/okular against whatever is newest in its output. |

New Qt modules: **qtpositioning + qtlocation** (plasma-workspace 6.4.6 REQUIRES Qt6::Location/Positioning:
timezone-selector map QML, libcolorcorrect). New KF6-side: **kdecoration becomes KDecoration3**
(libkdecorations3; kwin 6.4 and breeze 6.4 need it; KDecoration2 is gone).

## 2. Compiler / C++ needs vs our toolchain

Toolchain today: Debian clang 14 through the cctools wrapper (`aarch64-apple-darwin-clang`), iPhoneOS
16.5 SDK libc++ (LLVM 15 vintage). The image also has clang-19 (Ladybird lane; `lb-cc`/`lb-cxx` pattern in
`build-ladybird-wave4.sh`). `x11/docs/webkitgtk-toolchain-plan.md` does not exist yet; coordination goes through main.

| Unit | C++ std | Library features actually used (grepped from the 6.4.6/26.08 trees) |
|---|---|---|
| Qt 6.8 | C++17 (opt. 20) | nothing new; no clang-version gate in `qcompilerdetection.h` |
| KF6 6.24, plasma-workspace, libplasma, powerdevil, kscreen, Gear | 20 (konsole 17) | `<ranges>` algorithms, `<span>`, `<optional>`: libc++ 15 has these |
| **kwin 6.4.6, libkscreen 6.4.6, kscreenlocker** | **23** | **`<expected>` (kwin core/iccprofile, libkscreen: 5 uses) and `<format>` (kwin: 2 includes)**. SDK libc++ 15 has neither. |
| poppler >= 25.12 | 23 | out of scope for now |

Consequence: only kwin and libkscreen (and poppler 26+) need a modern libc++. This does **not** alter every
recipe, so it is not a stop condition. Plan:
1. **P0 probe** (first docker slot, minutes): compile+link tiny `<expected>`/`<format>`/`<ranges>` TUs with
   (a) clang-14 wrapper, (b) clang-19 + SDK libc++, (c) clang-19 + apt `libc++-19-dev` headers via
   `-nostdinc++ -isystem` linked to the SDK `libc++.tbd` (check undefined symbols against the SDK tbd and
   iOS 17.6 device dylib). Go/no-go for kwin/libkscreen.
2. If (c) works, kwin/libkscreen get a per-recipe compiler override. This is exactly what the
   webkit-toolchain worker is scoping; **ask main to have it share its libc++-header result; I will not edit toolchain files.**
3. Fallback with no new toolchain: a ~100-line `tl::expected` polyfill dir (force `-isystem`) plus patching the 2
   `std::format` uses in kwin. Small, kept inside kwin/libkscreen fix scripts.

Qt/KF6 themselves stay on clang-14 unless the pilot shows otherwise.

## 3. Fate of our port work

Measured on the host (6.1.5 tree vs 6.4.6 tree vs 6.8.4 tree, fix scripts re-run with a GNU-sed shim; harness in the session scratchpad).

| Item | Result on new sources | Decision |
|---|---|---|
| qtbase.mk patches 1-9 (cocoa guard, `CONDITION MACOS AND FALSE`, iosexec fixup, shadow-header rm, collator/kqueue, fontconfig ungate, XKB synth, ATSPI2 synth, GLDEBUGPROC) | Every anchor still present in 6.8.4 (same file layout). `CONDITION MACOS` blocks: 10 -> 11 (new `Gui ... MACOS AND QT_FEATURE_opengl`, auto-disabled by the sed). | **Carry** unchanged; pilot confirms. Darwin-masquerade approach **kept** (nothing in 6.8 gives us a shared-lib UIKit port). |
| Qt feature flags in qtbase.mk | names unchanged | Carry; re-run configure and read feature summary. |
| qtdeclarative-ios-fixes.sh | **hard fails**: flickable initialiser now `platformTheme()->themeHint(...)` | **Rework** (same constants, new anchor). Pilot checks the crash it fixed is still real. |
| qtwayland-ios-fixes.sh | **hard fails**: `setPopup` now uses `unique_ptr<Positioner>`; `surfaceRole` hunk anchor intact | **Rework** the popup hunk (insert attachPopup after `m_popup = new Popup(...)`). The three `qgenericunixthemes` seds still match. |
| qtsvg/qt5compat/shadertools/imageformats/tools/sensors | no patches | Carry; add Qt CVE diffs (section 4). |
| kf6-common.mk / gen-kf6-recipes.py TABLE | version vars + URL macros change; new deps (below) | **Carry + edit generator**. New: `kdecoration`->KDecoration3, knotifyconfig `Qt6Multimedia REQUIRED` unless Canberra (demote), PWP 1.18, wayland-protocols >= 1.46 for kwindowsystem (we ship 1.49: OK), many new `Qt6GuiPrivate` finds (private headers must stay staged). Existing `if(APPLE)` seds (kguiaddons, kwindowsystem, kidletime, knotifications, solid, kcoreaddons) must be re-audited against 6.24 anchors; the generator seds do not all fail loudly. |
| kwin-ios-fixes.sh (1136) + gpu-backend (517) + kwin-ios-gpu/ (~870) | fixes script **aborts at the touch-point scale hunk** on 6.4.6 (earlier hunks apply); input.cpp libinput guards and the EGL/IOSurface templates are unverified against 6.4's refactor | **Rework**, the single biggest item. Strategy: do not carry the perl blobs blindly; port in layers (baseline Darwin compile -> nested backend -> IOSurface/ANGLE backend -> scale contract), each with a hard "anchor missing" failure. New: drop systembell plugin (Canberra REQUIRED unconditional; only that plugin uses it), Libinput floor 1.26 (already demoted), libdisplay-info 0.2.0, KDecoration3. The owned `kwin-ios-gpu/*.cpp` files must be diffed against 6.4's `wayland_egl_backend` API. |
| plasma-workspace-ios-fixes (1395) | hard fails (`substring not found`) | Rework |
| plasma-desktop-ios-fixes (507) | hard fails (taskmanager `qmldir` moved) | Rework |
| libkscreen / kscreen / powerdevil / kde-cli-tools / kactivitymanagerd fixes | hard fail (XCB block, OSD block, KF6 COMPONENTS line, kioclient add_executable, sed form) | Rework (small each) |
| plasma-mobile fixes+stubs (1769+1424), plasma-nano, libplasma, systemsettings, plasma5support, plasma-integration, plasma-pa, polkit-kde-agent-1, xdg-desktop-portal-kde, layer-shell-qt (533) | scripts run without error; changed-line counts differ (mobile 2236 -> 1684, nano 93 -> 27) so some hunks silently no-op | **Carry, then audit**: add an "applied marker" check per hunk so silent no-ops become failures. layer-shell-qt (352 lines changed, identical both versions) is the safest. |
| Gear fix scripts (kate, konsole, kpty) | not yet run | Carry, re-verify in Gear wave. |
| Device-side contracts (KWIN_XIOS_HOST_OUTPUT_SCALE, kde-scale/IOSurface notes) | depend on KWin internals | Re-prove on device after the port; keep the 6.1.5 knowledge in `docs/handoff/kde-kf6.md` until then. |

New silent-failure guard (do this first in phase 2): a `lib/apply-hunks` helper, or a wrapper that diffs
before/after and asserts a minimum changed-line count per script, so nothing "applies" by matching nothing.

## 4. Security: what the new versions fix

Verified against kde.org/info/security and download.qt.io CVE dirs.

| Item | Status in the lane |
|---|---|
| Qt CVEs (qtbase 14575, 3512, 4211, 5455, 5992, 6338, 11573, 19248, 76151, 78253; qtsvg 10728, 10729, 6210, 8168; qtdeclarative 12385, 14576, 79616; qt5compat 9499; qtimageformats 5683) | Qt publishes an official `6.8` diff for each. Dry-run on the 6.8.4 trees: all apply or are already in 6.8.4, except hand-resolve cases: CVE-2025-3512 and CVE-2026-11573 report already-applied/reversed hunks (verify), CVE-2026-8168 part 0002 has one failing hunk (qsvgtinydocument.cpp), 19248/79616 fail only in `tests/`. Ship them as `x11/ports/qt68-cve/*.diff` applied in each `-setup`, with a post-apply `.rej` check. |
| KCoreAddons CVE-2026-41526 (KShell) | **Remains**: fixed in 6.25, we are on 6.24 (6.25 needs Qt 6.9). Backport upstream commit 6153c9ae (verify hash) as a port patch. |
| konsole CVE-2025-49091 (< 25.04.2), dolphin CVE-2026-41525 (< 25.12.3), ark CVE-2024-57966, okular fax x5 (<= 26.04.0) | Fixed by Gear 26.08.1. |
| poppler | Fixed to 25.11 (see 1). Anything found after 25.11 stays open until the C++23 lane. |
| plasma 6.1.5 is EOL; no open advisory against it, but 6.4 gets backports for a while | Gain. |

## 5. Packaging and upgrade path

Names do not change (`qt6-base`, `kf6-*`, `kwin`, ...), so the new debs are in-place upgrades of the same
paths (`libQt6Core.6.dylib` etc.). **A partial upgrade is a broken stack** (Qt private ABI is used by kwin, qtwayland
plugins, Gear apps). Rules:

- Versions: `qt*: 6.8.4-1+ios1` (qt6-base keeps its `-N` epoch-ish scheme), `kf6-*: 6.24.0+ios1`, plasma `6.4.6+ios1`,
  Gear `26.08.1+ios1`, poppler `25.11.0+ios1`. All sort above current, so production `.deb` filenames change.
- Soname/package changes: `libpoppler140` -> **`libpoppler154`** (new package; old stays for rollback);
  `libpoppler-glib8`, `libpoppler-qt6-3` keep sonames; `kdecoration` -> KDecoration3 (libkdecorations3, replaces libkdecorations2; breeze and kwin rebuilt);
  `libdisplay-info1` -> libdisplay-info 0.2.0 (new soname, only `kwin` depends on it); new debs `qt6-positioning`, `qt6-location`.
- Must rebuild (from `repo/Packages` reverse deps of `qt6-*`): all 175 packages reachable from qt6 (every `kf6-*`, plasma/kwin family,
  `phonon4qt6`, `qcoro6`, `qt-wayland-gl-smoke`, Gear apps, `xios-kde`). Poppler: only `okular` links `libpoppler.140`
  directly. **GNOME-side consumers (`papers`, `zathura-pdf-poppler`, `gimp`) link only `libpoppler-glib.8` (verified with
  `otool -L`), soname unchanged: no rebuild, they just pick up the new `libpoppler-glib8` + `libpoppler154`.** Nothing GNOME-pinned
  is pulled in (needs glib >= 2.72; we have 2.78). I will `otool -L`-check the new glib wrapper for removed symbols.
- Co-upgrade enforcement: generate `Breaks: <every KDE pkg> (<< new)` on the new `qt6-base`, plus a new `xios-kde` that
  `Depends:` every unit with `>=` versions. A single `apt-get install xios-kde` is then one transaction.
  Every Breaks target has a new version in the same transaction, so apt upgrades rather than removes.
- Device upgrade path (proposed to Max before any device action): (1) bundle the currently installed old debs (all in `repo/debs`) into a
  rollback dir on the iPad and record `dpkg --get-selections` + `apt-mark showmanual`; (2) `apt-get -s` as sanity only (not proof);
  (3) one `apt-get install xios-kde` from staging, never `dist-upgrade`/`--fix-broken`; (4) rollback = `dpkg -i` of the saved set.
  No device work until cleared.
- Re-sign: host-side `ldid` DER re-sign through the existing `resign-graphics-packages.py` flow for kwin and anything with GPU entitlements.
  `x11-package-portability-minos` stamping and the dyld-load audit run on the whole set (libintl trap).
- Version policy file: `upstream-version-policy.json` tracks (qt 6.6, kf6 6.3, plasma 6.1, gear 24.08) must change with the merge to
  (6.8, 6.24, 6.4, 26.08, pwp 1.18). That file is outside my ownership allow-list only in the sense that the lane owns it; edited on this branch at the end.

## 6. Build order, volumes, resources

Single new volume `procursus-vol-kde68`, seeded by cloning `procursus-vol-qt` and then **purging staged Qt/KDE files from
`build_base`** and `host-qt-6.6.3`, `build_work`, `build_stage`, `build_dist`. The 6.6 volumes (`-qt`, `-kf6`, `-kf6-closure-*`) are untouched and keep
the 6.6 lane rebuildable. Debs for this lane go to `x11/linux-build/out/` in this worktree (empty; seeded with copies of the dependency debs: angle,
libicu74 + libicu-dev +ios1, wayland family, libxkbcommon, libdrm/gbm, libxcvt, at-spi/atspi, epoll-shim, libepoxy, libintl, libvorbis, libei), read from the main `out/`.
Build recipes live in the same recipe files on this branch (version vars bumped in place); `main` keeps 6.6.

Disk (Mac has ~73 GiB free; existing volumes ~136 GB): clone of qt volume ~9 GB, grows to ~12 GB after Qt 6.8; KF6+Plasma+Gear on top is
~+15-20 GB (old kf6 volume is 17.5 GB). **Estimate 30-35 GB total new**, leaving ~38 GB. `procursus-vol-kf6-closure-20260719` (12.9 GB, a read-only workaround clone)
is the obvious reclaim candidate; **Max's call, I will not delete it.**

RAM: VM is now 27.4 GiB; the old "-j2 retry" OOM guards for qtdeclarative/KWin stay (cheap) but the first pass can run `-j8`.

Waves (each wave = one slot request, each ends with debs + staged `build_base`):
- **W0** prep: create/seed volume, purge, cmake 3.31 in `build_tools`, P0 libc++ probe.
- **Q (pilot)**: host Qt 6.8.4 (qtbase + shadertools + declarative + wayland host tools), cross qtbase, then module ladder: shadertools, declarative, 5compat, wayland, svg, imageformats, tools, sensors, positioning, location.
- **P** prereq libs: plasma-wayland-protocols 1.18, libdisplay-info 0.2.0, pulseaudio-qt 1.6, qcoro6, phonon, KDecoration3 (early).
- **K** KF6 6.24 host tooling + the 40-unit set (+ kde extras: kded, runner, newstuff, ...).
- **W** kwin 6.4.6, layer-shell-qt, kglobalacceld, kwayland (C++23 gate).
- **PL** libplasma, activities(+stats), plasma5support, libkscreen, kscreen, kactivitymanagerd, plasma-workspace, plasma-desktop, plasma-integration, plasma-pa, powerdevil, systemsettings, milou, breeze, plasma-nano, plasma-mobile, polkit-kde-agent-1, xdg-desktop-portal-kde, kde-cli-tools.
- **G** poppler 25.11 (+glib, qt6), Gear: ark dolphin gwenview kate kcalc konsole kwrite okular.
- **S** packaging: control/Breaks/meta, resign, minos, audit.

Pilot go/no-go (qtbase 6.8 alone, then ladder):
1. qtbase 6.8.4 configure, build, install, package: all Qt6 core libs + `libqwayland-generic` present, `FEATURE_*` summary matches 6.6 (dbus, xkbcommon, icu, opengl es2, fontconfig, atspi).
2. `otool -L` of all dylibs: no unresolved frameworks beyond the shared-cache set; `nm` shows no dead PrintSupport/UIKit stubs; no `.rej` from CVE diffs.
3. Whole ladder (+positioning, location) builds; `qml`/`qt-wayland-gl-smoke` link. (Device tests wait for Max's go-ahead.)
No-go triggers (stop and report): qtbase needs structural patches beyond the carried set (> ~2 new hunks of the kind in qtbase.mk), clang-14 cannot compile Qt 6.8, or the ladder needs a toolchain change affecting every recipe.

Time guesses: host Qt ~1 h, cross qtbase ~40 min, modules ~1.5 h, KF6 ~2-3 h, Plasma ~3 h plus KWin rework (days of porting, not CPU), Gear ~2 h.

## 7. Risks

1. KWin 6.4 port (hunks, GPU backend vs 6.4 refactor) and libc++ for `<expected>`/`<format>`.
2. KF6 6.24 under Plasma 6.4.6 (10 minors apart; policy says source-compatible; fallback KF 6.19).
3. Silent no-op perl hunks in Plasma fix scripts.
4. Qt 6.8 behaviour changes in the Darwin masquerade (platformTheme null, FlickDeceleration).
5. Disk.
6. Device upgrade atomicity (section 5).

## 8. Flags for Max (not acted on)

- KF6 6.24 (not 6.27) because of the Qt 6.9 floor from KF 6.25; KShell CVE therefore needs a backport.
- Poppler 25.11 vs 26.x: 26.x needs the C++23 toolchain.
- Reclaiming `procursus-vol-kf6-closure-20260719` if disk gets tight.
- Gear 26.08.1 vs 25.12.3 (conservative, fits KF 6.22 / no cmake bump).
- No blocker requiring a stop was found: no GNOME/glib conflict, no base-system shadowing (ICU stays 74.2).
