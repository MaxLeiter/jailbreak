# Ladybird on iOS — leaf-dependency tier & build integration

Status: **Phase 0 design, settled 2026-07-02.** Companion to [`ladybird-plan.md`](ladybird-plan.md)
(coordinator-owned; that doc holds the top-level feasibility, phasing, and the Skia/toolchain
walls). This doc scopes the **leaf third-party closure** for the headless-raster **M0** and
settles the build-integration fork. Skia is out of scope here (standalone `build-skia.sh`, other
agent); ICU 78.3 is DONE (recipe deb, do not touch); the toolchain (clang-19) is done.

---

## Recommendation (the fork): Option B, per-dep Procursus recipes

**Drive the whole leaf closure as Procursus recipes on `procursus-vol-ladybird`, exactly like
ICU. Do not adopt vcpkg.** One line: *ICU 78.3 built cleanly as a recipe against our
cctools+clang-19 cross toolchain, proving the house mechanism satisfies even Ladybird's hardest
pin (`find_package(ICU 78.3 EXACT REQUIRED)`), while vcpkg-on-iOS with a non-Apple host toolchain
remains entirely unproven.*

Deciding evidence and rationale:

- **The house mechanism is proven for this exact job.** ICU 78.3 is the worst-case dep (EXACT
  version pin, native-then-cross double build, data-blob packaging) and it came out clean:
  `.pc` reads `78.3`, arm64 Mach-O NOUNDEFS, Unicode 17.0. Every other leaf is easier than ICU.
- **vcpkg would be a second, unproven toolchain integration.** vcpkg needs a triplet that wires
  our cctools `ld64` + apt.llvm.org clang-19 + the 16.5 SDK as a *cross* toolchain with
  `VCPKG_CMAKE_SYSTEM_NAME iOS`. Nobody runs vcpkg iOS builds from a Linux host with a non-Apple
  toolchain; Skia (GN) and ffmpeg ports would still need per-port patching. Its output is a vcpkg
  install tree we would then hand-repackage into a deb, foreign to `xmkdeb`/signing.
- **The rest of the closure already fits Option B.** Skia is a standalone GN driver
  (`build-skia.sh`); ICU is a recipe deb. If the leaves are recipes too, the *entire* closure is
  recipe/driver-based and there is no vcpkg tree to hand-package. One pipeline, one signing path,
  versions under our control (which the EXACT-pin deps force anyway).
- **The recipe count is manageable.** ~19 M0 leaves. Of those, **11 already have an upstream
  Procursus recipe we just bump**, and **8 are new** (5 of the 8 are header-only or single-file
  amalgamations, i.e. near-trivial). That is a day of recipe writing, not a project.
- **Nothing specifically favors vcpkg.** The one argument for A was "Ladybird's ports already
  know how to build Skia" — but Skia is already a bespoke standalone driver on our side, so that
  advantage evaporates for the only genuinely hard dep.

**Linking model (design note).** `BUILD_SHARED_LIBS OFF` on iOS controls only how Ladybird
builds *its own* Lagom libraries; third-party imported targets can still resolve to `.dylib`.
So the leaves ship as **normal Procursus dylib debs** (like ICU) staged into `BUILD_BASE` on
`procursus-vol-ladybird`, and Ladybird links them via `find_package`/pkg-config. This matches
the ICU-as-deb precedent and sidesteps a static-archive detour. The plan's "one deb" ideal
(fully static third-party folded into the binaries) is a **later size optimization**, not an M0
requirement; do not block M0 on it. On-device we ship Ladybird plus its leaf-dep debs as a
dependency set, the same shape as every other stack here.

**Do NOT reuse our existing GNOME/desktop-track debs.** Our `curl`/`libxml2`/`nghttp2`/`harfbuzz`
overrides are stripped, older, GNOME-purposed builds (harfbuzz 2.8.1 without ICU, curl without
http2/brotli, etc.). Ladybird's version pins and feature needs differ, and the tracks live on
separate build volumes, so Ladybird gets its own recipes at the pinned versions. `libpsl` 0.21.5
is the one exact-version reuse.

---

## Per-dep action table (M0-critical leaf closure)

Versions: **Pin** = Ladybird `vcpkg.json` override. **Upstream** = ProcursusTeam/Procursus
`makefiles/*.mk` today. **Ours** = what we already ship in `out/` (or build into a volume base).

| Dep | Pin | Upstream recipe | Ours (`out/`) | Action | Notes |
|---|---|---|---|---|---|
| zlib | 1.3.1 | none (only `zlib-ng`) | SDK `libz` | **NEW** | Trivial autotools/CMake. Root of the tree (libpng/freetype/curl/openssl/libxml2/ffmpeg all pull it). Do not substitute zlib-ng. |
| libpng | 1.6.50 | `libpng16` 1.6.37 | via base | **BUMP** | autotools `configure` retained at 1.6.50; needs zlib. `apng` patch is upstream's default source variant. |
| libjpeg-turbo | 3.1.1 | 2.0.6 | 2.0.6-1 | **BUMP** | Major 2→3 jump. CMake. arm64 SIMD uses NEON intrinsics, **no nasm** needed (nasm is x86-only). Big soname move (libjpeg 8→ ; turbo API stable). |
| libwebp | 1.6.0 | 1.2.2 | via base | **BUMP** | autotools. anim+mux+simd. Optional libpng/jpeg for tooling only. |
| freetype | 2.13.3 | 2.12.1 | via base | **BUMP** | autotools `configure` retained. **Build without harfbuzz first** (see cycle in build order). Needs zlib; brotli for WOFF2 glyph tables; libpng for embedded PNG. |
| fontconfig | 2.17.1 | 2.14.0 | libfontconfig1 2.14.0 | **BUMP (verify build system)** | Needs freetype + **expat** + host **gperf**. RISK: fontconfig moved toward meson post-2.14; confirm 2.17.1 still ships `configure` or switch the recipe to meson. Ships runtime config (`/etc/fonts` → `/var/jb/etc/fonts`) that must land on-device even when statically linked. |
| harfbuzz | 10.2.0 | 2.8.1 (autotools, `--without-icu`) | libharfbuzz0b 2.8.1 | **NEW** | Our recipe is unusable: 10.2.0 is **meson-only** (autotools dropped in HB 8.0) and Ladybird needs **`-Dicu=enabled -Dfreetype=enabled`** (our override disabled ICU). Write fresh meson recipe. Depends freetype + ICU. Highest-touch leaf. |
| libxml2 | 2.13.8 | 2.9.12 (our override too) | via base | **BUMP** | Ladybird-specific recipe (our override is a GNOME no-python build; reuse that pattern, bump to 2.13.8). Needs zlib; ICU optional. |
| sqlite3 | 3.52.0 | 3.34.1 | via base | **BUMP** | Big version jump, trivial recipe (amalgamation). Low risk. |
| openssl | 3.5.3 | 3.2.1 | via base | **BUMP** | Upstream recipe **already injects a `darwin64-arm64` iOS `Configure` target** (perlasm ios64) — mechanics are proven, just bump + re-validate the custom target and no-asm/perlasm against 3.5.x. curl's TLS backend. |
| nghttp2 | (curl feat) | 1.61.0 | (our override, lib-only) | **REUSE** | Not a Ladybird pin; it is curl's http2 dep. Build lib-only (our override pattern) to avoid dragging nghttp3/ngtcp2. |
| curl | 8.20.0 | 8.7.1 | (our override, stripped) | **BUMP** | Ladybird-specific recipe. M0 feature set: **openssl + nghttp2 (http2) + zlib + brotli + zstd + libpsl + websockets**. **Drop http3** (nghttp3/ngtcp2/quictls) for M0 (open-question #7 — http2-only is fine). |
| brotli | (woff2/curl) | 1.1.0 | via base | **REUSE** | Feeds woff2 and curl. Upstream 1.1.0 is fine. |
| woff2 | 1.0.2 | none | — | **NEW** | CMake. Depends brotli. Small. |
| wuffs | 0.3.4 | none | — | **NEW** | Header-only image codecs; effectively a header-drop into the prefix. Trivial. |
| simdutf | 7.4.0 | none | — | **NEW** | Single-file amalgamation, CMake. Trivial. |
| simdjson | 4.2.4 | none | — | **NEW** | Single-file amalgamation, CMake. Trivial. |
| fmt | 12.1.0 | `libfmt` 7.1.3 | — | **BUMP** | Major 7→12 jump, but pure CMake + headers. Low risk. |
| fast-float | 8.1.0 | none | — | **NEW** | Header-only. Trivial. |
| libtommath | 1.3.0 | 1.2.0 | via base | **BUMP** | Tiny bignum for LibCrypto. Trivial. |
| mimalloc | 2.2.7 | none | — | **NEW** | CMake allocator. Small, self-contained. |
| ICU | 78.3 EXACT | (our recipe) 78.3 | libicu78 78.3+ios1 | **DONE** | Built 2026-07-02 (`recipes/icu4c.mk`, native-then-cross). Do not touch. |
| expat | (fontconfig) | present | via base | **REUSE** | fontconfig sub-dep. |

**Tally (the 19 primary M0 leaves):** **11 BUMP**, **8 NEW**, plus **ICU DONE (reuse)** and 3
supporting reuses (brotli, nghttp2, expat). No leaf is a from-scratch research problem; the only
build-system rewrite is harfbuzz (autotools→meson).

### Host / native-tool needs

- **ICU** — native-then-cross (host `genrb`/`icupkg`/`pkgdata` via `--with-cross-build`). Done.
- **fontconfig** — host **gperf** (charset tables) at configure time; expat at link.
- **libjpeg-turbo** — nasm listed by Ladybird's harness but **not required on arm64** (NEON
  intrinsics). Install nasm to satisfy the harness check if it gates, otherwise ignore.
- Everything else is a plain single-stage cross build (no host codegen).

### Version-skew reality

Because the build wants matching-version *sources*, **every leaf except libpsl and the
supporting brotli/nghttp2/expat is too old in our tree to reuse** — freetype, fontconfig,
libpng, sqlite3, libxml2, libjpeg-turbo, libwebp, curl, openssl, harfbuzz, fmt, libtommath all
lag their pins, several by major versions (harfbuzz 2.8→10, libjpeg-turbo 2→3, fmt 7→12, sqlite
3.34→3.52). Treat "we already ship it" as *false* for reuse purposes across this closure; the
bump/new-recipe column is authoritative.

---

## The 3–5 painful leaves

1. **harfbuzz 10.2.0** — the only build-system rewrite: our autotools `--without-icu` recipe is
   dead weight, 10.2.0 is meson-only, and Ladybird needs `icu=enabled freetype=enabled`. This
   creates the freetype↔harfbuzz↔ICU ordering below and is the highest-touch leaf.
2. **ffmpeg 7.1.1 — reclassify as M0-configure-REQUIRED, not fully deferrable.** Correction to
   the plan's split: `check_for_dependencies.cmake` does `pkg_check_modules(AVCODEC REQUIRED ...)`
   for avcodec/avformat/avutil/swresample **unconditionally** (non-Android). So configure fails
   without an ffmpeg 7.1.x present, even though *playback* is an M2 concern. Two routes: (a) build
   a **minimal ffmpeg 7.1.1** (avcodec/avformat/avutil/swresample only, `--disable-everything`
   plus a token decoder, no dav1d/vpx/opus) so the REQUIRED find succeeds; or (b) patch the four
   `pkg_check_modules(... REQUIRED)` lines to non-required on iOS and stub the LibMedia call
   sites. Our `out/` ffmpeg is 5.1.2 (ffmpeg-5 API); Ladybird uses the ffmpeg-7 API, so there is
   no reuse. **Recommend route (a) minimal ffmpeg 7.1.1** as least-invasive; it is a med recipe,
   not trivial. Full codec set is M2.
3. **openssl 3.5.3** — mechanically a 3.2→3.5 bump, but it rides the recipe's hand-injected
   `darwin64-arm64` Configure target + perlasm; re-validate that target and the no-asm fallback
   against 3.5.x. Feeds curl.
4. **fontconfig 2.17.1** — build-system drift risk (meson vs configure at 2.17), host gperf +
   expat + freetype wiring, and it carries **runtime data** (`/var/jb/etc/fonts`,
   `<dir>/var/jb/share/fonts`) that must be packaged and present on-device or text renders with
   no fonts even after a clean static link.
5. **curl 8.20.0** — not hard, but our existing curl is a stripped GNOME build, so a
   Ladybird-specific recipe with the right feature/dep wiring (openssl+nghttp2+zlib+brotli+zstd+
   psl, http3 off) is genuinely new work.

---

## M0-critical build order (leaf → dependent)

Bootstrap note: **freetype and harfbuzz are mutually optional.** freetype's autofitter can use
harfbuzz; harfbuzz needs freetype. Break the cycle by building **freetype WITHOUT harfbuzz
first**, then harfbuzz WITH freetype. Ladybird does not need freetype-with-harfbuzz for M0, so
skip the freetype rebuild.

```
Tier 0 (no intra-closure deps, build in any order / parallel):
  zlib · brotli · openssl · nghttp2 · sqlite3 · libtommath ·
  fmt · fast-float · simdutf · simdjson · mimalloc · wuffs · expat

Tier 1 (need Tier 0):
  libpng            (zlib)
  libjpeg-turbo     (—)
  libwebp           (—, opt libpng/jpeg)
  freetype[no-hb]   (zlib, brotli, libpng)
  libxml2           (zlib)
  woff2             (brotli)
  curl              (openssl, nghttp2, zlib, brotli, zstd, libpsl)

Tier 2 (need Tier 1 + ICU-done):
  harfbuzz          (freetype, ICU)
  fontconfig        (freetype, expat, gperf-host)

Tier 3 (media, M0-configure-required minimal build):
  ffmpeg 7.1.1 minimal   (zlib)

Tier 4 (other agent — links the above):
  skia 144 raster        (freetype, fontconfig, harfbuzz, ICU, libpng, zlib, wuffs)

Tier 5:
  Ladybird               (entire closure)
```

Deferrable to M2 (not on the M0 order): libjxl 0.11.1 (+highway 1.4.0), libavif 1.3.0 (+dav1d
1.5.1), tiff 4.7.1, libedit, cpptrace/libdwarf, libproxy, and curl http3 (nghttp3/ngtcp2/quictls).
Upstream Procursus already has recipes for dav1d (1.0.0, bump), libtiff (4.2.0, bump), libedit,
nghttp3 (1.2.0), ngtcp2 (1.4.0) when M2 comes.

---

## Ladybird source-side M0 changes (for the build agent)

These are engine-tree patches, not deps. Exact files verified against `master` (2026-07-02):

1. **Sandbox → Unimplemented.** `Services/WebContent/CMakeLists.txt` selects the sandbox by
   platform: `if (LINUX) … elseif (APPLE) … RendererSandboxMacOS.cpp … else() …
   RendererSandboxUnimplemented.cpp`. **iOS trips the `APPLE` branch** (CMake `APPLE` is true on
   iOS) and would compile the macOS Seatbelt path, which is unavailable to fakesigned iOS procs.
   Fix: change the branch to **`elseif (APPLE AND NOT IOS)`** so iOS falls to
   `RendererSandboxUnimplemented.cpp`. Belt-and-suspenders: also run with the existing
   **`--disable-sandbox`** flag. (Files: `Services/RendererSandboxMacOS.cpp`,
   `RendererSandboxUnimplemented.cpp`, `RendererSandboxLinux.cpp`, `RendererSandbox.h`.)

2. **SDL3 gamepad → drop for M0.** `Meta/CMake/check_for_dependencies.cmake` does
   `find_package(SDL3 CONFIG REQUIRED)` **unconditionally**; SDL3 is used only by
   `Libraries/LibWeb/Gamepad/*` and `Libraries/LibWeb/Internals/InternalGamepad.cpp`. For M0,
   gate the `find_package(SDL3 …)` behind `if (NOT IOS)` and exclude the `LibWeb/Gamepad` sources
   / stub `NavigatorGamepad` on iOS. (Alternative, if stubbing proves invasive: SDL3 3.2.28 is an
   Apple-blessed lib that cross-builds cleanly to iOS, so a real SDL3 recipe is a low-risk
   fallback — but M0 does not need gamepad, so prefer the patch.)

3. **ffmpeg → minimal build or make optional.** Same `check_for_dependencies.cmake`:
   `pkg_check_modules(AVCODEC/AVFORMAT/AVUTIL/LIBSWRESAMPLE REQUIRED IMPORTED_TARGET …)`. Provide
   a minimal ffmpeg 7.1.1 (Tier 3 above) so the REQUIRED find succeeds, OR patch those four lines
   to non-required on iOS and stub the LibMedia decoder plumbing. Prefer the minimal build.

4. **`-D__IOS__`** in the cross flags (or patch `AK/Platform.h` to test `TARGET_OS_IPHONE`), and
   steer `Meta/CMake/use_linker.cmake` to ld64. (Detailed in `ladybird-plan.md`.)

5. **Skia discovery.** `check_for_dependencies.cmake` accepts `PkgConfig::skia` when the
   `unofficial-skia` CONFIG package is absent, so the standalone `build-skia.sh` only needs to
   stage a `skia.pc` with the pinned version. (Owned by the Skia agent; noted here for the order.)
