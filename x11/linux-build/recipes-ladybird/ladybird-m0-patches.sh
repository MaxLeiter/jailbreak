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

patch_semantically_applied() {
  local patch_name="$1"

  case "$patch_name" in
    0001-ios-m0-sandbox-and-libedit-gates.patch)
      grep -q 'NOT WIN32 AND NOT ANDROID AND NOT IOS' Meta/CMake/check_for_dependencies.cmake &&
        grep -q 'APPLE AND NOT IOS' Services/ImageDecoder/CMakeLists.txt &&
        grep -q 'APPLE AND NOT IOS' Services/RequestServer/CMakeLists.txt &&
        grep -q 'APPLE AND NOT IOS' Services/WebContent/CMakeLists.txt &&
        grep -q 'APPLE AND NOT IOS' Services/WebWorker/CMakeLists.txt
      ;;
    0002-ios-m0-drop-avif-jpegxl-decoders.patch)
      # Old cached build trees can have this patch's code changes plus later
      # dependency-patch context drift, making both forward and reverse dry-runs
      # fail. The compile definition is the durable marker that the decoder gate
      # is already active.
      grep -q 'LADYBIRD_M0_NO_JXL_AVIF' Libraries/LibImageDecoders/CMakeLists.txt &&
        grep -q 'LADYBIRD_M0_NO_JXL_AVIF' Libraries/LibGfx/ImageFormats/ImageDecoder.cpp
      ;;
    0003-ios-m0-helper-build-graph.patch)
      grep -q 'Compositor deferred' Meta/CMake/ladybird_helper_processes.cmake &&
        grep -q 'iOS M0 helper set' Services/CMakeLists.txt
      ;;
    0004-ios-m0-darwin-source-gates.patch)
      grep -q 'AK_OS_MACOS) || defined(AK_OS_IOS)' Libraries/LibThreading/Thread.cpp &&
        grep -q 'AK_OS_MACOS) || defined(AK_OS_IOS)' Libraries/LibWasm/AbstractMachine/BytecodeInterpreter.cpp
      ;;
    0005-ios-m0-libjs-host-asm-tools.patch)
      grep -q 'LB_HOST_GEN_ASM_OFFSETS' Libraries/LibJS/CMakeLists.txt &&
        grep -q 'LB_HOST_ASMINTGEN' Libraries/LibJS/CMakeLists.txt
      ;;
    0006-ios-m0-webview-compositor-gates.patch)
      grep -q 'iOS M0: no compositor process to connect' Libraries/LibWebView/Application.cpp ||
        grep -q 'add_subdirectory(UI/iOS)' CMakeLists.txt
      ;;
    0007-ios-m0-headless-shot-driver.patch)
      [ -f Services/HeadlessShot/main.cpp ] &&
        grep -q 'add_subdirectory(HeadlessShot)' Services/CMakeLists.txt
      ;;
    0008-ios-m0-typeface-skia-coretext.patch)
      grep -q 'iOS: CoreText SkFontMgr' Libraries/LibGfx/Font/TypefaceSkia.cpp
      ;;
    0009-ios-m0-localnavigable-screenshot-raster.patch)
      grep -q 'DisplayListPlayerSkia' Libraries/LibWeb/HTML/LocalNavigable.cpp &&
        grep -q 'iOS M0: no Compositor process is launched' Libraries/LibWeb/HTML/LocalNavigable.cpp
      ;;
    ios-app-build-graph.patch)
      grep -q 'add_subdirectory(UI/iOS)' CMakeLists.txt &&
        grep -q 'duplicate create_context is a no-op' Services/Compositor/CompositorState.cpp
      ;;
    ios-app-cpu-fallback.patch)
      (grep -q 'LADYBIRD_IOS_CPU_DIAGNOSTIC' Libraries/LibWebView/Application.cpp ||
        grep -q 'LADYBIRD_IOS_APP_GPU' Libraries/LibWebView/Application.cpp) &&
        [ -f Services/Compositor/AngleStubIOS.cpp ]
      ;;
    iosurface-mach-ipc.patch)
      grep -q 'TransportMachPort is only available on Mach platforms' Libraries/LibIPC/TransportMachPort.h &&
        grep -q 'AK_OS_MACOS) || defined(AK_OS_IOS)' Libraries/LibGfx/SharedImageBuffer.h
      ;;
    ios-app-input-caret-after-events.patch)
      grep -q 'software keyboard handoff needs a fresh editable-caret signal' Services/WebContent/PageClient.cpp
      ;;
    ios-app-input-caret-pageclient-access.patch)
      grep -q 'friend class PageClient' Services/WebContent/ConnectionFromClient.h
      ;;
    ios-app-real-angle-pkgconfig.patch)
      grep -Eq 'The iOS app (GPU probe|release build) uses (the )?Procursus-staged ANGLE' \
        Meta/CMake/check_for_dependencies.cmake
      ;;
    ios-app-angle-compat.patch)
      [ -f Services/Compositor/AngleCompatIOS.cpp ] &&
        grep -q 'glBindVertexArrayOES' Services/Compositor/AngleCompatIOS.cpp
      ;;
    ios-app-webgl-ios-enable.patch)
      grep -q 'ladybird-webgl.log' Services/Compositor/OpenGLContext.cpp &&
        grep -q 'eglBindAPI GLES' Services/Compositor/OpenGLContext.cpp &&
        grep -q 'framebuffer before check' Services/Compositor/OpenGLContext.cpp &&
        grep -q 'AK_OS_MACOS) || defined(AK_OS_IOS)' Services/Compositor/OpenGLContext.h
      ;;
    ios-app-webgl-release-cleanup.patch)
      grep -q 'LADYBIRD_WEBGL_TRACE' Services/Compositor/OpenGLContext.cpp &&
        grep -q 'ladybird-webgl-trace' Services/Compositor/CanvasHost.cpp &&
        grep -q 'leaving WebGL context without a drawing buffer' Services/Compositor/OpenGLContext.cpp
      ;;
    ios-wayland-gtk-frontend.patch)
      grep -q 'LADYBIRD_IOS_DESKTOP_FRONTEND' CMakeLists.txt &&
        grep -q 'APPLE AND NOT IOS' UI/CMakeLists.txt &&
        grep -q 'TARGET WebDriver AND NOT WIN32' UI/CMakeLists.txt &&
        grep -q 'NO_CMAKE_FIND_ROOT_PATH' UI/Gtk/CMakeLists.txt &&
        grep -q 'NOT APPLE OR IOS' UI/cmake/InstallRules.cmake &&
        grep -q 'APPLE AND NOT IOS' UI/cmake/ResourceFiles.cmake
      ;;
    ios-gtk-4-14-memory-texture.patch)
      grep -q 'GTK_CHECK_VERSION(4, 16, 0)' UI/Gtk/WebContentView.cpp &&
        grep -q 'gdk_memory_texture_new(painted_width' UI/Gtk/WebContentView.cpp
      ;;
    ios-desktop-mach-bootstrap.patch)
      grep -q 'defined(AK_OS_MACOS) || defined(AK_OS_IOS)' Libraries/LibWebView/Application.cpp &&
        grep -q '(void)request.task_port' Libraries/LibWebView/Application.cpp &&
        grep -q 'set_browser_process_transport_handler' Libraries/LibWebView/Application.cpp
      ;;
    *)
      return 1
      ;;
  esac
}

apply_quilt_series() {
  local patch_dir="$1"
  local series="$patch_dir/series"
  [ -f "$series" ] || return 0

  series_semantically_applied() {
    local patch_name patch_file
    while IFS= read -r patch_name; do
      patch_name="${patch_name%%#*}"
      patch_name="${patch_name## }"
      patch_name="${patch_name%% }"
      [ -n "$patch_name" ] || continue
      patch_file="$patch_dir/$patch_name"
      [ -f "$patch_file" ] || return 1
      patch_semantically_applied "$patch_name" || return 1
    done < "$series"
  }

  series_has_semantic_marker() {
    local patch_name
    while IFS= read -r patch_name; do
      patch_name="${patch_name%%#*}"
      patch_name="${patch_name## }"
      patch_name="${patch_name%% }"
      [ -n "$patch_name" ] || continue
      patch_semantically_applied "$patch_name" && return 0
    done < "$series"
    return 1
  }

  apply_with_patch() {
    local patch_name patch_file
    while IFS= read -r patch_name; do
      patch_name="${patch_name%%#*}"
      patch_name="${patch_name## }"
      patch_name="${patch_name%% }"
      [ -n "$patch_name" ] || continue
      patch_file="$patch_dir/$patch_name"
      if patch_semantically_applied "$patch_name"; then
        say "quilt fallback: $patch_name already applied (semantic marker)"
      elif patch -p1 --dry-run -f < "$patch_file" >/dev/null 2>&1; then
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

  if series_semantically_applied; then
    say "quilt: $patch_dir already applied (semantic markers)"
    return 0
  fi

  if command -v quilt >/dev/null 2>&1 && ! series_has_semantic_marker; then
    QUILT_PATCHES="$patch_dir" quilt push -a || {
      # Idempotent reruns can land here when every patch in the series is already applied.
      QUILT_PATCHES="$patch_dir" quilt applied >/dev/null 2>&1 && return 0
      series_semantically_applied && {
        say "quilt: $patch_dir already applied (semantic markers)"
        return 0
      }
      return 1
    }
    return 0
  fi

  apply_with_patch
}

# Common M0 source patches that are needed by both headless and app builds.
apply_quilt_series "$SCRIPT_DIR/patches-m0"

# =============================================================================================
# APP-BUILD MODE (LB_APP_BUILD=1 only). The interactive UIKit .app uses the NORMAL compositor
#     paint cycle, NOT the headless render_screenshot path. At 92b0257 the frontend's
#     m_client_state.front_bitmap is filled ONLY by CompositorClient (IPC callbacks from a live
#     Compositor process): WebContent records a display list -> Compositor paints into an
#     ShareableBitmap backing store -> ships it to the UI -> server_did_paint -> on_ready_to_paint.
#     With no Compositor process the window is blank. So for the app we re-enable the Compositor as
#     a 5th helper and carry its IOSurface-backed image over Mach IPC. This applies the
#     app-only patch stack to reverse headless Compositor gates for iOS and wire UI/iOS in.
#     Guarded by LB_APP_BUILD so the headless deb build only applies patches-m0.
# =============================================================================================
if [ "${LB_APP_BUILD:-0}" = "1" ]; then
  say "APP-BUILD MODE: re-enabling Compositor + wiring UI/iOS"

  # Cached trees from early WebGL bring-up can contain an older partial version of the
  # iOS WebGL patch. Reset only the files owned by that patch so the final quilt patch
  # applies cleanly while leaving the rest of the warmed tree intact.
  if [ -d .git ] &&
     grep -q 'ladybird-webgl.log' Services/Compositor/OpenGLContext.cpp 2>/dev/null &&
     ! grep -q 'eglBindAPI GLES' Services/Compositor/OpenGLContext.cpp 2>/dev/null; then
    git checkout -- \
      Services/Compositor/CanvasHost.cpp \
      Services/Compositor/OpenGLContext.cpp \
      Services/Compositor/OpenGLContext.h
    say "reset stale partial iOS WebGL patch before app series"
  fi
  if [ -d .git ] &&
     grep -q 'LADYBIRD_WEBGL_TRACE' Services/Compositor/OpenGLContext.cpp 2>/dev/null &&
     ! grep -q 'leaving WebGL context without a drawing buffer' Services/Compositor/OpenGLContext.cpp 2>/dev/null; then
    git checkout -- \
      Services/Compositor/CanvasHost.cpp \
      Services/Compositor/OpenGLContext.cpp \
      Services/Compositor/OpenGLContext.h
    say "reset stale partial iOS WebGL cleanup patch before app series"
  fi

  # App-only engine patch series for compositor/UI wiring and IOSurface/Mach transport.
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

fi

echo "  [m0-patch] all M0 patches applied."
