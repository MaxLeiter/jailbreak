# Ladybird on iOS — feasibility & phased build plan

Status: **★ M0 DONE 2026-07-03 — Ladybird RENDERS REAL WEB PAGES on the A10 iPad** (example.com + styled data: page, correct fonts/colors/layout; PNGs in `artifacts/device-runs/ladybird-m0-pixels/`; debs `ladybird-headless_0.1.1+ios1` + `libmimalloc_2.2.7+ios1`). Paint fix = in-process CPU raster of the screenshot display list (patches 16-17); Compositor is CPU-capable not GPU-required. Next = build the UIKit `.app` frontend (code-complete). Companion to [`../SCOPE.md`](../SCOPE.md)

> **Update 2026-07-02/03 — M0 mostly BUILT.** Full leaf closure (Skia + ICU 78.3 + ~19 leaves,
> Waves 1-3) built + staged on `procursus-vol-ladybird`. Ladybird itself then **configured 100%
> clean with NO vcpkg** (all `find_package`/`pkg_check_modules` resolve against the staged
> `/var/jb` closure) and **cross-compiled clean for arm64**: 28 Lagom libs + Skia + 336 TUs across
> AK/LibCore/LibJS/LibGfx/LibMedia/LibIPC/LibCrypto/LibWasm/… — which **fully closes open-question
> #1** (C++23 compiles clean vs the 16.5-SDK libc++ across the whole engine, no cross-headers).
> **2 of 4 helper binaries linked** (`ImageDecoder`, `RequestServer`, arm64 NOUNDEFS). Integration
> artifacts: `linux-build/recipes-ladybird/ios-toolchain.cmake` (system-name Darwin + `IOS=TRUE`,
> clang-19, cctools ld64, `/var/jb` find-root, `-liosexec`, fake xcrun/sw_vers),
> `ladybird-m0-patches.sh` (idempotent source patch series), `build-ladybird-wave4.sh`.
> **Four corrections to this plan:**
> 1. **Rust is a HARD build requirement** (not previously noted): 8 workspace crates
>    (libjs/libweb/libgfx/libunicode/liburl/libregex/libtextcodec/libweb_content_blocker `_rust`)
>    cross-compile to `aarch64-apple-ios` via rustup + cbindgen. Add rust to the toolchain image.
> 2. **The feared host-tools cross-split mostly evaporated** — modern Ladybird codegen is all
>    Python (runs cross). It reduces to exactly **two** LibJS-AsmInterpreter build-time tools
>    (`gen_asm_offsets` C++/AK, `asmintgen` Rust) that need a native-then-cross host build — the
>    one remaining wall (Wave 4b). Everything downstream is proven to compile.
> 3. **`check_for_dependencies.cmake` REQUIRES SDL3, ANGLE, libjxl, libavif, libedit at configure**
>    — the deps-plan's M2 deferral of jxl/avif is wrong *for configure*. Handled via stub/headers-
>    only `.pc` + source gates for M0 (real codecs are still M2).
> 4. **Two dep-recipe fixes:** libpng needs the **APNG patch** (`png_get_acTL`), libwebp needs
>    **`-DWEBP_BUILD_LIBWEBPMUX=ON`** — both rebuilt (`recipes-ladybird/{libpng16,libwebp}.mk`).
> Other build facts: `-DENABLE_CRANELIFT_JIT=OFF` (Wasm interpreter, `memfd_create` is Linux-only
> and JIT is forbidden on iOS anyway); off-Mac CMake targets `CMAKE_SYSTEM_NAME=Darwin` + faked
> `xcrun`/`sw_vers` + forced `IOS=TRUE` (house qtbase pattern); the compiler wrapper appends
> `-Wno-error` after `"$@"` (clang-19 stricter than upstream).

> **Update 2026-07-02 — wall #1 struck.** clang-19 (from apt.llvm.org, added as a cacheable
> layer in `linux-build/Dockerfile`, committed) + the **stock iPhoneOS 16.5 SDK libc++**
> compiles Ladybird's C++23 core cross to `arm64-apple-ios16.0`: **47/49 AK + core-LibCore TUs
> pass `-fsyntax-only`** (the 2 fails were the probe's own stale dep headers, not compiler/libc++
> gaps). Zero language-level C++23 errors, zero libc++ library-feature errors. The old SDK libc++
> is missing `<expected>`/`<print>`/`<source_location>`/`<generator>`/`<stacktrace>` and ships
> `<format>` incomplete, but AK/LibCore touch none of them (own `ErrorOr`/`String`/`Format`), so
> **no libc++ cross-headers are needed for the foundation** — open-question #1 resolves in our
> favor for this layer. `-D__IOS__` gates the macOS bundle path off and sets `AK_OS_IOS` as
> predicted. **Residual:** only AK/LibCore was probed; spot-check a few **LibJS/LibWeb** TUs
> against the 16.5 libc++ before declaring the whole engine cross-header-free (folded into the
> first real M0 partial-build). Build-integration notes: AK needs `Debug.h`/`Backtrace.h`
> configured from their `.in`, and each Lagom lib emits a generated `Export.h` — both are normal
> CMake, just don't let the recipe fight them.
>
> **Update 2026-07-02 — ICU 78.3 built + Ladybird build volume created.** ICU 78.3 EXACT is done
> (three `+ios1` debs in `out/`, `.pc` = 78.3, Unicode 17.0 — see HAVE/NEED table). The Ladybird
> track has its own Procursus build volume **`procursus-vol-ladybird`** (cloned from
> `procursus-vol-gtk`) so the live GNOME/EDS 74.2 stack in other volumes is never clobbered. ICU
> recipe/control edits are staged uncommitted under `linux-build/`.
and the desktop-apps track. Scope: can we cross-compile the Ladybird browser
(`LadybirdBrowser/ladybird`) to native `iphoneos-arm64` and render a real web page on the
jailbroken iPad (A10, iPadOS 17.6.1, palera1n rootless `/var/jb`), and what is the cheapest
path to first pixels?

Recon was done against a fresh `main` clone (2026-07-02). Line references are to that tree.

---

## TL;DR verdict

**Feasible, and less exotic than it looks.** Ladybird is a from-scratch C++ engine whose
non-UI core (AK, LibCore, LibJS, LibWeb, LibGfx) is already **Darwin-clean and carries a real
iOS branch**: `AK/Platform.h` defines `AK_OS_IOS` (+ `AK_OS_BSD_GENERIC`), the event loop is a
plain **`poll(2)` Unix implementation** (not CFRunLoop, so it runs headless), process spawning
is **`posix_spawn`** on the non-Linux path (works under this JB, same as bun/opencode), and
helper-binary path resolution uses `_NSGetExecutablePath` + a Linux-style `libexec/bin` prefix
search that is **compiled in for iOS** (the macOS bundle path is gated behind `AK_OS_MACOS`,
which iOS does not set). Two more levers land in our favor:

1. **LibJS is a bytecode interpreter — no JIT.** Ladybird removed its JS JIT. There is **no
   W^X / `MAP_JIT` / dynamic-codegen wall** (the thing that cost us weeks on bun/mozjs). This
   is the single biggest de-risker.
2. **`BUILD_SHARED_LIBS OFF` governs only Ladybird's own Lagom libs** (`if (ANDROID OR IOS)` in
   the top `CMakeLists.txt`) — *corrected 2026-07-02*: the third-party leaf closure is NOT forced
   static, so the leaves ship as **normal dylib debs** (like ICU), and "one deb" is a later
   optimization, not an M0 constraint. We still let the build own matched-version deps to avoid
   version-mismatch hell. See [`ladybird-deps-plan.md`](ladybird-deps-plan.md).

The three real walls are all **build-time, not runtime**: (1) the toolchain — Ladybird needs
**clang ≥ 19** (CI uses clang-21 / gcc-14) and C++23, while the Docker image's Debian-bookworm
default clang is ~14; (2) **Skia** (vcpkg pin `144`, GN build system) and **ICU 78.3 EXACT**
(we have 74.2); (3) **no iOS branch in `vcpkg.json`** — the manifest's platform guards know
`osx/linux/windows/android/bsd` but not `ios`, so a stock `ios` triplet resolves Skia/ANGLE/
HarfBuzz to *nothing*. All three are tractable with known moves.

**Recommendation:** target the **headless renderer first** (`HeadlessWebView`, already in-tree,
renders a page to a CPU bitmap via Skia raster with the full multiprocess engine and *no* GUI
toolkit). That is the shortest path to "a real page rendered on-device" and it sidesteps Qt,
AppKit, Metal, GPU entitlements, and Wayland all at once. Promote to a live window only after
the engine is proven.

---

## Dependency inventory (from `vcpkg.json`)

Required C++ standard: **C++23** (`CMAKE_CXX_STANDARD 23`, `_REQUIRED ON`). Minimum compilers
(`Meta/Utils/find_compiler.py`): **clang 19**, **gcc 14**, Xcode 16.3. `nasm` required.

Every third-party dep is **vcpkg-managed** (pinned in `overrides`); there are no "system"
deps except the toolchain libc++/frameworks. Full pinned set:

| Dep | Pin | Notes |
|---|---|---|
| skia | 144 | GN build; osx=metal, others=raster/vulkan. **Big.** |
| angle | chromium_7258 | osx=metal feature; GLES→Metal (we already ship `angle`). |
| icu | **78.3 EXACT** | `find_package(ICU 78.3 EXACT REQUIRED)` — hard pin. |
| harfbuzz | 10.2.0 | osx=coretext+icu; else freetype+icu. |
| freetype | 2.13.3 | |
| fontconfig | 2.17.1 | linux/bsd/osx (not gated off for iOS — see wall #3). |
| curl | 8.20.0 | brotli, http2, **http3**, openssl, websockets, zstd → pulls nghttp2/nghttp3. |
| openssl | 3.5.3 | |
| ffmpeg | 7.1.1 | avcodec/avformat/swresample + dav1d/openh264/opus/webp/theora/vorbis/vpx. |
| libjxl | 0.11.1 | + highway 1.4.0. |
| libavif | 1.3.0 | + dav1d 1.5.1. |
| libwebp | 1.6.0 | anim, mux, simd. |
| libpng | 1.6.50 | apng. |
| libjpeg-turbo | 3.1.1 | |
| tiff | 4.7.1 | zstd. |
| woff2 | 1.0.2 | + brotli. |
| wuffs | 0.3.4 | header-only image codecs. |
| libxml2 | 2.13.8 | |
| sqlite3 | 3.52.0 | |
| zlib | 1.3.1 | |
| simdutf | 7.4.0 | small, SIMD. |
| simdjson | 4.2.4 | small, SIMD. |
| fmt | 12.1.0 | |
| fast-float | 8.1.0 | header-ish. |
| libtommath | 1.3.0 | bignum for LibCrypto. |
| mimalloc | 2.2.7 | allocator. |
| libpsl | 0.21.5 | (we already ship 0.21.5). |
| libedit | 2024-08-08 | REPL line editing; non-win/android. |
| sdl3 | 3.2.28 | **Gamepad API only** (`LibWeb/Gamepad`) — candidate to stub/disable for M0. |
| libproxy | 0.4.18 | `!(android\|bsd)` — skippable. |
| cpptrace / libdwarf | 1.0.2 / 2.3.0 | backtraces on linux/win/osx — optional. |
| dbus | 1.16.2 | **linux/freebsd only — N/A on iOS.** |
| vulkan(-headers) | — | **linux/bsd/android only — N/A on iOS.** |
| wayland(-protocols) | 1.24 / 1.44 | **GTK feature on linux only — N/A** (we have these anyway). |
| pthread / mman / dirent | — | **windows only — N/A.** |
| qtbase | 6.10.0 | Qt feature; windows/freebsd variants only (macOS uses AppKit). |
| libadwaita / gtk | 1.8.4 / 4.22.0 | GTK feature (linux/osx). |

---

## HAVE vs NEED

Because iOS is a **static** build, "HAVE deb" mostly does not help at link time (the build
wants matching-version *sources/headers* under its own prefix, and reusing our shared libs
fights `BUILD_SHARED_LIBS OFF`). The table below is therefore about **build-time provisioning**,
and the honest recommendation is *let the Ladybird build own its whole dependency closure*
(via vcpkg or per-dep recipes) rather than splice in our debs, except where the version already
matches.

| Dep | Status | Detail |
|---|---|---|
| libpsl 0.21.5 | **HAVE (exact)** | `libpsl5_0.21.5` — version matches the pin. |
| angle | **HAVE (adapt)** | `angle` deb = google/angle GLES→Metal, `/var/jb/lib/angle`. Pin is `chromium_7258`; API close enough for a GPU path later. Raster M0 does not need it. |
| libpulse 17.0 | **HAVE (runtime)** | audio.cmake routes iOS to the **PULSE** backend (not AudioUnit, which is `APPLE AND NOT IOS`). Our pulseaudio bridge already works. |
| icu | **DONE (2026-07-02)** | Built 78.3 via bumped `recipes/icu4c.mk` native-then-cross. `libicu78_78.3+ios1`, `libicu-dev_78.3+ios1`, `icu-devtools_78.3+ios1` in `out/`; all component `.pc` read `78.3` (EXACT passes), arm64 Mach-O NOUNDEFS, Unicode 17.0. Deltas: dotted release tag/tarball naming (`icu4c-78.3-sources.tgz`), pkg rename `libicu74`→`libicu78`. Clone-hygiene wall: `build_base` is not version-guarded, so a stale 74.2 `libicudata` shadowed the 78.3 stub (`_icudt78_dat` undefined) until wiped — do this before any future ICU bump on a reused volume. |
| harfbuzz | **REBUILD** | HAVE 2.8.1 (way too old); NEED 10.2.0. |
| freetype/fontconfig/libpng/zlib/sqlite3/libxml2/libjpeg-turbo/libwebp | **REBUILD or vcpkg** | Procursus/our debs exist but versions lag the pins; static build wants the pinned source. |
| curl + openssl + nghttp2/nghttp3 | **NEED** | http3 closure; our base curl lacks it. |
| ffmpeg 7.1.1 | **NEED — M0-CONFIGURE-REQUIRED** | *Corrected 2026-07-02*: NOT deferrable. `check_for_dependencies.cmake` does an unconditional `pkg_check_modules(AVCODEC/AVFORMAT/... REQUIRED)`, so Ladybird configure FAILS without an ffmpeg 7.1.x present, even though playback is M2. HAVE libav* 5.1.2 (ffmpeg 5 API) — no reuse. Build a **minimal ffmpeg 7.1.1** (reduced codec set) to satisfy configure. |
| skia 144 | **DONE (2026-07-02)** | Built raster-only (m144, `skia_enable_ganesh=true` + all GPU backends off). `libskia.a` 12M arm64 + `libskcms.a` staged at `out/skia-ios-arm64/` (lib + 1718 headers + `skia.pc`), reproducible via `build-skia.sh`. **nm confirmed `SkSurfaces::RenderTarget`/`GrDirectContext` present+DEFINED — no Ladybird ifdef patch needed.** Framework closure (from undefined-symbol survey): CoreFoundation/CoreGraphics/CoreText/ImageIO/libobjc, no Metal. Built in derived image `procursus-xbuild:skia` (base+clang-19+nasm), source in volume `skia-ios-vol`. |
| simdutf / simdjson / fmt / fast-float / libtommath / mimalloc / woff2 / wuffs / libtiff / libjxl(+highway) / libavif(+dav1d) | **NEED (small–med)** | Mostly clean CMake/meson cross builds; several are header-heavy and trivial. |
| sdl3 | **NEED or STUB** | Only used by the Gamepad API. For M0, patch it out or ship a stub. |
| libedit / cpptrace / libdwarf / libproxy | **NEED or SKIP** | REPL/backtrace/proxy niceties; all optional for a headless first light. |
| dbus / vulkan / wayland / qtbase / gtk / pthread / mman | **N/A (iOS)** | Gated off for iOS by platform, or belong to a frontend we are not building at M0. |

### Skia (the one genuinely hard dep)

Skia's build is **GN + ninja**, not CMake, and vcpkg's Skia port drives GN under the hood.
Two facts make it tractable:

- **Skia officially supports an iOS target** in GN (`target_os="ios"`, `target_cpu="arm64"`).
  We are not blazing a trail.
- **A software-raster Skia sidesteps all GPU/GN-graphics complexity.** Ladybird's
  `LibGfx/PaintingSurface.cpp` has a CPU path: when constructed with a **null**
  `SkiaBackendContext`, `create_with_size()` calls `SkSurfaces::WrapPixels(...)` into a plain
  CPU bitmap (lines ~98–124). The Metal path (`WrapBackendRenderTarget` + `GrBackendRenderTargets::MakeMtl`)
  is only taken when a Metal context is supplied.

  **Corrected config (see [`ladybird-skia-recipe.md`](ladybird-skia-recipe.md), authoritative).**
  `skia_enable_gpu=false` is stale nomenclature and, taken literally, **breaks the link**: m144 has
  no such arg, and Ladybird references `GrDirectContext` / `SkSurfaces::RenderTarget`
  *unconditionally* at link (`SkiaBackendContext.{h,cpp}`, `PaintingSurface.cpp:105`), guarded only
  by a runtime null-check. The correct raster build is **`skia_enable_ganesh=true` with every GPU
  backend off** (`skia_use_gl/metal/vulkan/dawn=false`): Ganesh core symbols stay linkable, zero GPU
  TUs compile, runtime falls to `WrapPixels`. Also force `skia_use_freetype=true` (iOS defaults to
  CoreText); build the `:skia` target only, not `:modules`. Pin = chrome milestone **m144**, commit
  `ee20d565acb08dece4a32e3f209cdd41119015ca`. xcrun-bypass: set `xcode_sysroot="<16.5 SDK>"` so the
  guarded xcrun call in `gn/skia/BUILD.gn:24` is skipped. Archiver gotcha: iOS uses `libtool -static`
  (not `ar`), so PATH-shim cctools `aarch64-apple-darwin-libtool` as `libtool`. Bundle all deps
  (`skia_use_system_*=false`) to dissolve version skew.

**BUILT + VERIFIED 2026-07-02** — see [`ladybird-skia-recipe.md`](ladybird-skia-recipe.md) and the
HAVE/NEED row. gn gen clean, full build exit 0, `SkSurfaces::RenderTarget`/`GrDirectContext`
present+defined (bet held, no source patch), framework closure = CF/CG/CoreText/ImageIO/libobjc
(no Metal). Staged at `out/skia-ios-arm64/`. Operational deltas folded into `build-skia.sh`:
`git-sync-deps` retry loop, arm64e-fat→arm64 thinning, public-header `#include "include/..."`
rewrite on staging.

Recommended Skia approach: a **standalone GN cross-build** to `ios/arm64`, raster-only, staged
into the build prefix as a static lib + pkg-config `.pc` (Ladybird's `check_for_dependencies.cmake`
will accept `PkgConfig::skia` when the CONFIG package is absent). Add Metal (`skia_use_metal=true`)
in a later phase to unlock GPU painting + zero-copy IOSurface present (mirrors the ANGLE track).

---

## Toolchain remediation (wall #1)

**Problem.** `aarch64-apple-darwin-clang` in `linux-build/Dockerfile` is a cctools-port wrapper
around Debian bookworm's clang (**~14**). Ladybird demands **clang ≥ 19** for C++23; anything
older fails `find_compiler.py` and will not compile the codebase.

**Fix (cheap, known-good).** Install a modern clang from **apt.llvm.org** into the image
(`clang-19` or `clang-20`; the LLVM 21-on-macOS libc++ linker bug in `find_compiler.py` is a
*host-clang* caveat, not ours — we cross-compile, so pick 19/20 to be safe). Keep the existing
**cctools-port `ld64`** as the linker and the staged **iPhoneOS16.5.sdk** as the sysroot; only
the *compiler front end* changes. Point CMake at it with
`-DCMAKE_C_COMPILER=clang-19 -DCMAKE_CXX_COMPILER=clang++-19` plus the `--target=arm64-apple-ios16.0`
+ `-isysroot <sdk>` flags the cross wrapper already injects. Ladybird's `Meta/CMake/use_linker.cmake`
must be steered to ld64 (not lld/mold) via `-DLINKER=<default>` / letting the Apple path win.

**libc++ / ABI.** We compile with clang-19 but link against the **iPhoneOS 16.5 SDK libc++**
(Xcode 14.3-era, ~LLVM 16 headers). Language-level C++23 is fine; the risk is **C++23 library**
features. Ladybird mitigates this by using its own vocabulary types (`AK::Error`/`ErrorOr`,
`AK::String`, its own `format`) rather than `std::expected`/`std::print`, so the SDK libc++ is
*probably* sufficient. **Verify** by compiling AK + LibCore first; if a library gap bites,
supply clang-19's own `libc++` headers/static lib cross-targeted to iOS (the newer libc++
headers compile clean against the older runtime for the features Ladybird touches). Do **not**
mix a newer libc++ *dylib* into `/var/jb` — static-link libc++ into the binaries to avoid ABI
skew with the rest of the desktop stack.

**vcpkg manifest (wall #3).** `vcpkg.json`'s platform expressions have **no `ios` branch**, so
an `ios` triplet drops Skia, ANGLE, HarfBuzz, fontconfig-variants, etc. entirely. Either (a)
**patch `vcpkg.json`** to fold `ios` in beside `osx` for the graphics deps (skia raster/metal,
harfbuzz coretext-or-freetype, angle), or (b) **skip vcpkg** and drive per-dep Procursus-style
recipes (`recipes/*.mk`) as we do for every other stack — more recipes, but it is the house
mechanism and gives us the version control (ICU 78.3, ffmpeg-lite) we need anyway. See the
build-integration choice below.

---

## Build integration: vcpkg-in-container vs Procursus recipes

> **DECIDED 2026-07-02 → Option B (full Procursus recipes, no vcpkg).** ICU 78.3 and Skia both
> built cleanly against our cctools+clang-19 cross toolchain as recipes/drivers, proving the house
> mechanism handles the hardest deps; vcpkg-on-iOS with a non-Apple Linux host toolchain is
> unproven and would leave a foreign tree to hand-repackage. So the entire leaf closure is one
> pipeline on `procursus-vol-ladybird`. Per-dep action list + M0 build order live in
> [`ladybird-deps-plan.md`](ladybird-deps-plan.md): **19 M0 leaves = 11 bump, 8 new** (5 near-trivial
> header-only), ICU done. Source-side M0 patches pinned there too: sandbox `elseif (APPLE AND NOT
> IOS)` in `Services/WebContent/CMakeLists.txt`; SDL3/ffmpeg `find_package` gates in
> `Meta/CMake/check_for_dependencies.cmake`.

Two viable strategies; recommend **starting with a hybrid** and hardening toward recipes.

- **Option A — patch `vcpkg.json` + custom `ios-arm64` triplet.** Add an iOS platform branch,
  write a vcpkg triplet that uses our cctools+clang-19 toolchain (`VCPKG_CMAKE_SYSTEM_NAME iOS`,
  `VCPKG_TARGET_ARCHITECTURE arm64`, static, our toolchain file), and let vcpkg resolve the
  whole closure. **Pro:** Ladybird's own ports already know how to build Skia/ffmpeg/etc.;
  minimal recipe writing. **Con:** vcpkg-on-iOS with a non-Apple host toolchain is unproven;
  some ports (skia GN, ffmpeg) may need per-port patches; output is a vcpkg install tree we then
  hand-package into a deb (foreign to our pipeline).
- **Option B — Procursus recipes per dep.** ~20 `.mk` files (many trivial; ICU/harfbuzz/ffmpeg
  we partly have). **Pro:** house mechanism, versions under our control, integrates with
  `xmkdeb`/signing. **Con:** ~20 recipes and Skia's GN doesn't fit the Procursus autotools/meson
  mold (needs a bespoke recipe shelling out to GN+ninja).

**Recommended:** Option A for the **leaf deps** (fast, low-touch) but a **hand-rolled GN recipe
for Skia** and our **existing ICU recipe bumped to 78.3** regardless of route (the EXACT pin and
the GN special-case are worth owning). Package the final Ladybird tree as **one deb**:
`/var/jb/bin/ladybird` (+ headless), helpers in `/var/jb/libexec/ladybird/`, resources in
`/var/jb/share/Lagom` (matches the compiled-in non-macOS prefix search).

---

## iOS-specific work vs free-from-macOS

**Free (already Darwin/BSD-generic, no porting):**
- **AK, LibCore, LibJS, LibWeb, LibGfx core, LibIPC** — all compile under `AK_OS_IOS` /
  `AK_OS_BSD_GENERIC`.
- **Event loop** — `EventLoopImplementationUnix` is `poll(2)`-based (`System::poll`, line ~399);
  no CFRunLoop, runs headless. macOS uses the *same* Unix loop, so it is battle-tested off-GUI.
- **Process model** — `Core::Process::spawn` uses `posix_spawn`/`posix_spawnp` on the non-Linux
  branch (Process.cpp ~198–231). Helper binaries (`WebContent`, `RequestServer`, `ImageDecoder`,
  `WebWorker`, `Compositor`) are located by `get_paths_for_helper_process` via
  `_NSGetExecutablePath` → dirname → `$prefix/libexec` + `$prefix/bin` candidates
  (Utilities.cpp ~101). **No hardcoded `/usr` paths**; the Linux-style `libexec` branch is
  compiled in for iOS (it is gated `!AK_OS_MACOS`). Under this JB, `posix_spawn` of ldid-signed
  binaries from `/var/jb` is proven (bun/opencode).
- **No JIT** — LibJS is an interpreter. No `MAP_JIT`, no codegen entitlement, no W^X dance.
- **Audio** — `audio.cmake` sends iOS to the **PULSE** backend; our pulseaudio stack serves it.

**Genuinely iOS-specific work:**
- **No iOS frontend exists.** `UI/` has Android, AppKit, Gtk, Qt — no iOS. AppKit is
  `NSApplication`/Cocoa (macOS only), unusable on UIKit. First light must be **headless**;
  a real window comes later (UIKit view, or a thin Wayland/SDL3 client under `iosc`).
- **No iOS build path in the harness.** `Meta/CMake/presets/` has no iOS preset and
  `host_platform.py` has no iOS host; `IOS`/`__IOS__` are honored in source but nothing *drives*
  an iOS configure. We supply the toolchain file, `-DIOS=ON`-equivalent (`CMAKE_SYSTEM_NAME iOS`),
  and a preset ourselves.
- **Sandbox.** `Services/*/SandboxMacOS.cpp` and `UI/.../RendererSandboxMacOS.cpp` use the macOS
  Seatbelt (`sandbox_init`) API, which is unavailable/blocked to fakesigned iOS processes. Route
  iOS to the **`*Unimplemented.cpp`** variants (or run `--disable-sandbox`, an existing flag).
  Losing the sandbox is acceptable for a jailbroken proof; note it as a security caveat.
- **Entitlements per helper.** Each spawned binary must be ldid-signed with the `/var/jb`
  path-exception (like every app here). GPU/Metal entitlements are needed **only if** we build
  Skia-on-Metal or the ANGLE present path; the raster M0 needs none of that.
- **`__IOS__` define.** `AK/Platform.h` keys iOS off `__IOS__` (non-standard; clang normally
  exposes `TARGET_OS_IPHONE` via `TargetConditionals.h`). We must inject `-D__IOS__` (or patch
  Platform.h to test `TARGET_OS_IPHONE`) in the cross flags.

---

## Frontend + rendering path

**Recommendation: headless-first, raster-first.** Concretely:

- **M0 rendering:** **Skia CPU raster** (`SkSurfaces::WrapPixels` into an `AK::Bitmap`), driven
  by the in-tree **`HeadlessWebView`** (`Libraries/LibWebView/HeadlessWebView.{h,cpp}`). This
  exercises the *entire* real engine — WebContent/RequestServer/ImageDecoder multiprocess, full
  LibWeb layout + paint — and emits a PNG. No GUI toolkit, no Metal, no GPU entitlement, no
  Wayland. It is the maximum-signal / minimum-surface first light.
- **M1 live window:** present the headless bitmap through the **existing `iosc` Wayland +
  IOSurface path** — a thin `wl_shm` (or SDL3) client that blits WebContent's backing bitmap,
  reusing the Xios/Metal present pipeline exactly as the other desktop apps do. This gets an
  interactive window with the least new code and no Qt-version risk.
- **Qt frontend (option, deferred):** Ladybird's Qt UI would reuse our built Qt6 + qtwayland as
  a client under `iosc`. **But** the pin is **qtbase 6.10.0** and we have **6.6.3** (the Qt UI
  and its new `Compositor` service lean on platform GPU-buffer handles), so this is a bigger
  version-chase than M1's shm blit. Treat Qt as the "polished desktop" phase, after the engine
  is proven and if a Qt 6.10 rebuild is justified.
- **Skia-on-Metal + zero-copy IOSurface (option, deferred):** rebuild Skia with
  `skia_use_metal=true`, feed it a Metal context, and let `PaintingSurface`'s
  `GrBackendRenderTargets::MakeMtl` path render into an IOSurface-backed `MTLTexture` — the same
  zero-copy win the ANGLE track already proved. Needs the Xios GPU entitlement set. This is the
  performance endgame, not the first milestone.
- **Native UIKit frontend (option, latest):** a proper `UIView`/`CAMetalLayer` shell with touch
  → input events. Most work; do last, once the window path and input semantics are understood.

---

## Phased plan

| Phase | Goal | Work | Effort | Risk |
|---|---|---|---|---|
| **M0** | **Headless renders a real page to PNG on-device.** | clang-19 in image; toolchain file + iOS preset; `-D__IOS__`; build dep closure (raster Skia, ICU 78.3, harfbuzz 10, simdutf/simdjson/fmt/woff2/wuffs/libtommath/mimalloc + image/xml/sqlite/curl+ssl); route Sandbox→Unimplemented, `--disable-sandbox`; disable/stub SDL3-gamepad + ffmpeg video; package one deb (bin + libexec helpers + share/Lagom); ldid-sign every helper. Validate `Ladybird`-headless emitting a PNG of a known page. | **High** (the bulk of the project) | **Med.** Walls are the toolchain, Skia GN, ICU EXACT — all known-shape. No JIT/entitlement wall. |
| **M1** | **Interactive window.** | Thin `wl_shm`/SDL3 client presenting WebContent's bitmap via `iosc`→IOSurface→Xios; wire UIKit touch/keyboard → input events. | Med | Low–Med. Reuses proven present pipeline. |
| **M2** | **Media + polish.** | Full ffmpeg 7.1.1 (dav1d/opus/vpx…), libjxl/libavif/tiff codecs, libedit REPL, cpptrace backtraces; audio through PULSE bridge. | Med | Low. Additive. |
| **M3** | **GPU painting.** | Skia-on-Metal (`skia_use_metal=true`) + zero-copy IOSurface present; Xios GPU entitlement set on the WebContent helper. | Med–High | Med. GPU entitlements + Metal context lifetime. |
| **M4** | **Native/Qt frontend.** | Either UIKit shell or a Qt 6.10 rebuild + Qt UI as `iosc` client; site-isolation/spare-process tuning. | High | Med. Qt version chase or new UIKit code. |

---

## Open questions / verify on-device

1. **libc++ C++23 gap.** ~~Does the iPhoneOS 16.5 SDK libc++ satisfy every C++23 *library* use in
   AK/LibWeb, or must we cross clang-19's libc++ headers? Settle by compiling AK+LibCore first.~~
   **RESOLVED for AK/LibCore (clean, 2026-07-02) — no cross-headers needed.** Remaining: spot-check
   a few LibJS/LibWeb TUs (larger, likelier to hit `<ranges>`/`<format>` edges) in the first M0
   partial-build.
2. **Skia iOS GN raster build.** Confirm `target_os="ios"` + raster-only links clean against our
   cctools ld64 and the 16.5 SDK; check Skia's own freetype/harfbuzz/icu wiring vs our staged
   copies (version skew inside Skia).
3. **Multiprocess spawn under sandbox exception.** Confirm a WebContent helper posix_spawn'd from
   `/var/jb/libexec` inherits the path-exception + runs; confirm many-WebContent site isolation
   is stable on the A10 (memory).
4. **IPC transport.** Ladybird LibIPC uses `AF_UNIX` socketpair fd-passing between UI and
   helpers — confirm `SCM_RIGHTS` fd passing behaves under the JB sandbox (it does for our other
   sockets, but the multiprocess handshake is new surface).
5. **ICU 78.3 EXACT vs our 74.2.** The `EXACT` pin means nothing older links; confirm the
   `icu4c.mk` native-then-cross recipe bumps cleanly to 78.3 (data blob size, `--with-cross-build`).
6. **`__IOS__` vs `TARGET_OS_IPHONE`.** Decide inject-define vs a one-line `AK/Platform.h` patch;
   check nothing else keys off a macOS-only conditional that iOS should share (audio already
   handled; sandbox handled).
7. **curl http3 closure.** nghttp3/ngtcp2/quictls on iOS — is http3 worth the extra libs for a
   first browser, or ship http2-only to shrink M0?
8. **SDL3 removal.** Cleanest way to drop the Gamepad dep for M0 without patching LibWeb broadly
   (build-flag vs stub `SDLGamepadForward.h`).
9. **Memory ceiling.** WebContent + Skia raster on a 3 GB A10 with the desktop running — measure;
   may force fewer spare processes / site-isolation off.

---

## One-line summary

A no-JIT, Darwin-clean, statically-linked engine with an in-tree headless renderer — the port
is real work (a modern clang, a raster Skia, ICU 78.3, and a one-deb package) but has **no
class of blocker we have not already beaten elsewhere in this project**, and the headless-raster
M0 reaches a real rendered page without touching Qt, Metal, GPU entitlements, or Wayland.
