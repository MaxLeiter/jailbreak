# Skia cross-build recipe for Ladybird-on-iOS (wall #2)

Status: **design + argument-set validation. No Skia compile run.** Companion to
[`ladybird-plan.md`](ladybird-plan.md) (this is the "Skia (the one genuinely hard dep)" section,
worked out to a concrete recipe). Target: `iphoneos-arm64`, rootless `/var/jb`, A10 / iPadOS
17.6.1. Toolchain: cctools-port `ld64` + `libtool` + a bare upstream `clang-19`/`clang++-19`
(from apt.llvm.org, already in the image) + the staged `iPhoneOS16.5.sdk`, deployment target
`arm64-apple-ios16.0`.

All line references below are to `google/skia` at the pinned revision and to a fresh Ladybird
`main` clone (2026-07-02).

---

## 1. The exact Skia revision for pin 144

Ladybird's `vcpkg.json` pins `{"name": "skia", "version": "144#0"}` against builtin baseline
`81de6771512413aaf89ea77add5ad1fda126b9d0`. Resolving that:

- vcpkg `versions/s-/skia.json` version **144** -> port git-tree
  `49644bbec29e7c5301d670487212d30505306b93`.
- That port's `portfile.cmake` pins upstream:

  ```
  REPO google/skia
  REF  ee20d565acb08dece4a32e3f209cdd41119015ca
  ```

**Use `google/skia` commit `ee20d565acb08dece4a32e3f209cdd41119015ca`.** This is the
**`chrome/m144`** milestone point (the port's patch notes reference `chrome/m143` release notes;
the pin is one milestone past). "Skia 144" == Chrome milestone 144, not an `m144` tag we fetch by
name. Pin by commit, not branch.

Skia's internal graphics deps at this revision (for reference, from
`gn/skia.gni` / `gn/BUILDCONFIG.gn`): C++17 core, GN + ninja, `skia_enable_ganesh` default true.

---

## 2. `gn gen` argument set + the xcrun bypass (the crux)

### 2a. The xcrun problem and the one-line bypass

Skia's GN normally shells out to `xcrun`/`xcodebuild`, which do not exist in the Debian
container. There is exactly **one** such call on the static-lib path, and it is guarded so we can
skip it. In `gn/skia/BUILD.gn`:

```
declare_args() {
  ...
  xcode_sysroot = ""            # line 21
}

if (is_ios && xcode_sysroot == "") {          # line 24
  ...
  sdk = "iphoneos"
  xcode_sysroot = exec_script("../find_xcode_sysroot.py", [ sdk ], "trim string")
}
```

and `gn/find_xcode_sysroot.py` is nothing but `xcrun --sdk <sdk> --show-sdk-path`.

**Bypass: set `xcode_sysroot` in the gn args to the staged SDK path.** The `== ""` guard then
short-circuits and `find_xcode_sysroot.py` (the only `xcrun` invocation reachable when building
`:skia`) is never executed. Skia then injects `-isysroot $xcode_sysroot`, `-arch arm64`, and
`-miphoneos-version-min=$ios_min_target` into cflags/asmflags/ldflags itself (BUILD.gn lines
211-238). No other part of the `:skia` graph reaches `xcrun`: the only remaining `xcrun`/codesign
consumers (`gn/codesign_ios.py`, `ios_app_bundle`, `compile_ib_files`) are app-bundle templates
we never instantiate, gated behind `skia_ios_use_signing`.

Two more toolchain facts from `gn/BUILDCONFIG.gn` and `gn/toolchain/BUILD.gn`:

- **`cc`, `cxx`, `ar` are plain declare_args** (`gn/BUILDCONFIG.gn` lines 21-23, default
  `"ar"`/`"cc"`/`"c++"`). Setting `cc=`/`cxx=` is exactly how vcpkg's own portfile feeds a
  non-Apple compiler (`cc="${VCPKG_DETECTED_CMAKE_C_COMPILER}" ...`). We do the same.
- **The iOS archive step uses `libtool -static`, not `ar`** (`gn/toolchain/BUILD.gn` lines
  297-303: `if (is_mac || is_ios) { not_needed(["ar"]) ... command = "libtool -static -o
  {{output}} -no_warning_for_no_symbols {{inputs}}" }`). GN hardcodes the bare name `libtool`.
  The Debian image installs **GNU `libtool-bin`**, whose `libtool` is a totally different program
  and will choke on `-static -o ... -no_warning_for_no_symbols`. So the recipe **must put
  cctools' `libtool` first on PATH as `libtool`** (symlink `aarch64-apple-darwin-libtool` ->
  `libtool` in a shim dir prepended to PATH), or the archive step fails. This is the second,
  easily-missed integration point after the xcrun bypass.

### 2b. The compiler-triple wrapper

`cc="clang-19"` bare is a Linux-host clang; Skia adds `-arch arm64 -isysroot <sdk>
-miphoneos-version-min=16.0` but not an OS triple, so the default target stays
`aarch64-unknown-linux`. Mirror the house `cc-nounused` pattern with a thin wrapper that pins the
Darwin/iOS triple (the Dockerfile comment already prescribes driving clang-19 as
`clang-19 --target=arm64-apple-ios<v> -isysroot <sdk>`):

```sh
# build_tools/skia-cc
exec clang-19  --target=arm64-apple-ios16.0 "$@"
# build_tools/skia-cxx
exec clang++-19 --target=arm64-apple-ios16.0 "$@"
```

Pass those as `cc`/`cxx`. Skia's own `-arch arm64` / `-miphoneos-version-min` are then redundant
but harmless (they agree with the triple). `ar` is set to `aarch64-apple-darwin-ar` for form; it
is unused on the iOS path (libtool wins).

### 2c. The full `gn gen` args (raster-only ios/arm64, static)

```sh
gn gen out/ios-arm64 --args='
  target_os="ios"
  target_cpu="arm64"
  ios_min_target="16.0"
  xcode_sysroot="/root/cctools/SDK/iPhoneOS16.5.sdk"
  cc="/work/Procursus/build_tools/skia-cc"
  cxx="/work/Procursus/build_tools/skia-cxx"
  ar="aarch64-apple-darwin-ar"

  is_official_build=true
  is_component_build=false
  is_debug=false

  # Ganesh core stays ON, every GPU backend OFF (see section 4 for why ganesh must
  # stay compiled even for a CPU-raster M0).
  skia_enable_ganesh=true
  skia_use_gl=false
  skia_use_metal=false
  skia_use_vulkan=false
  skia_use_dawn=false
  skia_enable_graphite=false

  # Font raster: iOS defaults skia_use_freetype=false (CoreText). Ladybird feeds Skia
  # freetype-built typefaces on non-mac, so force freetype ON + custom fontmgrs.
  skia_use_freetype=true
  skia_use_system_freetype2=false
  skia_use_fontconfig=false
  skia_use_harfbuzz=true
  skia_use_system_harfbuzz=false
  skia_use_icu=true
  skia_use_system_icu=false

  # Bundled everything else (see section 3).
  skia_use_zlib=true
  skia_use_system_zlib=false
  skia_use_expat=true
  skia_use_system_expat=false
  skia_use_libpng_decode=true
  skia_use_libpng_encode=true
  skia_use_system_libpng=false
  skia_use_libjpeg_turbo_decode=true
  skia_use_libjpeg_turbo_encode=false
  skia_use_no_jpeg_encode=true
  skia_use_system_libjpeg_turbo=false
  skia_use_libwebp_decode=false
  skia_use_libwebp_encode=false
  skia_use_no_webp_encode=true
  skia_use_wuffs=true

  # Trim everything Ladybird does not consume.
  skia_enable_pdf=false
  skia_enable_svg=false
  skia_enable_skottie=false
  skia_enable_tools=false
  skia_enable_android_utils=false
  skia_enable_spirv_validation=false
  skia_enable_gpu_debug_layers=false
  skia_use_lua=false
  skia_use_dng_sdk=false
  skia_use_jpeg_gainmaps=false

  extra_cflags=["-DSKCMS_DLL"]
  extra_cflags_cc=["-DSKCMS_DLL","-USK_HIDE_PATH_EDIT_METHODS"]
'
```

Then build only what Ladybird links:

```sh
ninja -C out/ios-arm64 skia
```

Notes on the non-obvious flags:

- `is_official_build=true` + `is_component_build=false` -> optimized static libs. (Ladybird's own
  in-tree flatpak recipe uses `is_component_build=true` for a `.so`; iOS forces static, so we flip
  it. vcpkg's portfile makes the identical `is_component_build=false` choice for static linkage.)
- `-USK_HIDE_PATH_EDIT_METHODS` re-enables the `SkPath` edit methods Ladybird calls. Ladybird's
  flatpak recipe uses this exact cflag; vcpkg achieves the same with `skpath-enable-edit-methods.patch`.
- `-DSKCMS_DLL` must match the consumer: Ladybird's `check_for_dependencies.cmake` appends
  `SKCMS_DLL` to the skia imported target's compile defs, so skcms headers must be compiled with
  it here too.
- Do **not** build `:modules`. Ladybird references `skcms` (LibGfx/ColorSpace.cpp) but zero
  `SkShaper`/`SkParagraph`/`SkUnicode` (grep of `Libraries/` = 0 hits) - it shapes text with its
  own HarfBuzz and feeds Skia positioned glyphs. So `:skia` alone is the target; skipping
  `:modules` also means `skia_enable_svg`/`skia_enable_skottie` can stay off despite their
  `!is_component_build` default (they are separate targets, not pulled by `:skia`).

### 2d. `gn args --list` cross-check

Every arg above is a real `declare_args()` at m144: `xcode_sysroot`, `extra_cflags*`,
`extra_asmflags`, `ios_min_target` (`gn/BUILDCONFIG.gn:34`), `cc/cxx/ar` (`gn/BUILDCONFIG.gn:21-23`),
`skia_enable_ganesh` (`gn/skia.gni:93`), `skia_use_freetype` (`:53`), `skia_use_harfbuzz` (`:54`),
`skia_use_gl` (`:55`), `skia_use_icu` (`:56`), `skia_use_metal` (`:72`), `skia_use_vulkan` (`:119`),
`skia_enable_graphite` (`:94`). No invented flags. Note the plan's `skia_enable_gpu=false` is
**stale nomenclature** - m144 has no `skia_enable_gpu`; the correct arg is `skia_enable_ganesh`,
and it must stay **true** (section 4).

---

## 3. Bundled vs system deps for M0 + the version-skew resolution

**Recommendation: bundled (`skia_use_system_*=false` for all).** Skia vendors its own freetype,
harfbuzz, icu, libpng, zlib, expat, libjpeg-turbo, and wuffs under `third_party/externals/`
(populated by `python3 tools/git-sync-deps`, which reads `DEPS`). Building against those instead
of pointing Skia at Ladybird's staged copies is the lowest-friction path for a static M0 and it
**dissolves the version-skew caveat the plan flagged**: when Skia uses its own vendored freetype
(2.13-ish) / harfbuzz / icu internally, there is no ABI or version negotiation with Ladybird's
independently-pinned freetype 2.13.3 / harfbuzz 10.2.0 / icu 78.3. The two font stacks are fully
isolated; Skia only ever sees positioned glyphs from Ladybird at the API surface, not shared
harfbuzz/icu state. `skia_use_system_icu=true` (what the flatpak recipe uses) is the exact opposite
choice and is what would reintroduce the skew, so we deliberately do not take it.

Practical cost: `git-sync-deps` clones the full external set (icu is the heavy one). For M0 only
freetype, harfbuzz, icu, libpng, zlib, expat, libjpeg-turbo, and wuffs are needed; the driver can
either run the full `git-sync-deps` (simplest, needs network at `docker run` time like every other
recipe) or clone just that subset into `third_party/externals/` from `DEPS`. Recommend full
`git-sync-deps` first, prune later if image size bites.

**`nasm` is a host tool.** Skia's bundled libjpeg-turbo SIMD path assembles with `nasm`; the
Debian image does not ship it. Add `apt-get install -y nasm` to the driver's host-tool preamble
(same shape as `build-wayland-apps.sh` installing `wayland-scanner`/`tic`). Bundled zlib/png/expat
need no extra host tools.

---

## 4. Fonts / codecs / the Ganesh-must-stay-compiled correction

**Raster text works, but Ganesh cannot be fully disabled.** The plan says "`skia_enable_gpu=false`
... is a complete backend." Verified against the source, that is half right and one word off:

- `skia_use_freetype=true` + `skia_use_harfbuzz=true` + `skia_use_icu=true` pulls in freetype glyph
  rasterization, the path/blitter code, and the custom fontmgrs
  (`skia_enable_fontmgr_custom_embedded`/`_directory` derive from `skia_use_freetype`,
  `gn/skia.gni:141-143`). That is the full CPU text + geometry path Ladybird needs. Good.
- **But Ladybird references Ganesh symbols unconditionally at compile/link time, not just under an
  ifdef.** `LibGfx/PaintingSurface.cpp:105` calls `SkSurfaces::RenderTarget(context->sk_context(),
  ...)` guarded only by a runtime `if (context)`, and `LibGfx/SkiaBackendContext.{h,cpp}`
  unconditionally `#include <gpu/ganesh/GrDirectContext.h>` and declare
  `virtual GrDirectContext* sk_context()`. On iOS none of `AK_OS_MACOS`/`USE_VULKAN`/`USE_DIRECTX`
  is defined, so `create_independent_gpu_backend()` falls through to `return nullptr` (CPU path at
  runtime) - but the `GrDirectContext` and `SkSurfaces::RenderTarget` **symbols must still resolve
  at link**. If Skia were built with `skia_enable_ganesh=false`, those symbols vanish from
  `libskia.a` and Ladybird fails to link.

**Resolution: `skia_enable_ganesh=true` (keep the default) with every GPU backend off**
(`skia_use_gl/metal/vulkan/dawn=false`, `skia_enable_graphite=false`). This compiles Ganesh's
backend-agnostic core (GrDirectContext base, `SkSurfaces::RenderTarget`) so Ladybird links, while
pulling in **no** Metal/GL/Vulkan/Ganesh-GPU translation units - so no GPU entitlement, no
`xcrun metal`, no Metal framework link. At runtime the null context routes through
`SkSurfaces::WrapPixels` (CPU). This is the corrected reading of the plan's intent. (`gn/skia.gni:169`
even self-documents that GL implies ganesh: `skia_use_gl = skia_use_gl && skia_enable_ganesh`.) Flag
for the full compile: confirm the ganesh-core-without-backend configuration actually emits
`SkSurfaces::RenderTarget`/`GrDirectContext::getResourceCacheUsage` into `libskia.a` (section 6).

Alternative if that link check fails: keep `skia_enable_ganesh=false` and add a one-file Ladybird
patch that `#ifdef`s the `SkSurfaces::RenderTarget` call and the `gpu/ganesh` includes out on iOS.
More Ladybird-side churn; only take it if the ganesh-no-backend build does not link.

No GPU/Metal/Ganesh-GPU TU is pulled with the args above: `skia_use_metal=false` keeps
`GrMtl*`/`GrBackendRenderTargets::MakeMtl` out (those are `#ifdef AK_OS_MACOS` on the Ladybird side
anyway, so iOS never references them).

---

## 5. Staging into Ladybird: header layout + `skia.pc`

Ladybird's `Meta/CMake/check_for_dependencies.cmake` tries `find_package(unofficial-skia CONFIG)`
first (the vcpkg CONFIG package) and, when absent, falls back to:

```cmake
pkg_check_modules(skia skia=${SKIA_REQUIRED_VERSION} REQUIRED IMPORTED_TARGET skia)
set(SKIA_TARGET PkgConfig::skia)
set_property(TARGET PkgConfig::skia APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS "SKCMS_DLL")
```

where `SKIA_REQUIRED_VERSION` is parsed from `vcpkg.json` (= `144`). So a pkg-config `skia.pc`
advertising `Name: skia` / `Version: 144` satisfies `PkgConfig::skia` exactly, and the CONFIG
package can stay absent - no vcpkg install tree required. This is the route the plan predicted.

### Header layout

Mirror Ladybird's own flatpak install (`Meta/CMake/flatpak/skia/skia-install.sh`), which is the
authoritative Ladybird-side layout, but also copy `src/*.h` the way vcpkg's portfile does (some
public Skia headers include `src/...` privates):

```
$PREFIX/include/skia/            <- copy of Skia include/  (core/, gpu/ganesh/, ...) 
$PREFIX/include/skia/modules/    <- copy of Skia modules/*.h
$PREFIX/include/skia/src/        <- copy of Skia src/*.h   (vcpkg parity, safety)
```

Ladybird includes headers as `<core/SkCanvas.h>`, `<gpu/ganesh/GrDirectContext.h>`, so the include
dir handed to the compiler is `$PREFIX/include/skia`. Apply the flatpak's fixups verbatim:
- flatten `include/skia/include/*` up one level, and
- rewrite `#include "include/..."` -> `#include "..."` across the installed headers
  (`grep -rl '#include "include/'` + sed).

### `skia.pc`

```
prefix=/var/jb
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include/skia

Name: skia
Description: 2D graphic library for drawing text, geometries and images.
URL: https://skia.org/
Version: 144
Libs: -L${libdir} -lskia -lskcms
Cflags: -I${includedir}
```

This is byte-for-byte the flatpak `skia.pc` (Version 144, `-lskia -lskcms`). The static build emits
`libskia.a` (`:skia`) and `libskcms.a`; install both to `${libdir}`.

- `Requires:` stays **empty** - bundled deps are archived into `libskia.a`, nothing external to
  chase, no version-skew handles exposed.
- `Cflags:` is just `-I${includedir}`; the consumer adds `SKCMS_DLL` itself (the CMake snippet
  above), so it is not repeated here.
- `Libs:` may need the Apple framework/`-lobjc` closure appended once resolved at link time. Skia's
  apple config adds `libs += ["objc"]` (`gn/skia/BUILD.gn:228`), and freetype-fontmgr + image
  generators can pull `CoreFoundation`/`CoreGraphics`/`CoreText`/`ImageIO`. Finalize the exact set
  from Ladybird's link `otool -l` / undefined-symbol pass; start with
  `Libs: -L${libdir} -lskia -lskcms -lobjc -framework CoreFoundation -framework CoreGraphics
  -framework CoreText -framework ImageIO` and trim. (Marked as a section-6 risk.)

Because iOS is a static build, this staging goes into the **Ladybird build prefix**, not a
standalone deb. Skia links into Ladybird's binaries; the "one deb" is Ladybird's.

---

## 6. Recipe integration: `build-skia.sh`, not a `.mk`

**Recommend a standalone `build-skia.sh` driver**, not a Procursus `recipes/*.mk`. Reasons, both
matching house convention:

- Procursus recipes are autotools/meson-shaped (`DEFAULT_CONFIGURE_FLAGS`, `EXTRACT_TAR`,
  `AFTER_BUILD`, `PACK`/`SIGN`). GN + `git-sync-deps` + `ninja` fits none of that; the plan itself
  says Skia "does not fit the Procursus recipe mold cleanly."
- The house already keeps the awkward, non-Procursus builds as standalone drivers:
  `build-mutter.sh`, `build-kf6.sh`, `build-bun-ios.sh`, `build-opentui-ios.sh`,
  `build-fff-ios.sh`, and `build-opencode.sh`. Skia belongs with those.
- Skia produces **no deb of its own** - it links into Ladybird - so the Procursus `PACK`/`SIGN`
  machinery is not even wanted. A `.mk` would fight that.

`build-skia.sh` shape (mirrors `build-icu.sh`'s driver preamble):

1. Host tools: `apt-get install -y nasm` (+ ensure `python3`, `ninja`, `git`, `curl` present -
   they are).
2. PATH shim: prepend a dir with `libtool -> aarch64-apple-darwin-libtool` (section 2a) and write
   the `skia-cc`/`skia-cxx` triple wrappers (section 2b).
3. Fetch: `git clone` skia, `git checkout ee20d565...`, `python3 tools/git-sync-deps`.
4. `gn gen out/ios-arm64 --args='...'` (section 2c) then `ninja -C out/ios-arm64 skia`. Fetch `gn`
   via Skia's `bin/fetch-gn` (or reuse the container's `gn` if the concurrent Dockerfile work adds
   one; do not add it yourself).
5. Stage `libskia.a`, `libskcms.a`, headers, and `skia.pc` into the Ladybird build prefix
   (section 5).

Invoke from `run.sh`-style `docker run` with the Ladybird build volume mounted, the same way
`build-icu.sh` mounts `procursus-vol-gtk`. Keep it out of the default `TARGETS` loop - it is a
one-shot dependency stage for the Ladybird build, gated behind that track.

---

## 7. Dry-run status: **un-run**, argument-set validated statically

`gn gen` was **not executed**. An honest `gn gen` for `:skia` needs the full Skia source tree plus
`third_party/externals/` populated by `git-sync-deps` (the wrapper `BUILD.gn`/`.gni` files for the
bundled deps are `import`ed into the `:skia` graph). Fetching the multi-hundred-MB source + all
externals is exactly the heavy step this task is scoped to avoid, and the compiler half
(clang-19 + cctools) lives in the Docker image the concurrent agent owns. Per the task's stated
fallback, the argument set was instead validated against the m144 GN files directly:

- Fetched and read `gn/skia/BUILD.gn`, `gn/BUILDCONFIG.gn`, `gn/toolchain/BUILD.gn`, `gn/skia.gni`,
  `gn/ios.gni`, `gn/find_xcode_sysroot.py` at commit `ee20d565...`.
- Confirmed every arg in section 2c is a real `declare_args()` entry (line refs in 2d), so GN will
  not reject the configuration for unknown args.
- Proved the xcrun bypass from the guard at `gn/skia/BUILD.gn:24` (`is_ios && xcode_sysroot == ""`):
  setting `xcode_sysroot` skips the sole `xcrun` call on the `:skia` path.
- Confirmed the iOS archiver is `libtool -static` (`gn/toolchain/BUILD.gn:297-303`), which drives
  the PATH-shim requirement.
- Confirmed `cc`/`cxx`/`ar` are injectable declare_args (`gn/BUILDCONFIG.gn:21-23`), matching how
  vcpkg's own portfile feeds a non-Apple compiler.

Walls hit during design: (1) `gn/BUILD.gn` does not exist at m144 - the compiler config lives in
`gn/skia/BUILD.gn` (initial fetch 404'd; resolved). (2) The plan's `skia_enable_gpu` arg does not
exist at m144 (renamed `skia_enable_ganesh`) and must stay **true**, not false (section 4) - the
one substantive correction to the plan.

---

## 8. Open risks for the full compile

1. **Ganesh-core-without-backend link.** The central bet (section 4): does
   `skia_enable_ganesh=true` with all backends off actually emit `SkSurfaces::RenderTarget` and the
   `GrDirectContext` base methods into `libskia.a`? Verify with `nm libskia.a | grep RenderTarget`
   before trusting the Ladybird link. Fallback = the one-file Ladybird ifdef patch.
2. **`libtool` shadowing.** GNU `libtool-bin` in the image will silently break the archive step if
   the PATH shim is wrong. Verify the archive rule resolves cctools `libtool`
   (`aarch64-apple-darwin-libtool`), not `/usr/bin/libtool`.
3. **Bare clang-19 + `-arch arm64`/`-isysroot` MachO targeting.** The triple wrapper
   (`--target=arm64-apple-ios16.0`) should make upstream clang-19 emit Mach-O for iOS, but this
   combination (upstream clang, cctools `ld64`/`libtool`, 16.5 SDK) is unproven for Skia
   specifically. First failure mode to watch: clang not switching to the Darwin driver, or
   `-fno-aligned-allocation`/`-stdlib=libc++` (Skia-injected) mismatching the SDK libc++.
4. **`nasm` SIMD vs iOS.** Bundled libjpeg-turbo assembles arm64 SIMD; confirm the nasm path is
   actually arm64 (some Skia builds route arm64 SIMD through the compiler, not nasm). If nasm
   objects mis-target, set `skia_use_libjpeg_turbo_decode` SIMD off or drop the codec (Ladybird has
   its own libjpeg-turbo for image decoding; Skia's is only for `SkImage` decode paths M0 may not
   hit).
5. **Apple framework closure in `skia.pc`.** The exact `-framework`/`-lobjc` set (section 5) is a
   guess until the Ladybird link surfaces undefined symbols; too many frameworks over-links, too
   few fails the link.
6. **`git-sync-deps` weight + network.** Full external fetch (icu especially) is large; if the
   image or CI budget bites, switch to a pruned manual clone of just the eight needed externals.
7. **skcms visibility under `-DSKCMS_DLL` in a static lib.** `SKCMS_DLL` flips skcms symbol
   visibility for a shared build; in a static archive it should be inert, but confirm skcms symbols
   are actually present in `libskcms.a` (Ladybird's `ColorSpace.cpp` needs `skcms_Parse` et al.).
8. **`skia-include-string.patch` / GCC-isms.** vcpkg applies a handful of source patches
   (`skia-include-string`, `bentleyottmann-build`). Most target MSVC/GCC or the modules/shared
   build; a raster static clang build likely needs none, but a missing `#include <string>` is the
   classic first compile error - keep that patch handy.
