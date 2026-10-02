# Ladybird rebase onto upstream master (2026-10)

Status: phase 1 (patch port + recipe/script prep) done on the host; nothing built yet.

- Old pin: `92b0257e` (2026-07-02). New target: `b9c913c09f6dc8031749dd1d3f44417225077a84` (upstream master, 2026-10-02), 6300+ commits.
- The patch series is carried as plain `patch -p1` diffs in `linux-build/recipes-ladybird/{patches-m0,patches}/` and applied by
  `ladybird-m0-patches.sh` (rewritten: forward-apply, skip if already applied, abort on failure; the old semantic-marker
  table and stale-tree cleanup are gone, builds use fresh `-r2` work dirs).
- Reproducibility check: applying the series to a clean checkout of b9c913c0 yields a tree identical (same git tree hash) to the porting branch.

## Per-patch outcome

| patch | outcome |
|---|---|
| m0 0001 sandbox + libedit gates | applied (same hunks) |
| m0 0002 drop AVIF + JPEG-XL | reworked: JPEG-XL is now the in-tree Rust `jxl` crate, so only the AVIF half remains (libavif is not staged) |
| m0 0003 helper build graph | applied (same hunks) |
| m0 0004 Darwin source gates | reworked: also gates new `VideoSurfaceImage.mm` (Metal) and `VideoToolbox/VideoToolboxVideoDecoder.mm` out of the iOS build |
| m0 0005 host AsmInterpreter tools | reworked: upstream replaced `gen_asm_offsets`/`asmintgen` with `generate_interpreter_layout` + Rust `flapc` + `generate-libjs-bytecode`. Now env-driven (`LB_HOST_GENERATE_INTERPRETER_LAYOUT`, `LB_HOST_RUST_BIN_DIR`); `--has-jscvt` is no longer passed for Apple aarch64 when IOS (A10 has no FEAT_JSCVT) |
| m0 0006 compositor gates | reworked (same intent, new call sites in `Application.cpp`) |
| m0 0007 headless-shot driver | applied; the `headless-shot` target is not part of any build or package now |
| m0 0008 CoreText SkFontMgr (+ old 0010 force-fontconfig reject) | merged and reworked for the new TypefaceSkia / `force_freetype_rasterization` code |
| m0 0009 screenshot raster (headless only) | NOT ported, moved to `patches-shelved/`: needs a rewrite against LibCompositing and only the unshipped headless M0 build used it |
| app build-graph | reworked (also: `ladybird_sign_helper_process` is a no-op on iOS, new `MediaServer` helper CMake gate) |
| app cpu-fallback | applied with new hunk locations |
| app iosurface-mach-ipc | reworked: upstream (d8ad6476) already builds Mach-port IPC on iOS, so most `AK_OS_MACOS -> || AK_OS_IOS` hunks are upstream now. What remains: Mach bootstrap listener/transport on iOS (no task-port exchange), IOSurface on iOS, SharedImage/SharedImageBuffer, LibWebView/WebContent bootstrap hunks, LibWebView CMake gates (CrashReportPOSIX, LaunchURLsMacOS, ProcessReaper are macOS-only) |
| app caret-after-events, caret-pageclient-access | obsolete: upstream pushes `update_input_method_state` after key and mouse events (public API) |
| app real-angle-pkgconfig | applied |
| app angle-compat | applied (may need more adapter symbols at link) |
| app webgl-ios-enable + release-cleanup | merged, reworked for `Compositing::WebGL` / `ENABLE_WEBGL_CPU_PAINTING_SURFACE` |
| wayland: gtk-frontend, gtk-4-14-memory-texture, desktop-mach-bootstrap | moved to `patches-wayland-pending/`, not in any series: upstream deleted `UI/Gtk` (2026-07-09) and the AppKit UI. Wayland flavor stays on the old engine until the Qt UI (needs Qt 6.10) lane exists |

## Dependency pins (upstream vcpkg.json at b9c913c0)

Bumped here (Ladybird-private): OpenSSL 3.6.3, simdutf 9.1.0, simdjson 4.6.4, fmt 12.2.0, fast-float 8.2.10, Skia m148
(`e7c90ecc`), mimalloc 2.2.7 now with `MI_SECURE=ON` (upstream's `mimalloc[secure]`), ffmpeg 7.1.1 as `-ladybird`-suffixed libs
(new packages `libav*-ladybird*`, still no codecs enabled; upstream's `ladybird-components` decoder list is a follow-up).
Owned by upd-wave-core, not touched: curl, nghttp2, libxml2, libpng, sqlite, freetype, harfbuzz (no hard minimum in new CMake).
Not bumped, listed for follow-up: libjpeg-turbo 3.2.0, brotli 1.2.0, zlib, libwebp (unchanged pin), tiff.
Toolchain: clang >= 19 still the minimum; Rust 1.96 -> 1.98 (rustup); no compiler upgrade needed.

## Device bring-up findings (iPad7,12, iPadOS 17.6.1)

Fixups 1-6 (patches/ios-app-fixups-N.patch) came out of compiling and running on device:
- `AK/ThreadID.cpp` returned 0 on iOS, so every IPC `m_owner_thread_id.is_current_thread()` VERIFY failed (UI crashed at launch).
- iOS caps a process at roughly 8-10 GiB of virtual address space. Upstream's GC reserves a 4 TiB primitive-storage cage (and 128 GiB heap region for non-macOS AArch64); both are now 1 GiB on iOS (`HeapRegion.h`, `PrimitiveStorage.h`).
- The host `generate_interpreter_layout` tool must be compiled with `-D__IOS__`, otherwise the generated JS interpreter bakes the Linux masks (SIGBUS in `asm_handler_GetById` on JS-heavy pages).
- WebContent's own SIGSEGV/SIGBUS handler is not installed on iOS so CrashReporter writes .ips files.
Debug aids in the UIKit frontend, all behind the existing `/var/jb/tmp/ladybird-trace` sentinel: stderr of UI + helpers goes to `ladybird-stderr.log`; `ladybird-load-url`, `ladybird-dump` (writes the presented frame to `ladybird-dump.png`) and `ladybird-tap` ("x y" in points) files are polled twice a second. The sentinel files must be removed by the writer (root-created files cannot be unlinked by the app).
