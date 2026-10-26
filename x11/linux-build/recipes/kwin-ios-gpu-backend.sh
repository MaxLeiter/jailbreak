#!/usr/bin/env bash
# KWin 6.7 GPU path for Xios: ANGLE Metal rendering into IOSurfaces, IOSurface client buffers sampled without a CPU
# copy, brokered Metal fences. Re-port of the 6.1 script against 6.7's architecture, where the nested Wayland backend is
# built from RenderDevice + EglBackend + subsurface layers + EglSwapchain, all of which assume DRM and dmabuf.
#
# How the pieces fit (see kwin-ios-gpu/ for the files this installs):
#   - iosc_gpu_support.{h,cpp}: ANGLE Metal EGL display wrapped in a RenderDevice with NO DrmDevice and NO Vulkan,
#     IOSurface -> GLTexture binding (pbuffer + eglBindTexImage), the IOSurface swapchain allocator, wl_buffer creation
#     for compositor-owned IOSurfaces, Metal acquire fence export/apply.
#   - wayland_egl_backend.{h,cpp}: upstream's file with the dmabuf format negotiation / gbm allocator / native fences
#     replaced by the above. Layers stay WaylandLayer subclasses, so subsurface commit, viewport, damage and frame
#     callbacks are upstream's.
#   - small patches to upstream files, each marked "ios-gpu-*" (a marker also makes the patch idempotent).
# The QPA plugin is NOT touched: KWin-as-a-client keeps the raster/QPainter path (kwin-ios-fixes.sh), exactly as the
# shipped 6.1 lane did in practice ("EGL not available -> software QtQuick" is benign there).
set -euo pipefail

src=${1:?usage: kwin-ios-gpu-backend.sh /path/to/kwin-source}
backend="$src/src/backends/wayland"
assets="$(cd "$(dirname "$0")/kwin-ios-gpu" && pwd)"

wayland-scanner client-header \
  "$src/src/wayland/protocols/iosc-iosurface.xml" \
  "$backend/iosc-iosurface-client-protocol.h"

python3 - "$src" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace(path, old, new, marker):
    p = root / path
    text = p.read_text()
    if marker in text:
        return
    if old not in text:
        raise SystemExit(f"{path}: missing anchor for {marker}")
    p.write_text(text.replace(old, new, 1))

# ---- iosc_iosurface global on the nested host connection -------------------------------------------------------------
replace("src/backends/wayland/wayland_display.h",
        "struct zwp_linux_dmabuf_v1;\n",
        "struct zwp_linux_dmabuf_v1;\nstruct iosc_iosurface; // ios-gpu-factory\n",
        "ios-gpu-factory")
replace("src/backends/wayland/wayland_display.h",
        "    WaylandClient::LinuxDmabufV1 *linuxDmabuf() const;\n",
        "    WaylandClient::LinuxDmabufV1 *linuxDmabuf() const;\n    iosc_iosurface *iosurface() const; // ios-gpu-factory-accessor\n",
        "ios-gpu-factory-accessor")
replace("src/backends/wayland/wayland_display.h",
        "    std::unique_ptr<WaylandClient::LinuxDmabufV1> m_linuxDmabuf;\n",
        "    std::unique_ptr<WaylandClient::LinuxDmabufV1> m_linuxDmabuf;\n    iosc_iosurface *m_iosurface = nullptr; // ios-gpu-factory-member\n",
        "ios-gpu-factory-member")
replace("src/backends/wayland/wayland_display.cpp",
        '#include "wayland-xdg-shell-client-protocol.h"\n',
        '#include "wayland-xdg-shell-client-protocol.h"\n#include "iosc-iosurface-client-protocol.h" // ios-gpu-factory-include\n',
        "ios-gpu-factory-include")
replace("src/backends/wayland/wayland_display.cpp",
        "    m_linuxDmabuf.reset();\n",
        "    m_linuxDmabuf.reset();\n    if (m_iosurface) { // ios-gpu-factory-destroy\n        iosc_iosurface_destroy(m_iosurface);\n        m_iosurface = nullptr;\n    }\n",
        "ios-gpu-factory-destroy")
replace("src/backends/wayland/wayland_display.cpp",
        "WaylandClient::LinuxDmabufV1 *WaylandDisplay::linuxDmabuf() const\n{\n    return m_linuxDmabuf.get();\n}\n",
        "WaylandClient::LinuxDmabufV1 *WaylandDisplay::linuxDmabuf() const\n{\n    return m_linuxDmabuf.get();\n}\n\n"
        "iosc_iosurface *WaylandDisplay::iosurface() const // ios-gpu-factory-accessor-impl\n{\n    return m_iosurface;\n}\n",
        "ios-gpu-factory-accessor-impl")
replace("src/backends/wayland/wayland_display.cpp",
        "    } else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {",
        "    } else if (strcmp(interface, iosc_iosurface_interface.name) == 0) { // ios-gpu-factory-bind\n"
        "        display->m_iosurface = static_cast<struct iosc_iosurface *>(wl_registry_bind(registry, name, &iosc_iosurface_interface, 1));\n"
        "    } else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {",
        "ios-gpu-factory-bind")

# ---- no DrmDevice on iOS ---------------------------------------------------------------------------------------------
# linux-drm-syncobj-v1 is DRM-only; the unconditional deref segfaulted the moment OpenGL compositing was attempted.
replace("src/wayland_server.cpp",
        "    if (backend->drmDevice()->supportsSyncObjTimelines()) {",
        "    if (backend->drmDevice() && backend->drmDevice()->supportsSyncObjTimelines()) { // ios-gpu-no-drm-syncobj",
        "ios-gpu-no-drm-syncobj")
replace("src/compositor.cpp",
        "    if (const auto pciInfo = backend->drmDevice()->pciDeviceInfo()) {",
        "    if (const auto pciInfo = backend->drmDevice() ? backend->drmDevice()->pciDeviceInfo() : std::nullopt) { // ios-gpu-no-drm-pci",
        "ios-gpu-no-drm-pci")

# ---- an OpenGL ES 3.0 context: what KWin 6.7 needs and ANGLE has to be asked for explicitly -------------------------
# KWin asks for EGL_CONTEXT_CLIENT_VERSION 2 and relies on drivers handing out the newest compatible version. ANGLE
# creates exactly the version requested, so 6.7 got an ES 2.0 context, and EglContext::checkSupported() rejected it
# without a word (no 3D textures without GL_OES_texture_3D, which ANGLE does not expose on ES 2): KWin printed only
# "Could not initialize rendering context" and fell back to QPainter. ANGLE Metal gives ES 3.0 on the A10 (the angle
# deb's es3 patch), so ask for 3 first and keep upstream's ES 2 candidates as the fallback.
replace("src/opengl/eglcontext.cpp",
        "    std::vector<std::unique_ptr<AbstractOpenGLContextAttributeBuilder>> candidates;\n    if (GLES) {\n",
        "    std::vector<std::unique_ptr<AbstractOpenGLContextAttributeBuilder>> candidates;\n    if (GLES) {\n"
        "#if defined(__APPLE__) // ios-gpu-gles3-context\n"
        "        {\n"
        "            auto gles3 = std::make_unique<EglOpenGLESContextAttributeBuilder>();\n"
        "            gles3->setVersion(3);\n"
        "            candidates.push_back(std::move(gles3));\n"
        "        }\n"
        "#endif\n",
        "ios-gpu-gles3-context")
# ANGLE's GLSL preprocessor is spec-strict: an undefined identifier in #if is an error, not 0, and the extension macro
# is not defined under "#version 300 es" (derivatives are core there). Mesa tolerates it; ANGLE fails every base.frag
# variant with "'GL_OES_standard_derivatives' : unexpected token after conditional expression".
replace("src/opengl/base.frag",
        "#if GL_OES_standard_derivatives && TRAIT_ROUNDED_CORNERS && TRAIT_BORDER\n",
        "#if defined(GL_OES_standard_derivatives) && TRAIT_ROUNDED_CORNERS && TRAIT_BORDER // ios-gpu-angle-glsl-defined\n",
        "ios-gpu-angle-glsl-defined")
# Several effect shaders (blur downsample, colour-blindness correction, monochrome) say "#version 140" but sample with
# texture2D(), which desktop GL 1.40 still has and GLSL ES 3.00 does not: ANGLE rejects them, and blur dies with
# "Failed to load downsampling pass shader". Alias it for GLES core shaders, the same way upstream already aliases
# texture() the other way round for pre-1.40 shaders.
replace("src/opengl/glshader.cpp",
        '            ret.append("precision highp sampler3D;\\n");\n        }\n',
        '            ret.append("precision highp sampler3D;\\n");\n'
        '            if (coreShader) { // ios-gpu-gles3-texture2d\n'
        '                ret.append("#define texture2D texture\\n");\n'
        '            }\n'
        '        }\n',
        "ios-gpu-gles3-texture2d")
# GL_UNPACK_ROW_LENGTH & co. are core in ES 3.0; upstream only accepts the ES 2 extension spelling.
replace("src/opengl/eglcontext.cpp",
        "    const bool supportsUnpack = !m_isOpenglES || hasOpenglExtension(QByteArrayLiteral(\"GL_EXT_unpack_subimage\"));\n",
        "    const bool supportsUnpack = !m_isOpenglES || hasVersion(Version(3, 0)) || hasOpenglExtension(QByteArrayLiteral(\"GL_EXT_unpack_subimage\")); // ios-gpu-es3-unpack\n",
        "ios-gpu-es3-unpack")
# Say which requirement failed instead of failing silently: this check is what cost device run 1 its GPU path.
replace("src/opengl/eglcontext.cpp",
        "    if (!supportsGLSL || !supportsNonPowerOfTwoTextures || !supports3DTextures || !supportsFBOs || !supportsUnpack || !supportsBGRADownload) {\n        return false;\n    }\n",
        "    if (!supportsGLSL || !supportsNonPowerOfTwoTextures || !supports3DTextures || !supportsFBOs || !supportsUnpack || !supportsBGRADownload) {\n"
        "        qCWarning(KWIN_OPENGL) << \"ios-gpu: GL context rejected:\" << m_versionString << \"glsl\" << supportsGLSL // ios-gpu-checksupported-diag\n"
        "                               << \"npot\" << supportsNonPowerOfTwoTextures << \"3d\" << supports3DTextures << \"fbo\" << supportsFBOs\n"
        "                               << \"unpack\" << supportsUnpack << \"bgraRead\" << supportsBGRADownload;\n"
        "        return false;\n    }\n",
        "ios-gpu-checksupported-diag")
replace("src/opengl/eglcontext.cpp",
        "    return m_shaderManager->shader(ShaderTrait::MapTexture | ShaderTrait::TransformColorspace | ShaderTrait::AdjustSaturation | ShaderTrait::Modulate);\n}",
        "    if (!m_shaderManager->shader(ShaderTrait::MapTexture | ShaderTrait::TransformColorspace | ShaderTrait::AdjustSaturation | ShaderTrait::Modulate)) {\n"
        "        qCWarning(KWIN_OPENGL) << \"ios-gpu: GL context rejected: the probe shader does not compile on\" << m_versionString; // ios-gpu-checksupported-shader\n"
        "        return false;\n"
        "    }\n"
        "    qCInfo(KWIN_OPENGL) << \"ios-gpu: GL context\" << m_versionString << m_renderer;\n"
        "    return true;\n}",
        "ios-gpu-checksupported-shader")

# RenderDevice assumes a DrmDevice (nullable here) and a Vulkan instance: vk::raii::Context dlopens a Vulkan loader
# that does not exist on iOS. Both members go away on Apple; vulkanDevice() stays nullptr.
replace("src/core/renderdevice.h",
        "    const vk::raii::Context m_vulkanContext;\n    const vk::raii::Instance m_vulkanInstance;\n",
        "#if !defined(__APPLE__) // ios-gpu-no-vulkan: no Vulkan loader on iOS\n    const vk::raii::Context m_vulkanContext;\n    const vk::raii::Instance m_vulkanInstance;\n#endif\n",
        "ios-gpu-no-vulkan")
replace("src/core/renderdevice.cpp",
        "    , m_display(std::move(display))\n    , m_vulkanInstance(createVulkanInstance(m_vulkanContext))\n{",
        "    , m_display(std::move(display))\n#if !defined(__APPLE__) // ios-gpu-no-vulkan-ctor\n    , m_vulkanInstance(createVulkanInstance(m_vulkanContext))\n#endif\n{",
        "ios-gpu-no-vulkan-ctor")
replace("src/core/renderdevice.cpp",
        "void RenderDevice::createVulkanDevice()\n{\n    if (!*m_vulkanInstance) {\n        return;\n    }\n    m_vulkanDevice = openVulkanDevice(m_vulkanInstance, m_device.get());",
        "void RenderDevice::createVulkanDevice()\n{\n#if defined(__APPLE__) // ios-gpu-no-vulkan-create\n    m_inReset = false;\n    return;\n#else\n    if (!*m_vulkanInstance) {\n        return;\n    }\n    m_vulkanDevice = openVulkanDevice(m_vulkanInstance, m_device.get());",
        "ios-gpu-no-vulkan-create")
replace("src/core/renderdevice.cpp",
        "        connect(m_vulkanDevice.get(), &VulkanDevice::deviceLost, this, &RenderDevice::handleVulkanDeviceLoss);\n    }\n    m_inReset = false;\n}",
        "        connect(m_vulkanDevice.get(), &VulkanDevice::deviceLost, this, &RenderDevice::handleVulkanDeviceLoss);\n    }\n    m_inReset = false;\n#endif\n}",
        "ios-gpu-no-vulkan-create-end")

# ---- WaylandBackend: pick the ANGLE render device, accept IOSurface buffers ------------------------------------------
replace("src/backends/wayland/wayland_backend.h",
        "    RenderDevice *m_renderDevice = nullptr;\n",
        "    RenderDevice *m_renderDevice = nullptr;\n    std::unique_ptr<RenderDevice> m_ioscRenderDevice; // ios-gpu-render-device\n",
        "ios-gpu-render-device")
replace("src/backends/wayland/wayland_backend.cpp",
        '#include "wayland_display.h"\n',
        '#include "iosc_gpu_support.h" // ios-gpu-backend-include\n#include "wayland_display.h"\n',
        "ios-gpu-backend-include")
replace("src/backends/wayland/wayland_backend.cpp",
        "    createOutputs();\n\n    m_seat = std::make_unique<WaylandSeat>",
        "    if (!m_renderDevice && m_display->iosurface()) { // ios-gpu-render-device-create\n"
        "        m_ioscRenderDevice = createIoscRenderDevice();\n"
        "        m_renderDevice = m_ioscRenderDevice.get();\n"
        "    }\n\n"
        "    createOutputs();\n\n    m_seat = std::make_unique<WaylandSeat>",
        "ios-gpu-render-device-create")
replace("src/backends/wayland/wayland_backend.cpp",
        "    if (m_display->linuxDmabuf() && m_renderDevice) {\n        ret.append(OpenGLCompositing);\n    }",
        "    if ((m_display->linuxDmabuf() || m_display->iosurface()) && m_renderDevice) { // ios-gpu-supported-compositor\n        ret.append(OpenGLCompositing);\n    }",
        "ios-gpu-supported-compositor")
replace("src/backends/wayland/wayland_backend.cpp",
        "        if (const DmaBufAttributes *attributes = graphicsBuffer->dmabufAttributes()) {\n            handle = m_display->linuxDmabuf()->importBuffer(graphicsBuffer);",
        "        if (graphicsBuffer->iosurface()) { // ios-gpu-import-iosurface\n            handle = ioscCreateWlBuffer(m_display.get(), graphicsBuffer);\n"
        "            if (!handle) {\n                return nullptr;\n            }\n"
        "        } else if (const DmaBufAttributes *attributes = graphicsBuffer->dmabufAttributes()) {\n            handle = m_display->linuxDmabuf()->importBuffer(graphicsBuffer);",
        "ios-gpu-import-iosurface")

# ---- host presentation timestamps onto KWin's clock -------------------------------------------------------------------
# KWin 6.7 paces the nested output purely from wp_presentation "presented" and feeds the timestamp straight into
# RenderLoop, which works on std::chrono::steady_clock. iosc stamps presentation in CLOCK_MONOTONIC (what it
# advertises as clock_id), while libc++'s steady_clock on Darwin is CLOCK_UPTIME_RAW. The two differ by seconds to
# minutes and the gap changes every time the iPad sleeps (CLOCK_MONOTONIC keeps counting, UPTIME_RAW does not; see
# the A10 clock note). When the host clock is AHEAD, RenderLoop schedules the next composite that far in the future
# and KWin stops repainting for that long after every presented frame: taps reach Plasma but nothing shows, and a
# rotation leaves Plasma's old-size surfaces on screen. When it is behind (the case on the test boot), the bogus
# negative safety margin only happens to work. Map the host time onto steady_clock at receipt.
replace("src/backends/wayland/wayland_output.cpp",
        "#include <cmath>\n",
        "#include <cmath>\n#include <time.h> // ios-presentation-clock-include\n",
        "ios-presentation-clock-include")
replace("src/backends/wayland/wayland_output.cpp",
        "    const auto timestamp = std::chrono::seconds((uint64_t(tv_sec_hi) << 32) | tv_sec_lo) + std::chrono::nanoseconds(tv_nsec);\n",
        "    std::chrono::nanoseconds timestamp = std::chrono::seconds((uint64_t(tv_sec_hi) << 32) | tv_sec_lo) + std::chrono::nanoseconds(tv_nsec);\n"
        "#if defined(__APPLE__) // ios-presentation-clock-map\n"
        "    {\n"
        "        timespec host = {};\n"
        "        clock_gettime(CLOCK_MONOTONIC, &host); // iosc's wp_presentation clock_id\n"
        "        const std::chrono::nanoseconds hostNow = std::chrono::seconds(host.tv_sec) + std::chrono::nanoseconds(host.tv_nsec);\n"
        "        timestamp = timestamp - hostNow + std::chrono::steady_clock::now().time_since_epoch();\n"
        "    }\n"
        "#endif\n",
        "ios-presentation-clock-map")

# The Metal acquire fence rides with every commit of a compositor-owned IOSurface (the wl_buffer is cached per
# GraphicsBuffer, the fence is per frame).
replace("src/backends/wayland/wayland_layer.cpp",
        '#include "wayland_display.h"\n',
        '#include "iosc_gpu_support.h" // ios-gpu-layer-include\n#include "wayland_display.h"\n',
        "ios-gpu-layer-include")
replace("src/backends/wayland/wayland_layer.cpp",
        "        m_surface->attachBuffer(output->backend()->importBuffer(m_pendingBuffer.buffer()));\n",
        "        wl_buffer *wlBuffer = output->backend()->importBuffer(m_pendingBuffer.buffer());\n"
        "        m_surface->attachBuffer(wlBuffer);\n"
        "        ioscApplyAcquireFence(output->backend()->display(), wlBuffer, m_pendingBuffer.buffer()); // ios-gpu-layer-fence\n",
        "ios-gpu-layer-fence")

replace("src/backends/wayland/CMakeLists.txt",
        "    color_manager.cpp\n",
        "    color_manager.cpp\n    iosc_gpu_support.cpp # ios-gpu-sources\n",
        "ios-gpu-sources")

# ---- swapchain slots and client buffers become GL textures through the IOSurface pbuffer binding --------------------
replace("src/opengl/eglswapchain.cpp",
        '#include "opengl/glutils.h"\n',
        '#include "opengl/glutils.h"\n#include "backends/wayland/iosc_gpu_support.h" // ios-gpu-swapchain-include\n',
        "ios-gpu-swapchain-include")
replace("src/opengl/eglswapchain.cpp",
        "    auto texture = context->importDmaBufAsTexture(*buffer->dmabufAttributes());\n",
        "    auto texture = buffer->iosurface() ? importIoscBufferAsTexture(context, buffer) // ios-gpu-swapchain-slot\n                                       : context->importDmaBufAsTexture(*buffer->dmabufAttributes());\n",
        "ios-gpu-swapchain-slot")
replace("src/opengl/eglswapchain.cpp",
        "                                          seed->dmabufAttributes()->modifier,\n",
        "                                          seed->dmabufAttributes() ? seed->dmabufAttributes()->modifier : uint64_t(DRM_FORMAT_MOD_LINEAR), // ios-gpu-swapchain-modifier\n",
        "ios-gpu-swapchain-modifier")

replace("src/scene/opengl/texture.h",
        "    bool loadShmTexture(GraphicsBuffer *buffer);\n",
        "    bool loadIoscTexture(GraphicsBuffer *buffer); // ios-gpu-texture-api\n    bool loadShmTexture(GraphicsBuffer *buffer);\n",
        "ios-gpu-texture-api")
replace("src/scene/opengl/texture.h",
        "        UDmaBuf,\n    };\n\n    BufferType m_bufferType = BufferType::None;\n",
        "        UDmaBuf,\n        Iosc, // ios-gpu-texture-type\n    };\n\n    BufferType m_bufferType = BufferType::None;\n    void *m_ioscSurface = nullptr;\n",
        "ios-gpu-texture-type")
replace("src/scene/opengl/texture.cpp",
        '#include "opengl/eglbackend.h"\n',
        '#include "backends/wayland/iosc_gpu_support.h" // ios-gpu-texture-include\n#include "opengl/eglbackend.h"\n#include "wayland/ioscclientbuffer.h"\n',
        "ios-gpu-texture-include")
replace("src/scene/opengl/texture.cpp",
        "bool BufferTextureOpenGL::attach(GraphicsBuffer *buffer, const std::shared_ptr<SyncReleasePoint> &releasePoint)\n{\n    if (buffer->dmabufAttributes()) {",
        "bool BufferTextureOpenGL::attach(GraphicsBuffer *buffer, const std::shared_ptr<SyncReleasePoint> &releasePoint)\n{\n    if (buffer->iosurface()) { // ios-gpu-texture-attach\n        return loadIoscTexture(buffer);\n    } else if (buffer->dmabufAttributes()) {",
        "ios-gpu-texture-attach")
replace("src/scene/opengl/texture.cpp",
        "void BufferTextureOpenGL::attach(GraphicsBuffer *buffer, const Region &region, const std::shared_ptr<SyncReleasePoint> &releasePoint)\n{\n    if (buffer->dmabufAttributes()) {",
        "void BufferTextureOpenGL::attach(GraphicsBuffer *buffer, const Region &region, const std::shared_ptr<SyncReleasePoint> &releasePoint)\n{\n"
        "    if (buffer->iosurface()) { // ios-gpu-texture-update\n"
        "        if (m_bufferType == BufferType::Iosc && m_ioscSurface == buffer->iosurface()) {\n"
        "            // same IOSurface re-committed by the client: only the Metal fence has to be waited on again\n"
        "            if (auto *ioscBuffer = dynamic_cast<IoscClientBuffer *>(buffer)) {\n"
        "                if (!ioscBuffer->waitAcquireFence(m_backend->eglDisplayObject()->handle())) {\n"
        "                    qCWarning(KWIN_OPENGL) << \"ios-iosc-tex: refusing an unfenced client IOSurface update\";\n"
        "                }\n"
        "            }\n"
        "        } else {\n"
        "            reset();\n"
        "            loadIoscTexture(buffer);\n"
        "        }\n"
        "    } else if (buffer->dmabufAttributes()) {",
        "ios-gpu-texture-update")
replace("src/scene/opengl/texture.cpp",
        "    m_size = QSize();\n    m_releasePoint.reset();\n}",
        "    m_size = QSize();\n    m_ioscSurface = nullptr; // ios-gpu-texture-reset\n    m_releasePoint.reset();\n}",
        "ios-gpu-texture-reset")

p = root / "src/scene/opengl/texture.cpp"
text = p.read_text()
if "ios-gpu-texture-load" not in text:
    anchor = "bool BufferTextureOpenGL::loadShmTexture(GraphicsBuffer *buffer)\n"
    if anchor not in text:
        raise SystemExit(f"{p}: missing IOSurface texture insertion anchor")
    implementation = r'''bool BufferTextureOpenGL::loadIoscTexture(GraphicsBuffer *buffer) // ios-gpu-texture-load
{
    auto *ioscBuffer = dynamic_cast<IoscClientBuffer *>(buffer);
    if (!ioscBuffer) {
        return false;
    }
    EGLDisplay display = m_backend->eglDisplayObject()->handle();
    if (!ioscBuffer->waitAcquireFence(display)) {
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex: refusing an unfenced client IOSurface";
        return false;
    }
    // Clients that already present in top-left order are stored upside down relative to GL; everything else is GL origin.
    auto texture = createIoscSurfaceTexture(display, buffer->iosurface(), buffer->size(),
                                            ioscBuffer->isTopLeft() ? OutputTransform::FlipY : OutputTransform::Normal);
    if (!texture) {
        return false;
    }
    texture->setFilter(GL_LINEAR);
    texture->setWrapMode(GL_CLAMP_TO_EDGE);

    m_planes = {texture.release()};
    m_bufferType = BufferType::Iosc;
    m_ioscSurface = buffer->iosurface();
    m_size = buffer->size();
    m_isFloatingPoint = false;

    if (qEnvironmentVariableIsSet("KWIN_IOS_TEXTURE_DIAG")) {
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex diag: bound IOSurface texture size=" << buffer->size() << "topLeft=" << ioscBuffer->isTopLeft();
    }
    return true;
}

'''
    p.write_text(text.replace(anchor, implementation + anchor, 1))
PY

install -m 0644 "$assets/wayland_egl_backend.h" "$backend/wayland_egl_backend.h"
install -m 0644 "$assets/wayland_egl_backend.cpp" "$backend/wayland_egl_backend.cpp"
install -m 0644 "$assets/iosc_egl_helpers.h" "$backend/iosc_egl_helpers.h"
install -m 0644 "$assets/iosc_gpu_support.h" "$backend/iosc_gpu_support.h"
install -m 0644 "$assets/iosc_gpu_support.cpp" "$backend/iosc_gpu_support.cpp"

echo "kwin: applied ANGLE Metal + IOSurface nested Wayland output backend (6.7)"
