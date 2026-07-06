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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: ladybird-m0-patches.sh <ladybird-source-dir>}"
cd "$SRC"

say() { echo "  [m0-patch] $*"; }
truthy() {
  case "${1:-}" in
    1|yes|true|on|YES|TRUE|ON) return 0 ;;
    *) return 1 ;;
  esac
}

apply_quilt_series() {
  local patch_dir="$1"
  local series="$patch_dir/series"
  [ -f "$series" ] || return 0

  if command -v quilt >/dev/null 2>&1; then
    QUILT_PATCHES="$patch_dir" quilt push -a || {
      # Idempotent reruns can land here when every patch in the series is already applied.
      QUILT_PATCHES="$patch_dir" quilt applied >/dev/null 2>&1 && return 0
      return 1
    }
    return 0
  fi

  while IFS= read -r patch_name; do
    patch_name="${patch_name%%#*}"
    patch_name="${patch_name## }"
    patch_name="${patch_name%% }"
    [ -n "$patch_name" ] || continue
    local patch_file="$patch_dir/$patch_name"
    if patch -p1 --dry-run -f < "$patch_file" >/dev/null 2>&1; then
      patch -p1 < "$patch_file"
      say "quilt fallback: applied $patch_name"
    elif patch -p1 -R --dry-run -f < "$patch_file" >/dev/null 2>&1; then
      say "quilt fallback: $patch_name already applied"
    else
      echo "failed to apply $patch_file" >&2
      return 1
    fi
  done < "$series"
}

# Common M0 source patches that are needed by both headless and app builds.
apply_quilt_series "$SCRIPT_DIR/patches-m0"

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
import os, sys
p=sys.argv[1]; s=open(p).read()
changed=False
gpu_enabled = os.environ.get("LB_APP_GPU", "").lower() in ("1", "yes", "true", "on")
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
cpu_block="\n\n#if defined(AK_OS_IOS)\n    // iOS app: no GPU/ANGLE backend -> CPU (Skia) painting in WebContent AND the Compositor.\n    m_web_content_options.force_cpu_painting = ForceCPUPainting::Yes;\n#endif"
if gpu_enabled:
    if cpu_block in s:
        s=s.replace(cpu_block,"",1); changed=True
else:
    inject=anchor+cpu_block
    if anchor in s and "iOS app: no GPU/ANGLE backend" not in s:
        s=s.replace(anchor,inject,1); changed=True
open(p,"w").write(s)
if changed:
    print("  [m0-patch] Application.cpp: launch/connect ungated + " + ("GPU painting allowed (app mode)" if gpu_enabled else "CPU painting forced (app mode)"))
else:
    print("  [m0-patch] Application.cpp: app-mode gates already applied" + (" (GPU painting allowed)" if gpu_enabled else ""))
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

  # f) Compositor egl/gl link stub: the CPU app path references ANGLE EGL/GLES entry points
  #    (OpenGLContext.cpp + WebGL replayer) that are never called under --force-cpu-painting.
  #    The GPU probe path links real EGL/GLES dylibs instead, so remove the stub if the same
  #    tree is being flipped from CPU to GPU mode.
  f=Services/Compositor/CMakeLists.txt
  if truthy "${LB_APP_GPU:-0}"; then
    if grep -q 'AngleStubIOS.cpp' "$f"; then
      python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("    AngleStubIOS.cpp\n", "")
open(p,"w").write(s)
print("  [m0-patch] Services/Compositor: AngleStubIOS.cpp removed (GPU app mode)")
PY
    fi
    rm -f Services/Compositor/AngleStubIOS.cpp
  elif ! grep -q 'AngleStubIOS.cpp' "$f"; then
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

  # g) Quilt-managed engine patch series for the real iOS IOSurface/Mach transport path.
  apply_quilt_series "$SCRIPT_DIR/patches"

  # h) Remove temporary IOSurface allocation diagnostics from reused build trees. The patch was
  #    useful while isolating host-DER signing failures, but release app builds should not write
  #    failure logs under /var/jb/tmp from LibCore.
  f=Libraries/LibCore/IOSurface.cpp
  if grep -q 'ladybird-iosurface.log' "$f"; then
    python3 - "$f" <<'PY'
import re
import sys

p = sys.argv[1]
s = open(p).read()
s = s.replace('\n#include <stdio.h>\n', '\n')
s = re.sub(
    r'\n#if defined\(AK_OS_IOS\)\n'
    r'    if \(!ref\) \{\n'
    r'        FILE\* f = fopen\("/var/jb/tmp/ladybird-iosurface\.log", "a"\);\n'
    r'        if \(f\) \{\n'
    r'            fprintf\(f, "IOSurfaceCreate failed width=%d height=%d bpe=%zu format=0x%08x\\n", width, height, bytes_per_element, pixel_format\);\n'
    r'            fclose\(f\);\n'
    r'        \}\n'
    r'    \}\n'
    r'#endif\n',
    '\n',
    s,
)
blocks = [
'''    if (!ref) {
        if (auto* f = fopen("/var/jb/tmp/ladybird-iosurface.log", "a")) {
            fprintf(f, "IOSurfaceCreate failed width=%d height=%d bpe=%zu format=0x%08x\\n", width, height, bytes_per_element, pixel_format);
            fclose(f);
        }
    }
''',
'''    if (!ref) {
        if (auto* f = fopen("/var/jb/tmp/ladybird-iosurface.log", "a")) {
            fprintf(f, "IOSurfaceCreate failed width=%d height=%d bpe=%zu format=0x%08x\n", width, height, bytes_per_element, pixel_format);
            fclose(f);
        }
    }
''',
]
for block in blocks:
    s = s.replace(block, "")
open(p, "w").write(s)
print("  [m0-patch] LibCore/IOSurface.cpp: removed temporary IOSurface diagnostics")
PY
  fi

  # i) Remove earlier app-mode bring-up traces. These were useful while first pixels were still
  #    uncertain, but release app builds should not append frame-by-frame logs in /var/jb/tmp.
  f=Libraries/LibWebView/Application.cpp
  if grep -q 'LB_ENG_TRACE' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
start = s.find("\n#if defined(AK_OS_IOS)\n#    include <cstdio>\n#    define LB_ENG_TRACE")
if start != -1:
    end = s.find("#endif\n", start)
    assert end != -1, "LB_ENG_TRACE block unterminated"
    s = s[:start] + "\n" + s[end + len("#endif\n"):]
for line in [
    '    LB_ENG_TRACE("init-enter");\n',
    '    LB_ENG_TRACE("ctor: pre-platform_init");\n',
    '    LB_ENG_TRACE("ctor: post-platform_init");\n',
    '    LB_ENG_TRACE("init: pre-handle_attached_debugger");\n',
    '    LB_ENG_TRACE("init: post-debugger+args");\n',
    'LB_ENG_TRACE("pre-parse");\n    ',
    '\n    LB_ENG_TRACE("post-parse");',
    'LB_ENG_TRACE("pre-create_platform_options");\n    ',
    '\n    LB_ENG_TRACE("post-create_platform_options");',
    'LB_ENG_TRACE("pre-create_platform_event_loop");\n    ',
    '\n    LB_ENG_TRACE("post-create_platform_event_loop");',
    'LB_ENG_TRACE("pre-launch_services");\n    ',
    '\n    LB_ENG_TRACE("post-launch_services");',
]:
    s = s.replace(line, "")
open(p, "w").write(s)
print("  [m0-patch] Application.cpp: removed app-mode boot trace")
PY
  fi

  f=Libraries/LibWebView/ViewImplementation.cpp
  if grep -q 'LB_VIEW_TRACE' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
start = s.find("\n#if defined(AK_OS_IOS)\n#    include <cstdio>\n#    define LB_VIEW_TRACE")
if start != -1:
    end = s.find("#endif\n", start)
    assert end != -1, "LB_VIEW_TRACE block unterminated"
    s = s[:start] + "\n" + s[end + len("#endif\n"):]
for line in [
    '    LB_VIEW_TRACE("handle_resize vp=%dx%d", viewport_size().width(), viewport_size().height());\n',
    '    LB_VIEW_TRACE("server_did_paint id=%d %dx%d", bitmap_id, size.width(), size.height());\n',
    '    LB_VIEW_TRACE("did_allocate_backing_stores front=%d back=%d", front_bitmap_id, back_bitmap_id);\n',
]:
    s = s.replace(line, "")
open(p, "w").write(s)
print("  [m0-patch] ViewImplementation.cpp: removed present-handshake trace")
PY
  fi

  for f in \
    Libraries/LibWeb/HTML/LocalNavigable.cpp \
    Services/WebContent/PageClient.cpp \
    Services/WebContent/CompositorConnection.cpp \
    Services/Compositor/ConnectionFromWebContent.cpp \
    Services/Compositor/CompositorState.cpp
  do
    if grep -q 'LBTRACE' "$f"; then
      python3 - "$f" <<'PY'
import re
import sys

p = sys.argv[1]
s = open(p).read()
s = re.sub(
    r'\n#include <cstdio>\n#define LBTRACE\(\.\.\.\) do \{ FILE\* _lbf = fopen\("/var/jb/tmp/ladybird-boot\.log", "a"\); if \(_lbf\) \{ fprintf\(_lbf, __VA_ARGS__\); fprintf\(_lbf, "\\n"\); fclose\(_lbf\); \} \} while \(0\)\n',
    '\n',
    s)
for line in [
    '        LBTRACE("[wc] frame-timer fired");\n',
    '    LBTRACE("[wc] request_frame active=%d", m_frame_timer->is_active());\n',
    '    LBTRACE("[wc] record_dl enter has_ctx=%d", has_compositor_context());\n',
    '        LBTRACE("[wc] record_dl SHIP update_display_list");\n',
    '    LBTRACE("[wc] paint_next_frame enter has_ctx=%d needs_repaint=%d", has_compositor_context(), m_needs_repaint);\n',
    '    LBTRACE("[wc] paint_next_frame -> present_frame");\n',
    '    LBTRACE("[wc] conn.update_display_list can_send=%d", can_send_message_to_compositor());\n',
    '    LBTRACE("[wc] conn.present_frame can_send=%d", can_send_message_to_compositor());\n',
    '    LBTRACE("[wc] conn.request_rendering_update RECV");\n',
    '    LBTRACE("[cmp] recv update_display_list");\n',
    '    LBTRACE("[cmp] recv present_frame");\n',
    '    LBTRACE("[cmp] present_frame prepared=%d presents_to_client=%d", prepared_frame.has_value(), context.presents_to_client());\n',
    '    LBTRACE("[cmp] did_finish_async_present presents=%d", context->presents_to_client());\n',
    '        LBTRACE("[cmp] SEND did_present_frame");\n',
]:
    s = s.replace(line, '')
open(p, 'w').write(s)
print(f"  [m0-patch] {p}: removed first-paint diagnostic trace")
PY
    fi
  done

  # h) Compositor create_context idempotency (BUG 2 fix). CompositorState::create_context opens
  #    with VERIFY(!m_contexts.contains(context_id)). Under our frontend, the SAME page-based
  #    context_id (== page_id) is registered twice -- once from ViewImplementation::handle_resize
  #    (UI) and once from the WebContent traversable's PagePresentationRegistration::Yes. The
  #    duplicate reaches the Compositor's create_context a second time and trips that VERIFY ->
  #    Compositor SIGTRAP. Its sync CreateContext response then comes back null, so the UI's
  #    Application::register_compositor_context VERIFYs on the null NonnullOwnPtr response (the
  #    observed Ladybird crash in handle_resize). Make a duplicate create_context a no-op on iOS:
  #    keep the existing ContextState (it owns the display list + backing stores); the real
  #    viewport arrives via a separate update_compositor_viewport IPC right after.
  f=Services/Compositor/CompositorState.cpp
  if ! grep -q 'iOS: duplicate create_context is a no-op' "$f"; then
    python3 - "$f" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
anchor = ("void CompositorState::create_context(Web::Compositor::CompositorContextId context_id, "
          "Optional<u64> page_id, CompositorStateWebContentClient& web_content_client)\n{\n")
assert anchor in s, "create_context signature not found (upstream drift?)"
inject = (anchor +
          "#if defined(AK_OS_IOS)\n"
          "    // iOS: duplicate create_context is a no-op (two registration paths reach the same\n"
          "    // page-based context_id; keep the existing ContextState rather than VERIFY-crashing).\n"
          "    if (m_contexts.contains(context_id))\n"
          "        return;\n"
          "#endif\n")
s = s.replace(anchor, inject, 1)
open(p,"w").write(s)
print("  [m0-patch] CompositorState.cpp: create_context idempotent on iOS (app mode)")
PY
  fi

fi

echo "  [m0-patch] all M0 patches applied."
