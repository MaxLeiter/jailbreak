# WebKitGTK 2.44.4 -> 2.54: toolchain plan

Author: claude-sonnet-5-5 worker, 2026-10-01. Scope: get "Web" (Epiphany 43.1) and Geary 46.0 off
WebKitGTK 2.44.4, which is a dead series (no 2.44.5+; every WSA advisory since 2025 is unfixed
there). Max's decision: scope a compiler upgrade, then execute it.

Evidence marked "probe" was gathered 2026-10-01 by downloading the upstream 2.52.6 and 2.54.0
tarballs and reading/dry-running against them. "UNVERIFIED" means it needs the first container
run (listed in the build order).

## 1. Decisions in one screen

| Question | Answer |
|---|---|
| Target | **WebKitGTK 2.54.0** (released 2026-09-16, newest stable; GTK3 `webkit2gtk-4.1` API still built: `USE_GTK4=OFF` -> API `4.1`, soname `libwebkit2gtk-4.1.0`). Fallback if Skia-on-Darwin is a wall: **2.52.6** with `-DUSE_SKIA=OFF` (last series with a Cairo path). |
| Compiler | **clang-19, already in the toolchain image** (Dockerfile, apt.llvm.org layer added for Ladybird). Nothing to build. Opt-in per recipe via new wrappers; the default `aarch64-apple-darwin-clang` (Debian bookworm clang 14.0.x) is untouched. Linker stays cctools `ld64`, sysroot stays iPhoneOS16.5.sdk. |
| C++ library | Order of attempts: **A** SDK libc++ 15.0.6 headers (what Ladybird uses today) -> **B** LLVM-19 libc++ *headers* with Apple availability annotations, still linking the system `/usr/lib/libc++.1.dylib` -> **C** static libc++ built from LLVM 19 under a private ABI namespace. None ships a libc++ dylib, so nothing shadows a base-system package. |
| Epiphany / Geary | **No version bump, no GNOME-pin crossing.** Rebuild both against the new headers and re-pack: `epiphany` + `epiphany-native` 43.1+ios5, `geary` 46.0+ios2. Both only need the 4.1 API (Geary >= 2.30). |
| New package deps | None outside the tree. Skia, ANGLE, xdgmime, sysprof-capture, unifdef are bundled in the tarball. Floors vs our stack all pass (table in 5). |
| Blockers needing Max | **None of the three stop-conditions hit** (no GNOME pin crossed, no base package shadowed, no change to other recipes' output). Two coordination items are flagged in section 8 (a concurrent WebKit lane; volume choice). |

## 2. What the current toolchain is

- Procursus cross env, Docker image `procursus-xbuild:bookworm-arm64` (`x11/linux-build/Dockerfile`):
  Debian bookworm, native arm64 on the Apple Silicon host (no qemu).
- Default compiler: cctools-port's `aarch64-apple-darwin-clang{,++}` wrapper, which drives the Debian
  bookworm `clang` package (**clang 14.0.x**; confirm with `--version` in step 0). It parses C++20 only.
  This is exactly the documented failure: 2.52.4 configured cleanly but "failed immediately on C++23
  constructs that the current iOS cctools Clang 14 misparses" (`geary-webkitgtk.md`).
- Linker/tools: cctools-port `ld64` (the image's `aarch64-apple-darwin-ar` is clobbered; Ladybird
  works around it with an `llvm-ar-19 --format=darwin` shim, we do the same).
- Sysroot: `iPhoneOS16.5.sdk`, whose libc++ is **15.0.6** (`_LIBCPP_VERSION 15006`, probe of
  `linux-build/sdk/iPhoneOS.sdk/usr/include/c++/v1/__config`). Deployment floor is iOS 16.0.
- Second compiler already present: **clang-19** from apt.llvm.org (Dockerfile last toolchain layer,
  comment: "adds ONLY a newer compiler front end"). `build-ladybird-{wave4,app-engine,wayland}.sh`
  drive it as `clang++-19 --target=arm64-apple-ios16.0 -isysroot $SDK -stdlib=libc++ -B$SHIM
  -fuse-ld=$SHIM/ld -D__IOS__ ...`. UNVERIFIED that the `:bookworm-arm64` tag (vs `:skia`) has the
  layer; both images are 4.97 GB so they are very likely the same image. Step 0 checks.

## 3. What WebKitGTK needs

Compiler floor (Source/cmake, probe): 2.44 GCC>=10.2 ... 2.46/2.48 GCC>=11.2 ... **2.50/2.52/2.54
GCC>=12.2**. There is no explicit clang floor in CMake; the real floor is the language level:
`CMAKE_REQUIRED_FLAGS --std=c++2a` (2.44) became **`--std=c++2b`** from 2.46 onward
(`WebKitCompilerFlags.cmake`). Clang 14 accepts `-std=c++2b` but misparses WebKit's C++23 use;
**clang 19 is comfortably above any reasonable floor** (WebKit's own Linux bots build with
clang 17-19 and GCC 12-14).

| Series | std | Renderer (GTK port) | Notable change |
|---|---|---|---|
| 2.44.4 (ours) | c++2a | Cairo | |
| 2.46 | c++2b | Skia opt-in (GTK4) | |
| 2.48 / 2.50 | c++2b | Skia default (little-endian), `USE_SKIA=OFF` still allowed | GPU process default ON (needs GBM) |
| 2.52.6 (2026-08-19) | c++2b | Skia default, Cairo only via `USE_SKIA=OFF` | |
| **2.54.0 (2026-09-16)** | c++2b | **Skia only** (`USE_CAIRO OFF` hard-set, OptionsGTK.cmake:313) | `webkitgtk-2.54.0.tar.xz` 48 MB |

libc++ feature use, counted by grepping Source/{WTF,JavaScriptCore,WebCore,WebKit} (probe):

| Feature | files 2.52.6 | files 2.54.0 | in libc++ 15 headers? |
|---|---|---|---|
| `std::ranges::` | 286 | 304 | partial (algorithms yes; `contains`, `fold`, many views no) |
| `std::views::` | 50 | 61 | partial |
| `std::span` | 1297 | 1359 | yes |
| `std::bit_cast` | 388 | 397 | yes |
| `std::expected` / `<expected>` | 3 | 3 + 2 | **no** (libc++ 16) |
| `std::format` / `<format>` | 1 | 2 | experimental only |
| `std::source_location` | 2 | 2 | **no** |
| `std::to_chars`/`from_chars` | 2 / 1 | 2 / 1 | yes (availability-gated) |
| `std::to_underlying` | 2 | 112 | yes |
| `std::jthread`, `stop_token`, `move_only_function`, `<print>`, `<semaphore>`, `barrier`, `latch` | 0 | 0 | n/a, not used |

Most third-party-ish uses (fast_float, simdutf, FlipBytes) are guarded by `__cpp_lib_*` feature
macros, so a too-old library degrades gracefully. The unguarded hits (`std::expected`,
`std::source_location`, parts of ranges) are the real gaps and are small in count. This is why the
plan does not assume a library swap up front: Ladybird's AK compiled "zero library-feature errors"
against the SDK libc++ (`ladybird-plan.md`) because it uses its own vocabulary types; WebKit likewise
has its own `WTF::Expected`, `WTF::Vector`, `WTF::String`. Step 1 measures instead of guessing.

## 4. Does Ladybird already give us a toolchain?

Yes, the compiler half. Ladybird needs clang >= 19 for C++23; the Dockerfile layer, the
`lb-cc`/`lb-cxx` wrapper pattern, the `ar` shim, and the fake `xcrun`/`sw_vers` (CMake's Darwin
probe) are all proven on `procursus-vol-ladybird` (read-only reference; the ladybird-rebase worker
owns those files, we copy the pattern into our own files rather than edit theirs).
What Ladybird does **not** settle: it links the SDK libc++ and never needed a newer library, and it
builds a CMake project with its own types. WebKit is a bigger and more std-heavy consumer, so the
libc++ question (A/B/C) stays open until probed. Ladybird's advice, which we adopt: **never put a
newer libc++ *dylib* into `/var/jb`**; static-link or use headers only.

## 5. The runtime question: C++23 library vs libc++ in iOS 17.6

The device runs iOS 17.6.1, whose `/usr/lib/libc++.1.dylib` is newer than the SDK's, but the package
floor (MinimumOSVersion) is iOS 16.0-16.2, so the contract we can rely on is the 16.5 `libc++.tbd`
in the SDK (1420-line export list: has `to_chars`, `__libcpp_verbose_abort`; has **no**
`bad_expected_access`, **no** `__hash_memory`). Device libc++ is not read until a device test is cleared.

| Option | How | Pros | Cons / consequences |
|---|---|---|---|
| **A** SDK libc++ 15 headers | what Ladybird does | zero new infrastructure | `std::expected`, `source_location`, newer ranges missing -> source patches or fail |
| **B** LLVM-19 libc++ headers, system dylib | `-nostdinc++ -isystem <llvm19>/include/c++/v1` with a Darwin `__config_site` (`_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS`), `-mios-version-min=16.0` | This is how Xcode 16 targets old OSes: availability annotations turn "needs a newer runtime" into a *compile* error instead of a dyld failure. No ABI skew with the rest of the stack (still `std::__1`, same dylib). No shadowing. MinimumOSVersion stays 16.0 | Headers from apt `libc++-19-dev` are Linux-configured, so we supply our own `__config_site`; a few out-of-line symbols (e.g. `std::bad_expected_access<void>` key function, `__hash_memory`) are not in the 16.5 dylib, so those uses need a tiny local definition or a patch |
| **C** static libc++ 19 | build `libcxx`+`libcxxabi` from LLVM 19.1.x sources for `arm64-apple-ios16.0`, `-DLIBCXX_ABI_NAMESPACE=__xios`, link `-static` into `libjavascriptcoregtk` + `libwebkit2gtk` + helper processes only | independent of device libc++ entirely | two libc++ copies in one process; any std type crossing into a library built against the SDK libc++ (ICU C++ API, glib is C so fine) changes mangling and fails at link, visible but costly. Bigger binaries. WebKit is `-fno-exceptions -fno-rtti`, which limits libc++abi interplay |
| ~~D~~ shipped libc++ dylib in `/var/jb/usr/lib` | rejected | | would shadow/skew against the base system; same class as the libintl / openssl vendoring problems in memory. Not on the table without Max |

Recommendation: **A first (cheap probe), B if A fails, C only if B fails.** MinimumOSVersion: pass
`-miphoneos-version-min=16.0` on compile and link lines (the drift root cause in
`x11-package-portability-minos`), then `stamp-minos.py` as the final step. libc++ choice does not
change the stamped floor under A/B.

## 6. Which version, and what it drags in

Why 2.54.0 and not 2.52.6: WebKitGTK security fixes land on the newest stable only; a 2.52 landing
in October becomes the next dead series about when 2.56 ships. 2.54 removes Cairo, so it forces the
Skia work we would otherwise be deferring by one release. Risk containment: do the work in two
milestones so a Skia wall costs us a version, not the project.

- **M-toolchain**: `-DUSE_SKIA` untouched, configure + WTF + JSC (pure compiler/library question).
- **M-skia**: WebCore with Skia (bundled `Source/ThirdParty/skia`; deps freetype/fontconfig/harfbuzz/
  ICU/png/jpeg/webp are all already staged). If the Darwin file selection for Skia is a wall, fall back
  to 2.52.6 + `-DUSE_SKIA=OFF`, which keeps today's Cairo path, and flag to Max.

Option names in `webkitgtk.mk` all still exist in 2.54 (probe: every `-DENABLE_*`/`-DUSE_*` in the
recipe is defined in 2.54 `OptionsGTK.cmake`/`WebKitFeatures.cmake`; only `USE_APPLE_ICU`, already a
no-op, is gone).

Dependency floors, 2.54 vs our tree (probe of `OptionsGTK.cmake`):

| Dep | 2.54 needs | We ship | OK |
|---|---|---|---|
| GLib (GioUnix, Thread, Module) | 2.70 | 2.78.0 | yes |
| libsoup | 3.0.0 (soup2 gone) | 3.4.4 | yes |
| GTK3 (`USE_GTK4=OFF`) | 3.22 | 3.24.38 | yes |
| ICU | 70.1 | 78.3 | yes |
| HarfBuzz+ICU | 2.7.4 | staged | yes |
| Cairo | 1.16 (UI process only) | staged | yes |
| libepoxy | 1.5.4 | staged | yes (UNVERIFIED exact ver) |
| libxml2 | 2.9.13 | staged | yes |
| Freetype | 2.9 | staged | yes |
| Wayland / wayland-protocols | 1.20 / 1.24 | staged | UNVERIFIED protocols ver |
| libxslt, libsecret, sqlite, png, jpeg, webp+demux, gcrypt, tasn1, ATSPI | unchanged | staged | yes |

`stage-webkitgtk-deps.sh` already stages this list, so no new dep recipes are expected. Host tools:
CMake >= 3.20 (bookworm 3.25), Ninja, Ruby, gperf, Python, `unifdef` (all in the build-gnome preamble).

Epiphany 43.1 / Geary 46.0: unchanged versions. The 4.1 API is frozen (removals only happen in the
6.0 API), the soname stays `libwebkit2gtk-4.1.0`, JSC stays `libjavascriptcoregtk-4.1.0`, and the web
extension ABI (`webkit2gtk-web-extension-4.1`) is the same. They are rebuilt (headers changed, Geary's
extension links against JSC) and re-versioned so production filenames stay immutable. `epiphany-native`
pins `epiphany (= 43.1+ios4)`, so it re-versions with it. **Does not cross the GNOME 46 pin**
(`x11-gnome-desktop-feasibility`: GTK3, glib 2.78, Epiphany 43 is the last GTK3 release).

## 7. Port delta from 2.44.4 (probe: independent `patch --dry-run` of the 14 mainline patches)

| Patch | 2.52.6 | 2.54.0 |
|---|---|---|
| 0001 darwin process check (bmalloc CMake) | clean | **rebase** (`Source/bmalloc/CMakeLists.txt`) |
| 0002 AbortWithReason header (`PlatformGTK.cmake`) | rebase | rebase |
| 0003 `__muloti4` | clean | clean |
| 0004 unix IPC attachments | clean | clean |
| 0005 unix IPC connection metadata | rebase (Connection.cpp, HandleMessage.h) | rebase |
| 0006 XPC sendability (needs hydrated bmalloc file) | n/a pre-hydrate | n/a pre-hydrate |
| 0007 WTF XPC sendability | clean | clean |
| 0008 shared-memory serializer | rebase | rebase |
| 0009 glib process launcher | rebase (3 hunks) | rebase |
| 0010 / 0011 / 0012 viewport guard, Gigacage, ANGLE EGL path | clean | clean |
| 0013 ANGLE iOS platform sources | clean | **rebase** (ANGLE CMake) |
| 0014 X11 null-display accessibility | needs file check | needs file check |

So about 8 of 14 apply as-is on 2.52/2.54, 5-6 need hand rebasing, and the hydration list
(`hydrate-webkit-apple-sources.sh`, pinned to a 2.44-era commit) must be re-derived for the 2.54
commit. New work not in the 2.44 stack: Skia source selection for Darwin, and anything the first
`WebCore` compile finds. Estimated patch-port effort: 1-2 days of iteration, dominated by build time.

### Concurrent lane overlap (flag, not acted on)

Worktree `.claude/worktrees/webkit-jit-hwgl` (branch `worktree-webkit-jit-hwgl`) carries
**uncommitted** 2.44.4 patches 0015-0018 (IOSurface accelerated compositing, DMABuf-renderer gate,
EGL config), JIT-on flags and a `+ios4` build in `linux-build/out/`. They are not on main, not
published, and **do not apply to 2.52/2.54** (their target files moved). This plan builds from main's
published stack 0001-0014 and keeps the 2.44 recipe and patch dir untouched. If Max wants JIT +
hardware compositing in the 2.54 build, that lane's patches need a second forward port after it lands.

**Decision 2026-10-01 (main):** that lane is dormant (no changes for 3+ days); its uncommitted 2.44
patches 0015-0018 stay preserved as files in that worktree, which we do not touch. **Patches 0015-0018
need a forward port to 2.54 later** (not part of this task). Overwriting its 2.44 build state in
`procursus-vol-gtk` is acceptable. No clone volume (host disk ~61 GiB free): the build uses the shared
`procursus-vol-gtk` with distinct work dirs, after `upd-wave-gnome` releases it (that wave also bumps
libsoup3 to 3.8.0, so we build against libsoup 3.8; 2.54 needs only >= 3.0).

## 8. Opt-in mechanics (nothing existing changes)

New files only; no edit to `webkitgtk.mk`, `epiphany.mk`, `geary.mk`, `Dockerfile`, `target-env.sh`,
`build-gnome.sh`, or the 2.44 patch dir:

- `x11/linux-build/tools/xios-clang19-env.sh`: writes `cc19`/`cxx19` wrappers (clang-19, `--target=
  arm64-apple-ios16.0`, `-isysroot`, `-miphoneos-version-min=16.0`, ld64 via `-B/-fuse-ld`, optional
  libc++ mode A|B|C), the `ar` shim, fake `xcrun`/`sw_vers` and a CMake toolchain include. Sourced only
  by the new recipe.
- `x11/linux-build/recipes/webkitgtk-modern.mk`: SUBPROJECT `webkitgtk-modern`; separate
  `build_work/webkitgtk-modern`, `build_stage`, `build_dist` (so it cannot disturb the 2.44 trees);
  version `2.54.0+ios1`; produces the same four package names via new control files
  `build_info/libwebkit2gtk-4.1-0.control` etc. are reused unchanged (version token only).
- `x11/ports/webkitgtk-2.54/patches/` + `series`: the forward-ported stack.
- `epiphany`/`geary` rebuild: version overrides on the command line
  (`DEB_EPIPHANY_V=43.1+ios5`, `DEB_GEARY_V=46.0+ios2`) so their recipes are not edited.
- The driver is the existing `build-gnome.sh` via `TARGETS=` (it already installs
  `recipes/*.mk` into the Procursus tree); if a CC override cannot be passed through it, a thin
  `build-webkit-modern.sh` wrapper (new file) sets it. Package names collide with the 2.44 debs by
  design: only one producer is chosen at publish time (not our step).

## 9. Build order, volume, RAM and disk

Order (each step is a separate container run, checked before the next):

0. Image sanity (seconds): `clang-19 --version`, `aarch64-apple-darwin-clang --version`, `ldid`.
1. **libc++ probe** (minutes): `-fsyntax-only` of ~30 representative TUs from 2.54 WTF/JSC/WebCore
   (using generated headers from a configure) under modes A then B. Output: the exact gap list.
   Decide A/B/C here.
2. Configure + `WTF` + `JavaScriptCore` (JIT stays off, C-loop as in the current recipe).
3. `WebCore` (largest step, Skia included).
4. `WebKit` + install + package + host re-sign (existing `repack`/ldid scripts; host-ldid-signature
   problem means sign per the existing `build-gnome.sh` collect path and re-sign on device later).
5. Epiphany rebuild, `epiphany-native` repack, Geary rebuild.
6. `stamp-minos.py --apply` last.

Resources (host: 16 CPUs, Docker VM now 27.4 GiB):
- RAM: the old 7.7 GiB VM forced `-j2`..`-j4`; WebCore unified TUs are the OOM risk at roughly 2-3 GiB each.
  Plan `ninja -j8` first, auto-retry `-j3` on kill (the Qt pattern), `WEBKIT_NINJA_JOBS` knob.
- Wall time: a full 2.44 engine took multiple hours at `-j4`; expect **3-6 h** for 2.54 (Skia adds
  ~600 TUs) at `-j8`, plus 30-60 min for the Epiphany/Geary tail. Incremental rebuilds are minutes.
- Disk: the whole of `procursus-vol-gtk` is 16.2 GB including the old WebKit tree. A 2.54 tree is
  estimated at **15-20 GB** (sources 0.5 GB, objects 10-14 GB, install/stage/dist 2-3 GB). Mac free space
  is ~71 GiB. Two ways to host it: (a) new work dirs inside `procursus-vol-gtk` (+15-20 GB, but that
  volume is shared with the other WebKit lane), or (b) `docker volume` clone to
  `procursus-vol-webkit-modern` (16 GB copy + 15-20 GB build = **~35 GB**, fully isolated).
  Recommend (b) if the other lane is active, else (a); this needs Max's / main's call at the slot
  request. No pruning of anything, ever.

## 10. Risks, ranked

1. **Skia on the GTK-on-Darwin build** (new code path, 2.54 has no Cairo escape hatch). Mitigation:
   2.52.6 + `USE_SKIA=OFF` fallback.
2. **libc++ gap handling** under A/B (unguarded `std::expected`/`source_location`/ranges). Mitigation:
   probe first, then B, then C.
3. **Patch forward-port drift** in IPC/process-launcher code (5-6 rebases) and ANGLE (0013, plus the
   0012 EGL loader against newer ANGLE).
4. **Rendering/runtime regressions on device** (nothing runs until Max clears a device test):
   process launch, Gigacage allocation failure path (0011), WebGL via ANGLE, Wayland/X11 display.
5. **Concurrent-lane collision** on `procursus-vol-gtk`, `linux-build/out/` filenames, and package
   names (see section 7). Mitigation: separate recipe/version space and volume (b).
6. **Disk** (volumes already 136 GB; Mac ~71 GiB free). Mitigation: estimate above, `df -h /` on every
   slot request.

## 11. Effort

Plan 1 day (done), toolchain wrappers + probe 0.5 day, patch port + WTF/JSC 1-2 days, WebCore/Skia
1-3 days (the uncertain part), Epiphany/Geary tail 0.5 day, device verification a separate cleared
session. Builds dominate wall-clock; most of it is unattended.

## 12. Probe results (2026-10-01, steps 0-1; throwaway container, read-only source mount, no volume)

Image `procursus-xbuild:bookworm-arm64`: `aarch64-apple-darwin-clang` = Debian clang **14.0.6**;
`clang-19` = Debian clang **19.1.7** (present in this tag, so no image rebuild); `/usr/lib/llvm-19`
has no libc++ headers by default (`apt install libc++-19-dev` supplies them; headers only are used).

- **Mode A (SDK libc++ 15) is out.** `Source/WTF/wtf/StdLibExtras.h:36` includes `<expected>`
  unconditionally in 2.54, and nearly every TU includes StdLibExtras.h: first error on every TU is
  `'expected' file not found`. A would need a hand-written `<expected>` shim for all of WebKit.
- **Mode B (LLVM-19 libc++ headers, system dylib) works for the language/library level.** With
  `-nostdinc++ -isystem <llvm19 c++/v1>` (own `__config_site`: ABI v1, `__1`, pthread, vendor
  availability annotations left on), `--target=arm64-apple-ios16.0 -miphoneos-version-min=16.0`,
  `-std=c++2b -fno-exceptions -fno-rtti`:
  - a synthetic TU using `<expected>`, `<source_location>`, `<format>`, `<charconv>`, ranges/views
    pipelines, `std::span`, `std::to_underlying` compiles clean;
  - real 2.54 WTF TUs `StringImpl.cpp, Vector.cpp, Seconds.cpp, WTFString.cpp, StringView.cpp,
    AtomStringImpl.cpp` compile clean (0 errors). The other probed TUs failed only on environment
    (glib headers not mounted in the probe, generated `cmakeconfig.h`, libpas include layout), plus
    one real Darwin item to patch: `bmalloc/libpas/src/libpas/pas_lock.h:119` uses
    `os_unfair_lock_flags_t`, which the 16.5 SDK lacks (same class as patches 0006/0007).
- Link-time (undefined libc++ symbols vs the 16.5 `libc++.tbd`, e.g. `bad_expected_access`) is not
  testable by syntax-only; it is the first thing checked when WTF/JSC link.

Decision: **use mode B from the start; C stays the fallback.** Libc++ headers come from the
`libc++-19-dev` apt package (headers only), with our own Darwin `__config_site`, installed by the
new `xios-clang19-env.sh` at build time.

## 13. Build result (2026-10-02, phase 2 up to the device gate)

Built on `procursus-vol-gtk` (work dir `webkitgtk-modern`, no change to the 2.44 trees) through
`x11/linux-build/build-webkit-modern.sh`; recipe `recipes/webkitgtk-modern.mk`; patch stack
`x11/ports/webkitgtk-modern/patches` (0003, 0004, 0007, 0010-0012 carried from the 2.44 stack, plus
0015-0036 new). Result: `libwebkit2gtk-4.1` 24.3 / `libjavascriptcoregtk-4.1` 11.7, minos 16.0, Mach-O
install names `@rpath/lib*-4.1.0.dylib` (same scheme as 2.44), no CoreFoundation/Foundation/libedit
dependency, only `/usr/lib/libc++.1.dylib` + libSystem from the base system, zero libc++ symbols missing.

What the 2.54 port needed (all in the patch stack): shadow APPLE for the GTK port (0018) and restore it
only at generate time for Mach-O dylib naming (0036); export the Darwin SPI headers WTF includes
(0019, 0021, 0022); plain-C++ replacements for Apple-only pieces (entitlements stub 0020, bmalloc
ProcessCheck/TZoneLog 0024, OSLogPrintStream as C++ 0022, Skia bundle lookup 0034); libpas ulock-flags
API missing in the 16.5 SDK (0016); memory footprint via task_info (0017); TZone and libdispatch
threading off like the Linux port (0025, 0026); ANGLE: accept the iOS 16 SDK, select iOS platform
sources, use the EGL display backend, system-info and dma-buf utils (0027-0029, 0033); IPC on Unix
sockets rather than Mach/XPC (0030); config fixes for VIDEO/GBM/LIBDRM/2022-API off (0031, 0032, 0033);
no readline for `jsc` (0035). Patches 0001, 0002, 0005, 0006, 0008, 0009, 0013, 0014 of the 2.44
stack are not needed in 2.54 (upstream moved or the APPLE shadow removes the need).

Build-system lesson: `xios_clang19_setup` rewrote the compiler wrappers on every container run;
the mtime bump made ninja rebuild everything each time. Fixed (idempotent writes).

Not done / flagged: WebGL is compiled (`ENABLE_WEBGL=ON`) but untested on device; JIT stays off
(C-loop), hardware compositing is the dormant lane's work (patches 0015-0018 there need a forward port
to 2.54). Device tests are the next gate.

## 14. JIT + hardware-GL WIP vs 2.54 (assessment, 2026-10-25)

Source: commit `0898414b` on `worktree-webkit-jit-hwgl` (written against 2.44.4; plan
`docs/webkitgtk-jit-hwgl-plan.md` on that branch). Checked by reading the 2.54.0 tree in
`procursus-vol-gtk` and `patch --dry-run` against it. Not built.

**Verdict: does not port cleanly; not built.** The two halves are very different sizes.

Hardware GL (patches 0015-0018 of the 2.44 dir; numbering collides with this stack's 0015-0018):

| WIP patch | 2.54 status |
|---|---|
| 0016 gate (`rendererBufferMode` accepts the iosc shim's `EGL_*_platform_wayland`) | target moved: now `AcceleratedBackingStore::rendererBufferTransportMode()` in `UIProcess/gtk/AcceleratedBackingStore.cpp:88`, same two-extension test, enum renamed `RendererBufferTransportMode`. A ~15-line re-port. On its own it buys GPU raster with one readback per frame (SharedMemory mode). |
| 0015 IOSurface render target (514 lines) | does not apply. `UIProcess/gtk/AcceleratedBackingStoreDMABuf.*`, `UIProcess/dmabuf/*.messages.in` and `WebProcess/WebPage/dmabuf/AcceleratedSurfaceDMABuf.*` are gone; the swap chain is now `WebProcess/WebPage/CoordinatedGraphics/AcceleratedSurface.{h,cpp}` (`SwapChain::Type`, `RenderTarget*` classes) and the UI side is `AcceleratedBackingStore::Buffer{DMABuf,EGLImage,GBM,SHM}`. Layer content is rasterized by Skia now (TextureMapper still composites), so the render-target code is Skia-shaped. A rewrite, not a rebase: new `BufferIOSurface` + `RenderTargetIOSurface`, messages, swap-chain selection at `PlatformDisplay::Type::Surfaceless`. Its CMake hunk is `if (APPLE)`, which our 0018 shadows to false; it would need a Darwin test instead. It also needs the compositor/broker half (`wayland/iosc.c`, `xios-metal-event-broker.m`) that never landed from `claude/geary-web-black-screen-a10d4d`. |
| 0017 typedefs outside the GBM guard | obsolete (header removed). |
| 0018 per-site EGLConfig | partly obsolete: 2.54 `GLContext` has `eglConfig()`; whatever replaces 0015 can use it. |

Estimate: gate alone half a day; the zero-copy IOSurface path 2-4 days plus the unlanded
compositor work, and device time.

JIT: the WIP's premise ("CMake flags plus an entitlement, no source patch") is contradicted by
what Bun's JSC measured on this exact iPad (`linux-build/patches/bun-webkit/0002-ios-separated-wx-jit.patch`):
an RWX anonymous mapping is created fine and then SIGBUSes on first instruction fetch, and
`MAP_JIT` is EINVAL. The GTK port's JSC uses exactly that RWX pool (`EXECUTABLE_POOL_WRITABLE`,
`ENABLE_SEPARATED_WX_HEAP` 0 off Cocoa), so flag-only JIT would crash at the first compiled
function. The 2.54 gates are the same as 2.44's (`HAVE_REMAP_JIT` / `ENABLE_SEPARATED_WX_HEAP`
Cocoa-only, `HAVE_MACH_EXCEPTIONS` excludes GTK, `HAVE_IOS_JIT_RESTRICTIONS` IOS_FAMILY-only).
The good news: Bun's 0002 keys everything on `OS(IOS_FAMILY)`, not on a port, and **dry-runs clean
against the patched 2.54 tree** (offsets only). So the realistic JIT build is Bun 0002 + `ENABLE_JIT`
+ `ENABLE_DFG_JIT` ON, `ENABLE_FTL_JIT`/WebAssembly OFF (Bun's device-proven tier set; FTL drags in
B3 and the whole wasm chain), `ENABLE_C_LOOP` OFF. Risks: first non-C-loop build of this tree
(offlineasm ARM64 Mach-O output under clang-19), whether the web process under the app case needs
`dynamic-codesigning` (Bun runs bare-fakesigned as a CLI), and Bun's lesson that DFG + concurrent
JIT races only show on real workloads. Suggested as a separate `+ios4` after `+ios3` passes on
device, in its own work dir so the C-loop tree stays resumable.
