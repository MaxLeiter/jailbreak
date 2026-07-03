#!/usr/bin/env bash
# Ladybird-on-iOS Wave 4 — M0 source patch series (idempotent).
#   usage: ladybird-m0-patches.sh <ladybird-source-dir>
#
# These are engine-tree edits (NOT dependency recipes) needed for the headless-raster M0 cross to
# iphoneos-arm64. Each patch is guarded so re-running is a no-op. Rationale per patch inline.
# CMake-level iOS is asserted by the toolchain file (`set(IOS TRUE)`), so `if (IOS)` is usable in
# any CMake reached during configure. Source-level iOS is `__IOS__` (injected by the compiler
# wrapper) -> AK_OS_IOS.
set -euo pipefail
SRC="${1:?usage: ladybird-m0-patches.sh <ladybird-source-dir>}"
cd "$SRC"

say() { echo "  [m0-patch] $*"; }

# ---------------------------------------------------------------------------------------------
# 1) Sandbox -> Unimplemented. Services/WebContent/CMakeLists.txt selects the sandbox by platform;
#    CMake APPLE is true on our Darwin-system-name cross, so it would compile RendererSandboxMacOS
#    (Seatbelt sandbox_init, unavailable to fakesigned iOS procs). Route iOS to the else() branch
#    (RendererSandboxUnimplemented.cpp).
# ---------------------------------------------------------------------------------------------
# WebContent/RequestServer/ImageDecoder each select the sandbox by platform; the `elseif (APPLE)`
# arm compiles the macOS Seatbelt path (SeatbeltPath / add_seatbelt_path_if_exists — absent from
# LibSandbox on iOS). Route all three to the else() Unimplemented arm.
for f in Services/WebContent/CMakeLists.txt Services/RequestServer/CMakeLists.txt Services/ImageDecoder/CMakeLists.txt Services/WebWorker/CMakeLists.txt; do
  if grep -q 'elseif (APPLE)' "$f"; then
    sed -i 's/elseif (APPLE)/elseif (APPLE AND NOT IOS)/' "$f"
    say "sandbox: $f APPLE -> APPLE AND NOT IOS"
  else
    say "sandbox: $f already patched"
  fi
done

# ---------------------------------------------------------------------------------------------
# 2) libedit: only the `js` REPL utility uses it, and Utilities/ is not built on iOS. The check is
#    unconditional for non-win/android, so gate it off for iOS to avoid needing a libedit dep.
# ---------------------------------------------------------------------------------------------
f=Meta/CMake/check_for_dependencies.cmake
if grep -q 'if (NOT WIN32 AND NOT ANDROID)' "$f"; then
  sed -i 's/if (NOT WIN32 AND NOT ANDROID)/if (NOT WIN32 AND NOT ANDROID AND NOT IOS)/' "$f"
  say "libedit: gated off for iOS ($f)"
else
  say "libedit: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 3) libjxl + libavif: M0 renders a page to PNG and does not need JPEG-XL / AVIF decode. These are
#    the only two configure-REQUIRED deps we did not stage. Gate the finds for iOS. (LibImageDecoders
#    CMake + ImageDecoder.cpp dispatch are gated in patches 4/5 so the loaders are not compiled.)
# ---------------------------------------------------------------------------------------------
f=Meta/CMake/check_for_dependencies.cmake
python3 - "$f" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
def gate(line):
    global s
    if line in s and f"if (NOT IOS)\n    {line}" not in s and "# m0-gated" not in s.split(line)[0][-40:]:
        s = s.replace(line, f"if (NOT IOS)  # m0-gated\n    {line}\n    endif()")
if "m0-gated" not in s:
    gate("find_package(LIBAVIF REQUIRED)")
    gate("pkg_check_modules(Jxl REQUIRED IMPORTED_TARGET libjxl)")
    open(p,"w").write(s)
    print("  [m0-patch] jxl/avif: gated find_package(LIBAVIF)+pkg(Jxl) off for iOS")
else:
    print("  [m0-patch] jxl/avif finds: already patched")
PY

# ---------------------------------------------------------------------------------------------
# 4) LibImageDecoders: drop the AVIF + JPEG-XL loader sources and their link libs (avif,
#    PkgConfig::Jxl) on iOS, and compile-define LADYBIRD_M0_NO_JXL_AVIF for the dispatch gate (5).
# ---------------------------------------------------------------------------------------------
f=Libraries/LibImageDecoders/CMakeLists.txt
if ! grep -q 'LADYBIRD_M0_NO_JXL_AVIF' "$f"; then
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# remove the two loader source lines on iOS by wrapping the SOURCES entries in a genex-free filter:
s = s.replace("    ${LIBGFX_IMAGE_FORMATS_DIR}/AVIFLoader.cpp\n", "")
s = s.replace("    ${LIBGFX_IMAGE_FORMATS_DIR}/JPEGXLLoader.cpp\n", "")
# drop the `avif` link line
s = s.replace("    avif\n", "")
# the trailing jxl link if/else block -> iOS links neither PkgConfig::Jxl nor libjxl::libjxl
s = s.replace(
"""if (NOT ANDROID)
    target_link_libraries(LibImageDecoders PRIVATE PkgConfig::Jxl)
else()
    target_link_libraries(LibImageDecoders PRIVATE libjxl::libjxl hwy::hwy)
endif()""",
"""if (IOS)
    # m0: JPEG-XL dropped (no libjxl)
elseif (NOT ANDROID)
    target_link_libraries(LibImageDecoders PRIVATE PkgConfig::Jxl)
else()
    target_link_libraries(LibImageDecoders PRIVATE libjxl::libjxl hwy::hwy)
endif()""")
# compile define so ImageDecoder.cpp drops the JXL/AVIF dispatch + includes
s += "\ntarget_compile_definitions(LibImageDecoders PRIVATE LADYBIRD_M0_NO_JXL_AVIF)\n"
open(p,"w").write(s)
print("  [m0-patch] LibImageDecoders: dropped AVIF/JXL sources+links, defined LADYBIRD_M0_NO_JXL_AVIF")
PY
else
  say "LibImageDecoders: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 5) ImageDecoder.cpp: guard the JXL/AVIF includes + dispatch entries behind LADYBIRD_M0_NO_JXL_AVIF.
# ---------------------------------------------------------------------------------------------
f=Libraries/LibGfx/ImageFormats/ImageDecoder.cpp
if ! grep -q 'LADYBIRD_M0_NO_JXL_AVIF' "$f"; then
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
def guard(line):
    global s
    s = s.replace(line, "#if !defined(LADYBIRD_M0_NO_JXL_AVIF)\n" + line + "#endif\n")
guard("#include <LibGfx/ImageFormats/AVIFLoader.h>\n")
guard("#include <LibGfx/ImageFormats/JPEGXLLoader.h>\n")
guard("        { JPEGXLImageDecoderPlugin::sniff, JPEGXLImageDecoderPlugin::create },\n")
guard("        { AVIFImageDecoderPlugin::sniff, AVIFImageDecoderPlugin::create }\n")
open(p,"w").write(s)
print("  [m0-patch] ImageDecoder.cpp: guarded JXL/AVIF includes+dispatch")
PY
else
  say "ImageDecoder.cpp: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 6) Root: build the helper Services for iOS but skip the AppKit/Qt UI (no Cocoa on UIKit).
#    ENABLE_GUI_TARGETS defaults ON; we pass it explicitly. UI is skipped for iOS.
# ---------------------------------------------------------------------------------------------
f=CMakeLists.txt
if grep -q 'add_subdirectory(UI)' "$f" && ! grep -q 'iOS: skip UI' "$f"; then
  perl -0pi -e 's/(if \(ENABLE_GUI_TARGETS\)\n\s*add_subdirectory\(Services\)\n)(\s*)add_subdirectory\(UI\)/$1$2if (NOT IOS)  # iOS: skip UI (no AppKit\/UIKit frontend at M0)\n$2    add_subdirectory(UI)\n$2endif()/' "$f"
  say "root: Services built for iOS, UI skipped"
else
  say "root: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 7) Services: build only the M0 helper set (ImageDecoder, RequestServer, WebContent, WebWorker).
#    Skip Compositor (links real ANGLE GLES entry points -> GPU path, deferred to M1/M3) and
#    WebDriver (automation frontend, not needed for headless first-light).
# ---------------------------------------------------------------------------------------------
f=Services/CMakeLists.txt
if ! grep -q 'iOS M0 helper set' "$f"; then
  cat > "$f" <<'EOF'
# iOS M0 helper set: the multiprocess engine helpers only. Compositor (ANGLE GLES) + WebDriver
# are deferred (see ladybird-m0-patches.sh patch 7).
add_subdirectory(ImageDecoder)
add_subdirectory(RequestServer)
add_subdirectory(WebContent)
add_subdirectory(WebWorker)
if (NOT IOS)
    add_subdirectory(Compositor)
    add_subdirectory(WebDriver)
endif()
EOF
  say "Services: M0 helper set only (no Compositor/WebDriver on iOS)"
else
  say "Services: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 8) ladybird_helper_processes.cmake: drop Compositor from the helper list on iOS so nothing
#    depends on the un-built target (the list drives helper spawn-path + install).
# ---------------------------------------------------------------------------------------------
f=Meta/CMake/ladybird_helper_processes.cmake
if grep -q '^    Compositor' "$f" && ! grep -q 'iOS M0' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("set(ladybird_helper_processes\n    Compositor\n",
            "# iOS M0: Compositor deferred (GPU/ANGLE)\nset(ladybird_helper_processes\n")
open(p,"w").write(s)
print("  [m0-patch] helper_processes: Compositor removed for M0")
PY
else
  say "helper_processes: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 9) LibCore: gate the macOS-only Platform sources that CMake adds under bare `APPLE`. On our
#    Darwin-system-name cross APPLE is true, but these are genuinely macOS-only:
#      - Platform/ScopedAutoreleasePoolMacOS.mm : header ScopedAutoreleasePool.h already provides an
#        inline no-op class for !AK_OS_MACOS, so the .mm must not compile on iOS.
#      - IOSurface.cpp + `-framework IOSurface` : includes the macOS umbrella <IOSurface/IOSurface.h>
#        (iOS ships only IOSurfaceRef.h); the GPU/IOSurface present path is not part of headless M0.
# ---------------------------------------------------------------------------------------------
f=Libraries/LibCore/CMakeLists.txt
if grep -q 'list(APPEND SOURCES IOSurface.cpp)' "$f" && ! grep -q 'iOS: macOS-only' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace(
"""if (APPLE)
    list(APPEND SOURCES IOSurface.cpp)
    list(APPEND SOURCES Platform/ScopedAutoreleasePoolMacOS.mm)""",
"""if (APPLE AND NOT IOS)  # iOS: macOS-only IOSurface umbrella + AutoreleasePool .mm
    list(APPEND SOURCES IOSurface.cpp)
    list(APPEND SOURCES Platform/ScopedAutoreleasePoolMacOS.mm)""")
s=s.replace(
'''    target_link_libraries(LibCore PUBLIC "-framework IOSurface")''',
'''    if (NOT IOS)
        target_link_libraries(LibCore PUBLIC "-framework IOSurface")
    endif()''')
open(p,"w").write(s)
print("  [m0-patch] LibCore: IOSurface.cpp + ScopedAutoreleasePoolMacOS.mm gated APPLE AND NOT IOS")
PY
else
  say "LibCore macOS gate: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 10) LibGfx MetalContext.mm: gate off for iOS (its header static_asserts macOS-only; the GPU/Metal
#     paint path is deferred past headless M0; PaintingSurface.h/SkiaBackendContext.h already guard
#     the include with AK_OS_MACOS + forward-declare for the stubs).
# ---------------------------------------------------------------------------------------------
f=Libraries/LibGfx/CMakeLists.txt
if grep -q 'list(APPEND SOURCES MetalContext.mm)' "$f" && ! grep -q 'MetalContext.mm)  # iOS' "$f"; then
  perl -0pi -e 's/if \(APPLE\)\n    list\(APPEND SOURCES MetalContext\.mm\)\n/if (APPLE AND NOT IOS)\n    list(APPEND SOURCES MetalContext.mm)  # iOS: Metal deferred past headless M0\n/' "$f"
  say "LibGfx: MetalContext.mm gated APPLE AND NOT IOS"
else
  say "LibGfx MetalContext.mm: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 11) iOS shares Darwin behavior with macOS at several AK_OS_MACOS-only sites the codebase never
#     wrote an iOS arm for. Extend the guard to AK_OS_IOS:
#       - LibThreading/Thread.cpp     : pthread_setname_np(name) is the 1-arg Darwin form (iOS too);
#                                       the #else 2-arg (Linux) form fails to compile on Darwin.
#       - LibWasm BytecodeInterpreter : uc_mcontext is a pointer with __ss.__pc on Darwin arm64
#                                       (iOS too); the #else uc_mcontext.pc (glibc) is wrong.
# ---------------------------------------------------------------------------------------------
f=Libraries/LibThreading/Thread.cpp
if grep -q '#if defined(AK_OS_MACOS)' "$f" && ! grep -q 'AK_OS_MACOS) || defined(AK_OS_IOS)' "$f"; then
  sed -i 's/#if defined(AK_OS_MACOS)$/#if defined(AK_OS_MACOS) || defined(AK_OS_IOS)/' "$f"
  say "LibThreading/Thread.cpp: pthread_setname_np Darwin arm extended to iOS"
else
  say "Thread.cpp: already patched"
fi
f=Libraries/LibWasm/AbstractMachine/BytecodeInterpreter.cpp
if grep -q 'defined(AK_OS_MACOS)' "$f" && ! grep -q 'AK_OS_MACOS) || defined(AK_OS_IOS)' "$f"; then
  sed -i 's/defined(AK_OS_MACOS)$/defined(AK_OS_MACOS) || defined(AK_OS_IOS)/' "$f"
  say "LibWasm/BytecodeInterpreter.cpp: mcontext Darwin arm extended to iOS"
else
  say "BytecodeInterpreter.cpp: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 12) AsmInterpreter host-tool cross split. LibJS builds TWO generators that get cross-compiled for
#     iOS and cannot exec on the Linux build host, blocking LibWeb:
#       - gen_asm_offsets (C++ / AK) -> asm_offsets.conf  (LP64-portable: host arm64 == ios arm64)
#       - asmintgen       (Rust)     -> asmint_<arch>.S   (target asm chosen by --arch, host-agnostic)
#     Fix (native-then-cross, same shape as ICU host tooling): build both NATIVELY in the driver
#     (build-ladybird-wave4b.sh) and point the two add_custom_command COMMANDs at the host binaries
#     via env vars LB_HOST_GEN_ASM_OFFSETS / LB_HOST_ASMINTGEN (read at configure). The DEPENDS on
#     the cross targets are dropped in the host branch so they need not build/run.
#     A10 NOTE: the upstream aarch64+APPLE path appends --has-jscvt (emits ARMv8.3 `fjcvtzs`). The
#     target iPad is an A10 (ARMv8.1, no FEAT_JSCVT) -> the host branch omits --has-jscvt so the DSL
#     emits the software ToInt32 fallback (portable to every arm64; Apple-Silicon loses one fast op).
# ---------------------------------------------------------------------------------------------
f=Libraries/LibJS/CMakeLists.txt
if ! grep -q 'LB_HOST_GEN_ASM_OFFSETS' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
# --- asm_offsets.conf: host gen_asm_offsets when LB_HOST_GEN_ASM_OFFSETS set ---
old_off='''    add_custom_command(
        OUTPUT "${ASM_OFFSETS_FILE}"
        COMMAND "$<TARGET_FILE:gen_asm_offsets>" > "${ASM_OFFSETS_FILE}"
        DEPENDS gen_asm_offsets
        COMMENT "Generating asm struct offsets"
    )'''
new_off='''    if (DEFINED ENV{LB_HOST_GEN_ASM_OFFSETS})
        add_custom_command(
            OUTPUT "${ASM_OFFSETS_FILE}"
            COMMAND "$ENV{LB_HOST_GEN_ASM_OFFSETS}" > "${ASM_OFFSETS_FILE}"
            COMMENT "Generating asm struct offsets (host tool)"
        )
    else()
        add_custom_command(
            OUTPUT "${ASM_OFFSETS_FILE}"
            COMMAND "$<TARGET_FILE:gen_asm_offsets>" > "${ASM_OFFSETS_FILE}"
            DEPENDS gen_asm_offsets
            COMMENT "Generating asm struct offsets"
        )
    endif()'''
assert old_off in s, "asm_offsets custom_command block not found (upstream drift?)"
s=s.replace(old_off,new_off)
# --- asmint_<arch>.S: host asmintgen when LB_HOST_ASMINTGEN set (drop --has-jscvt for A10) ---
old_gen='''    add_custom_command(
        OUTPUT "${ASMINT_GENERATED_S}"
        COMMAND "${ASMINTGEN_BIN}" --arch ${ASMINT_ARCH}
            --object-format ${ASMINT_OBJ_FORMAT}
            --constants "${ASM_OFFSETS_FILE}"
            --bytecode-def "${BYTECODE_DEF}"
            --input "${ASMINT_DSL}"
            --output "${ASMINT_GENERATED_S}"
            ${ASMINT_EXTRA_FLAGS}
        DEPENDS "${ASMINTGEN_BIN}" "${ASMINT_DSL}" "${ASM_OFFSETS_FILE}" "${BYTECODE_DEF}"
        COMMENT "Generating asmint_${ASMINT_ARCH}.S from DSL"
    )'''
new_gen='''    if (DEFINED ENV{LB_HOST_ASMINTGEN})
        # A10 target: NO --has-jscvt (ARMv8.1, lacks FEAT_JSCVT); use software ToInt32 fallback.
        add_custom_command(
            OUTPUT "${ASMINT_GENERATED_S}"
            COMMAND "$ENV{LB_HOST_ASMINTGEN}" --arch ${ASMINT_ARCH}
                --object-format ${ASMINT_OBJ_FORMAT}
                --constants "${ASM_OFFSETS_FILE}"
                --bytecode-def "${BYTECODE_DEF}"
                --input "${ASMINT_DSL}"
                --output "${ASMINT_GENERATED_S}"
            DEPENDS "${ASMINT_DSL}" "${ASM_OFFSETS_FILE}" "${BYTECODE_DEF}"
            COMMENT "Generating asmint_${ASMINT_ARCH}.S from DSL (host tool, no jscvt)"
        )
    else()
        add_custom_command(
            OUTPUT "${ASMINT_GENERATED_S}"
            COMMAND "${ASMINTGEN_BIN}" --arch ${ASMINT_ARCH}
                --object-format ${ASMINT_OBJ_FORMAT}
                --constants "${ASM_OFFSETS_FILE}"
                --bytecode-def "${BYTECODE_DEF}"
                --input "${ASMINT_DSL}"
                --output "${ASMINT_GENERATED_S}"
                ${ASMINT_EXTRA_FLAGS}
            DEPENDS "${ASMINTGEN_BIN}" "${ASMINT_DSL}" "${ASM_OFFSETS_FILE}" "${BYTECODE_DEF}"
            COMMENT "Generating asmint_${ASMINT_ARCH}.S from DSL"
        )
    endif()'''
assert old_gen in s, "asmint custom_command block not found (upstream drift?)"
s=s.replace(old_gen,new_gen)
open(p,"w").write(s)
print("  [m0-patch] LibJS: asm_offsets + asmint custom_commands can use host tools (env-gated)")
PY
else
  say "LibJS asm host-tool split: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 13) launch_services() spawns the Compositor helper unconditionally, but Compositor is deferred
#     for M0 (patches 7/8, GPU/ANGLE). Gate that one spawn off for iOS so the headless path uses
#     RequestServer + ImageDecoder + WebContent only (the async_take_document_screenshot raster path
#     does not need the GPU present helper). Other launch_compositor_process() call sites (restart
#     handlers) are unreachable when it is never launched.
# ---------------------------------------------------------------------------------------------
f=Libraries/LibWebView/Application.cpp
if grep -q 'TRY(launch_compositor_process());' "$f" && ! grep -q 'iOS M0: Compositor deferred' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace(
"""    TRY(launch_request_server());
    TRY(launch_image_decoder_server());
    TRY(launch_compositor_process());""",
"""    TRY(launch_request_server());
    TRY(launch_image_decoder_server());
#if !defined(AK_OS_IOS)  // iOS M0: Compositor deferred (GPU/ANGLE); headless raster needs no present helper
    TRY(launch_compositor_process());
#endif""")
open(p,"w").write(s)
print("  [m0-patch] Application.cpp: launch_compositor_process gated off for iOS")
PY
else
  say "launch_services compositor gate: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 14) Headless driver. Upstream removed the standalone headless binary; WebView::Application already
#     carries the full headless machinery (`--headless screenshot --screenshot-path P url` ->
#     Application::execute() creates a HeadlessWebView, loads the URL, PNG-dumps via
#     ViewImplementation::take_screenshot, and exits). So the M0 driver is a ~15-line subclass +
#     ladybird_main that calls create()+execute(). Emitted as Services/HeadlessShot/headless-shot
#     (bin/), links LibWebView + LibWeb + the four helper client libs.
# ---------------------------------------------------------------------------------------------
d=Services/HeadlessShot
if [ ! -f "$d/main.cpp" ]; then
  mkdir -p "$d"
  cat > "$d/main.cpp" <<'EOF'
/*
 * Ladybird-on-iOS M0 headless driver.
 *
 * WebView::Application already implements the entire headless screenshot flow in execute()
 * (HeadlessMode::Screenshot -> load URL -> take_screenshot -> PNG -> quit). This is the minimal
 * binary that wires it up. Invoke on device as:
 *   headless-shot --headless screenshot --screenshot-path /var/jb/tmp/out.png https://example.com
 */
#include <LibMain/Main.h>
#include <LibWebView/Application.h>

namespace HeadlessShot {

class Application final : public WebView::Application {
    WEB_VIEW_APPLICATION(Application)
public:
    Application() = default;
};

}

ErrorOr<int> ladybird_main(Main::Arguments arguments)
{
    auto app = TRY(HeadlessShot::Application::create(arguments));
    return app->execute();
}
EOF
  cat > "$d/CMakeLists.txt" <<'EOF'
# M0 headless PNG driver. Mirrors test-web's link set (minus the test-only libs). It depends on the
# helper processes so they build alongside. The resource-copy target (ladybird_build_resource_files)
# lives in UI/, which is skipped on iOS (patch 6) -> guard the dependency; the driver packaging step
# stages resources straight from Base/res into share/Lagom.
add_executable(headless-shot main.cpp)
if (TARGET ladybird_build_resource_files)
    add_dependencies(headless-shot ladybird_build_resource_files)
endif()
add_dependencies(headless-shot ${ladybird_helper_processes})
target_link_libraries(headless-shot PRIVATE
    AK LibCore LibFileSystem LibGfx LibImageDecoders LibImageDecoderClient
    LibIPC LibJS LibMain LibRequests LibURL LibWeb LibWebView)
EOF
  say "HeadlessShot: driver source created"
else
  say "HeadlessShot: driver source already present"
fi
f=Services/CMakeLists.txt
if ! grep -q 'add_subdirectory(HeadlessShot)' "$f"; then
  # add before the NOT IOS block so it builds on iOS (it is our M0 headless frontend)
  printf 'add_subdirectory(HeadlessShot)\n' >> "$f"
  say "Services: HeadlessShot added to build"
else
  say "Services: HeadlessShot already in build"
fi

# ---------------------------------------------------------------------------------------------
# 15) LibGfx TypefaceSkia: font-manager selection. USE_FONTCONFIG=1 is defined (fontconfig found),
#     so the non-Android/Windows branch calls SkFontMgr_New_FontConfig -- which our Apple Skia build
#     (skia_use_fontconfig=false) does NOT provide (undefined symbol at WebContent/WebWorker link).
#     Our libskia DOES provide SkFontMgr_New_CoreText (CoreText is on iOS). Route iOS to CoreText:
#     add the CoreText fontmgr include + selection for iOS, and drop the fontconfig call from the iOS
#     compile so its symbol is not referenced. (The macOS-only CGFont/AppKit typeface paths stay
#     macOS-gated; iOS just needs the CoreText SkFontMgr for text to render.)
# ---------------------------------------------------------------------------------------------
f=Libraries/LibGfx/Font/TypefaceSkia.cpp
if ! grep -q 'iOS: CoreText SkFontMgr' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
# 1) include the CoreText fontmgr header on iOS (SkFontMgr_New_CoreText declaration).
s=s.replace(
"""#ifdef AK_OS_MACOS
#    include <CoreText/CoreText.h>
#    include <harfbuzz/hb-coretext.h>
#    include <ports/SkFontMgr_mac_ct.h>
#    include <ports/SkTypeface_mac.h>
#endif""",
"""#ifdef AK_OS_MACOS
#    include <CoreText/CoreText.h>
#    include <harfbuzz/hb-coretext.h>
#    include <ports/SkFontMgr_mac_ct.h>
#    include <ports/SkTypeface_mac.h>
#endif
#ifdef AK_OS_IOS  // iOS: CoreText SkFontMgr (Apple Skia has no fontconfig fontmgr)
#    include <CoreText/CoreText.h>
#    include <ports/SkFontMgr_mac_ct.h>
#endif""")
# 2) select CoreText on iOS as well.
s=s.replace(
"""#ifdef AK_OS_MACOS
        if (Gfx::FontDatabase::the().system_font_provider_name() != "FontConfig"sv) {
            font_manager = SkFontMgr_New_CoreText(nullptr);
        }
#endif""",
"""#if defined(AK_OS_MACOS) || defined(AK_OS_IOS)
        if (Gfx::FontDatabase::the().system_font_provider_name() != "FontConfig"sv) {
            font_manager = SkFontMgr_New_CoreText(nullptr);
        }
#endif""")
# 3) do not compile the fontconfig SkFontMgr call on iOS (its symbol is absent from libskia).
s=s.replace(
"""#if defined(AK_OS_ANDROID)
        font_manager = SkFontMgr_New_Android(nullptr);
#elif defined(AK_OS_WINDOWS)
        font_manager = SkFontMgr_New_DirectWrite();
#else
        if (!font_manager) {
            font_manager = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
        }
#endif""",
"""#if defined(AK_OS_ANDROID)
        font_manager = SkFontMgr_New_Android(nullptr);
#elif defined(AK_OS_WINDOWS)
        font_manager = SkFontMgr_New_DirectWrite();
#elif defined(AK_OS_IOS)
        // iOS: CoreText SkFontMgr selected above; Apple Skia build has no fontconfig fontmgr.
#else
        if (!font_manager) {
            font_manager = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
        }
#endif""")
open(p,"w").write(s)
print("  [m0-patch] TypefaceSkia.cpp: iOS uses SkFontMgr_New_CoreText (fontconfig fontmgr dropped)")
PY
else
  say "TypefaceSkia CoreText: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 16) THE PAINT FIX. In this commit all rasterization (incl. screenshots) was moved into the
#     separate Compositor process: WebContent only records a display list and ships it over IPC;
#     LocalNavigable::render_screenshot forwards to compositor_context().request_screenshot(), which
#     (with no Compositor process on iOS -> null CompositorConnection) immediately fires the callback
#     with an EMPTY bitmap -> the fully-transparent M0 screenshots. The compositor host itself is
#     created unconditionally (WebContentCompositorHost) and ~19 mostly-unguarded compositor_context()
#     call sites during load mean we CANNOT simply drop the host. Fix (bounded, in-process, no GPU/
#     ANGLE/5th-process): on iOS, record the display list locally and CPU-raster it straight into the
#     target PaintingSurface via a backend-less (raster) DisplayListPlayerSkia -- exactly what the
#     Compositor's ContextState::paint_screenshot does under --force-cpu-painting, but inside WebContent.
#     WebContent never calls initialize_gpu_backend, so the_main_thread_context() is null -> CPU raster.
# ---------------------------------------------------------------------------------------------
f=Libraries/LibWeb/HTML/LocalNavigable.cpp
if ! grep -q 'iOS M0: no Compositor process is launched' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
# a) include the raster player header (LocalNavigable.cpp already pulls Paintable/PaintableBox/
#    ViewportPaintable + PaintingSurface; add the Skia display-list player).
anchor='#include <LibWeb/Painting/ViewportPaintable.h>'
assert anchor in s, "ViewportPaintable include anchor not found (upstream drift?)"
s=s.replace(anchor, anchor+'\n#include <LibWeb/Painting/DisplayListPlayerSkia.h>',1)
# b) replace the whole render_screenshot body with an iOS in-process CPU-raster path (non-iOS
#    keeps the upstream compositor-forward path verbatim).
old='''void LocalNavigable::render_screenshot(Gfx::PaintingSurface& painting_surface, PaintConfig paint_config, Function<void()>&& callback)
{
    if (!has_compositor_context()) {
        callback();
        return;
    }

    if (!record_display_list_and_scroll_state(paint_config)) {
        callback();
        return;
    }
    compositor_context().request_screenshot(painting_surface, move(callback));
}'''
assert old in s, "render_screenshot body not found (upstream drift?)"
new='''void LocalNavigable::render_screenshot(Gfx::PaintingSurface& painting_surface, PaintConfig paint_config, Function<void()>&& callback)
{
#if defined(AK_OS_IOS)
    // iOS M0: no Compositor process is launched (GPU/ANGLE deferred). Forwarding to a non-existent
    // compositor yields a blank bitmap, so record the display list locally and CPU-raster it straight
    // into the target surface with a backend-less (raster) Skia player -- the in-process equivalent of
    // Compositor ContextState::paint_screenshot under --force-cpu-painting.
    auto document = active_document();
    if (!document) {
        callback();
        return;
    }
    document->update_paint_and_hit_testing_properties_if_needed();
    auto display_list = document->record_display_list(paint_config, m_display_list_resource_storage);
    if (!display_list) {
        callback();
        return;
    }
    auto document_paintable = document->paintable();
    VERIFY(document_paintable);
    document_paintable->refresh_scroll_state();
    Painting::ScrollStateSnapshot scroll_state_snapshot { document_paintable->scroll_state_snapshot() };
    Painting::DisplayListPlayerSkia player; // WebContent has no GPU backend -> CPU raster
    player.execute(*display_list, document_paintable->visual_context_tree(),
        m_display_list_resource_storage, scroll_state_snapshot,
        painting_surface, nullptr, nullptr);
    player.flush(painting_surface);
    callback();
    return;
#else
    if (!has_compositor_context()) {
        callback();
        return;
    }

    if (!record_display_list_and_scroll_state(paint_config)) {
        callback();
        return;
    }
    compositor_context().request_screenshot(painting_surface, move(callback));
#endif
}'''
s=s.replace(old,new)
open(p,"w").write(s)
print("  [m0-patch] LocalNavigable.cpp: iOS render_screenshot CPU-rasters in-process (real pixels)")
PY
else
  say "render_screenshot iOS CPU raster: already patched"
fi

# ---------------------------------------------------------------------------------------------
# 17) Compositor-gate completion (companion to patch 13). create_web_content_client() calls
#     connect_web_content_to_compositor(*client), which returns "Compositor process is not available"
#     when no Compositor was launched -> the TRY() propagates and client creation fails (the observed
#     "Compositor not available" SIGTRAP). Gate that one call off for iOS; patch 16 makes the compositor
#     connection unnecessary for the headless screenshot path.
# ---------------------------------------------------------------------------------------------
f=Libraries/LibWebView/Application.cpp
if grep -q 'TRY(Application::the().connect_web_content_to_compositor(\*client));' "$f" && ! grep -q 'iOS M0: no compositor process to connect' "$f"; then
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="    TRY(Application::the().connect_web_content_to_compositor(*client));"
new="""#if !defined(AK_OS_IOS)  // iOS M0: no compositor process to connect to (patch 13/16)
    TRY(Application::the().connect_web_content_to_compositor(*client));
#endif"""
assert old in s, "connect_web_content_to_compositor call not found (upstream drift?)"
s=s.replace(old,new)
open(p,"w").write(s)
print("  [m0-patch] Application.cpp: connect_web_content_to_compositor gated off for iOS")
PY
else
  say "connect_web_content_to_compositor gate: already patched"
fi

# =============================================================================================
# 18) APP-BUILD MODE (LB_APP_BUILD=1 only). The interactive UIKit .app uses the NORMAL compositor
#     paint cycle, NOT the headless render_screenshot path (patch 16). At 92b0257 the frontend's
#     m_client_state.front_bitmap is filled ONLY by CompositorClient (IPC callbacks from a live
#     Compositor process): WebContent records a display list -> Compositor CPU-rasters into a
#     ShareableBitmap backing store -> ships it to the UI -> server_did_paint -> on_ready_to_paint.
#     With no Compositor process the window is blank. So for the app we re-enable the Compositor as
#     a 5th CPU helper (upstream-shaped; the iOS non-MACOS shared-image transport is ShareableBitmap/
#     AnonymousBuffer over SCM_RIGHTS fds, already portable; NO IOSurface/GPU). This REVERSES the
#     headless gates (patches 8/12/13/17) for iOS and forces CPU painting. Also wires UI/iOS in.
#     Guarded by LB_APP_BUILD so the headless deb build (patches only 1-17) is unaffected.
# =============================================================================================
if [ "${LB_APP_BUILD:-0}" = "1" ]; then
  say "APP-BUILD MODE: re-enabling CPU Compositor + wiring UI/iOS"

  # a) Services/CMakeLists.txt: build Compositor on iOS (reverse patch 8). The headless patch
  #    guarded BOTH Compositor + WebDriver under `if (NOT IOS)`; pull Compositor OUT of the guard
  #    (WebDriver stays deferred).
  f=Services/CMakeLists.txt
  if ! grep -qE '^add_subdirectory\(Compositor\)' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="""if (NOT IOS)
    add_subdirectory(Compositor)
    add_subdirectory(WebDriver)
endif()"""
new="""add_subdirectory(Compositor)
if (NOT IOS)
    add_subdirectory(WebDriver)
endif()"""
if old in s:
    s=s.replace(old,new)
elif "add_subdirectory(Compositor)" in s:
    # already partially edited form: just ensure Compositor is unguarded
    s=s.replace("if (NOT IOS)\n    add_subdirectory(Compositor)","add_subdirectory(Compositor)\nif (NOT IOS)")
open(p,"w").write(s)
print("  [m0-patch] Services/CMakeLists.txt: Compositor unguarded on iOS (app mode)")
PY
  fi

  # a2) Services/Compositor/CMakeLists.txt: the sandbox source is chosen `elseif (APPLE)`, which
  #     picks SandboxMacOS.cpp on iOS too — but that file uses macOS-only Seatbelt symbols
  #     (Sandbox::add_seatbelt_path_if_exists / Sandbox::SeatbeltPath) that don't exist here.
  #     Mirror the WebContent helper: `elseif (APPLE AND NOT IOS)` so iOS falls to
  #     SandboxUnimplemented.cpp (Seatbelt is unavailable for fakesigned apps anyway).
  f=Services/Compositor/CMakeLists.txt
  if grep -qE '^elseif \(APPLE\)$' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("elseif (APPLE)\n    target_sources(Compositor PRIVATE SandboxMacOS.cpp)",
            "elseif (APPLE AND NOT IOS)\n    target_sources(Compositor PRIVATE SandboxMacOS.cpp)",1)
open(p,"w").write(s)
print("  [m0-patch] Services/Compositor: SandboxMacOS gated APPLE AND NOT IOS (app mode)")
PY
  fi

  # b) ladybird_helper_processes.cmake: add Compositor back to the helper list.
  f=Meta/CMake/ladybird_helper_processes.cmake
  if ! grep -q '^    Compositor' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("set(ladybird_helper_processes\n","set(ladybird_helper_processes\n    Compositor\n")
open(p,"w").write(s)
print("  [m0-patch] ladybird_helper_processes.cmake: Compositor re-added (app mode)")
PY
  fi

  # c) Application.cpp: reverse patch 13 (launch) + patch 17 (connect) iOS gates.
  f=Libraries/LibWebView/Application.cpp
  python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
changed=False
# patch-13 form: gate wrapping launch_compositor_process()
for g in [
  ("#if !defined(AK_OS_IOS)  // iOS M0: Compositor deferred (GPU/ANGLE); headless raster needs no present helper\n    TRY(launch_compositor_process());\n#endif",
   "    TRY(launch_compositor_process());"),
  ("#if !defined(AK_OS_IOS)  // iOS M0: no compositor process to connect to (patch 13/16)\n    TRY(Application::the().connect_web_content_to_compositor(*client));\n#endif",
   "    TRY(Application::the().connect_web_content_to_compositor(*client));"),
]:
    if g[0] in s:
        s=s.replace(g[0],g[1]); changed=True
# d) force CPU painting on iOS (both WebContent + Compositor pick it up; Compositor arg appends
#    --force-cpu-painting from web_content_options). Insert right after create_platform_options().
anchor="create_platform_options(m_browser_options, m_request_server_options, m_web_content_options);"
inject=anchor+"\n\n#if defined(AK_OS_IOS)\n    // iOS app: no GPU/ANGLE backend -> CPU (Skia) painting in WebContent AND the Compositor.\n    m_web_content_options.force_cpu_painting = ForceCPUPainting::Yes;\n#endif"
if anchor in s and "iOS app: no GPU/ANGLE backend" not in s:
    s=s.replace(anchor,inject,1); changed=True
open(p,"w").write(s)
print("  [m0-patch] Application.cpp: launch/connect ungated + CPU painting forced (app mode)" if changed
      else "  [m0-patch] Application.cpp: app-mode gates already applied")
PY

  # e) top-level CMakeLists.txt: add the UIKit frontend subdir on iOS.
  f=CMakeLists.txt
  if ! grep -q 'add_subdirectory(UI/iOS)' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="""    if (NOT IOS)  # iOS: skip UI (no AppKit/UIKit frontend at M0)
        add_subdirectory(UI)
    endif()"""
repl="""    if (NOT IOS)  # iOS: skip AppKit/Qt UI
        add_subdirectory(UI)
    else()          # iOS app build: our UIKit frontend (m0-patch 18)
        add_subdirectory(UI/iOS)
    endif()"""
assert anchor in s, "UI add_subdirectory guard not found (patch order?)"
s=s.replace(anchor,repl)
open(p,"w").write(s)
print("  [m0-patch] CMakeLists.txt: add_subdirectory(UI/iOS) on iOS (app mode)")
PY
  fi

  # f) Compositor egl/gl link stub: the Compositor executable references ANGLE EGL/GLES entry
  #    points (OpenGLContext.cpp + WebGL replayer) that only run for WebGL/GPU present. Under
  #    --force-cpu-painting they are never called, but must resolve at link. angle.pc has empty
  #    Libs, so we add a self-contained stub TU (trap-if-called) to compositorservice on iOS.
  f=Services/Compositor/CMakeLists.txt
  if ! grep -q 'AngleStubIOS.cpp' "$f"; then
    cat > Services/Compositor/AngleStubIOS.cpp <<'STUB'
// iOS app build (m0-patch 18): trap-if-called stubs for the ANGLE EGL/GLES entry points the
// Compositor references but never calls under --force-cpu-painting (WebGL/GPU present is off).
// The concrete symbol list is generated by the build driver from the first link's undefined
// symbols and appended below between the GEN markers. Keeping the mechanism in-tree keeps the
// Compositor self-contained (no external ANGLE dylib in the closure).
extern "C" {
// __LB_ANGLE_STUBS_BEGIN__
// __LB_ANGLE_STUBS_END__
}
STUB
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("set(SOURCES\n","set(SOURCES\n    AngleStubIOS.cpp\n",1)
open(p,"w").write(s)
print("  [m0-patch] Services/Compositor: AngleStubIOS.cpp added (app mode; driver fills symbols)")
PY
  fi

  # g) DEBUG: engine-side boot checkpoints in Application::initialize() so on-device bring-up can
  #    see how far the (clean-exit, no-crash) launch gets past the frontend's boot: enter trace.
  #    Writes to the same /var/jb/tmp/ladybird-boot.log. Temporary; remove once app is validated.
  f=Libraries/LibWebView/Application.cpp
  if ! grep -q 'LB_ENG_TRACE' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
# NOTE: real newlines below (no \n escapes); the fprintf format keeps a literal backslash-n via r"..."
helper = (
    "\n#if defined(AK_OS_IOS)\n"
    "#    include <cstdio>\n"
    '#    define LB_ENG_TRACE(msg) do { FILE* _f = fopen("/var/jb/tmp/ladybird-boot.log", "a"); '
    'if (_f) { fprintf(_f, ' + r'"[eng] %s\n"' + ', msg); fclose(_f); } } while (0)\n'
    "#else\n"
    "#    define LB_ENG_TRACE(msg) do {} while (0)\n"
    "#endif\n"
)
anchor = "ErrorOr<void> Application::initialize(Main::Arguments const& arguments)\n{"
assert anchor in s, "initialize() anchor not found"
# Define the macro BEFORE the constructor (which is earlier in the file than initialize()).
ctor_anchor = "Application::Application(Optional<ByteString> ladybird_binary_path)"
assert ctor_anchor in s, "ctor anchor not found"
s = s.replace(ctor_anchor, helper + "\n" + ctor_anchor, 1)
# init-enter (first thing inside initialize) + constructor trace to bisect ctor vs initialize.
s = s.replace(anchor, anchor + '\n    LB_ENG_TRACE("init-enter");', 1)
s = s.replace("    platform_init(move(ladybird_binary_path));",
              '    LB_ENG_TRACE("ctor: pre-platform_init");\n    platform_init(move(ladybird_binary_path));\n    LB_ENG_TRACE("ctor: post-platform_init");', 1)
s = s.replace("    TRY(handle_attached_debugger());\n    m_arguments = arguments;",
              '    LB_ENG_TRACE("init: pre-handle_attached_debugger");\n    TRY(handle_attached_debugger());\n    m_arguments = arguments;\n    LB_ENG_TRACE("init: post-debugger+args");', 1)

def wrap(call, label):
    global s
    s = s.replace(call, 'LB_ENG_TRACE("pre-%s");\n    %s\n    LB_ENG_TRACE("post-%s");' % (label, call, label), 1)

wrap("args_parser.parse(m_arguments);", "parse")
wrap("create_platform_options(m_browser_options, m_request_server_options, m_web_content_options);", "create_platform_options")
wrap("m_event_loop = &create_platform_event_loop();", "create_platform_event_loop")
wrap("TRY(launch_services());", "launch_services")
open(p, "w").write(s)
print("  [m0-patch] Application.cpp: LB_ENG_TRACE boot checkpoints injected (app mode debug)")
PY
  fi
fi

echo "  [m0-patch] all M0 patches applied."
