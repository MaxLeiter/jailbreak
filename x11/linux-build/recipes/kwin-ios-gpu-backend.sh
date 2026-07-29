#!/usr/bin/env bash
# Apply the small source edits for KWin's Xios GPU path, then install the owned
# backend/QPA source templates from kwin-ios-gpu/. The baseline compatibility
# pass has already generated the server-side iosc client buffer type.
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

replace(
    "src/backends/wayland/wayland_display.h",
    "struct zwp_linux_dmabuf_v1;\n",
    "struct zwp_linux_dmabuf_v1;\nstruct iosc_iosurface; // ios-gpu-factory\n",
    "ios-gpu-factory",
)
replace(
    "src/backends/wayland/wayland_display.h",
    "    WaylandLinuxDmabufV1 *linuxDmabuf() const;\n",
    "    WaylandLinuxDmabufV1 *linuxDmabuf() const;\n    iosc_iosurface *iosurface() const; // ios-gpu-factory-accessor\n",
    "ios-gpu-factory-accessor",
)
replace(
    "src/backends/wayland/wayland_display.h",
    "    std::unique_ptr<WaylandLinuxDmabufV1> m_linuxDmabuf;\n",
    "    std::unique_ptr<WaylandLinuxDmabufV1> m_linuxDmabuf;\n    iosc_iosurface *m_iosurface = nullptr; // ios-gpu-factory-member\n",
    "ios-gpu-factory-member",
)

replace(
    "src/backends/wayland/wayland_display.h",
    "    iosc_iosurface *iosurface() const; // ios-gpu-factory-accessor\n",
    "    iosc_iosurface *iosurface() const; // ios-gpu-factory-accessor\n"
    "    uint32_t iosurfaceCapabilities() const; // ios-gpu-caps-accessor\n"
    "    void setIosurfaceCapabilities(uint32_t capabilities);\n",
    "ios-gpu-caps-accessor",
)
replace(
    "src/backends/wayland/wayland_display.h",
    "    iosc_iosurface *m_iosurface = nullptr; // ios-gpu-factory-member\n",
    "    iosc_iosurface *m_iosurface = nullptr; // ios-gpu-factory-member\n"
    "    uint32_t m_iosurfaceCaps = 0; // ios-gpu-caps-member\n",
    "ios-gpu-caps-member",
)

replace(
    "src/backends/wayland/wayland_display.cpp",
    '#include "wayland-xdg-shell-client-protocol.h"\n',
    '#include "wayland-xdg-shell-client-protocol.h"\n#include "iosc-iosurface-client-protocol.h" // ios-gpu-factory-include\n',
    "ios-gpu-factory-include",
)

# The compositor advertises its IOSurface import contract through the version-2
# capabilities event. Bind at the generated interface version and actually
# consume the event: with no listener the proxy sees an unknown opcode, which is
# exactly what produced "interface 'iosc_iosurface' has no event 0" followed by a
# dropped connection while kwin was still generated from the stale v1 XML.
# Defined here, immediately after the includes, so the registry global handler
# below can reference the listener.
replace(
    "src/backends/wayland/wayland_display.cpp",
    '#include "iosc-iosurface-client-protocol.h" // ios-gpu-factory-include\n',
    '#include "iosc-iosurface-client-protocol.h" // ios-gpu-factory-include\n'
    "\nnamespace KWin\n{\nnamespace Wayland\n{\n"
    "static void iosc_iosurface_handle_capabilities(void *data, struct iosc_iosurface *, uint32_t capabilities); // ios-gpu-caps-handler\n"
    "\nstatic const struct iosc_iosurface_listener s_ioscIosurfaceListener = {\n"
    "    iosc_iosurface_handle_capabilities,\n};\n"
    "}\n} // namespace KWin::Wayland\n",
    "ios-gpu-caps-handler",
)
replace(
    "src/backends/wayland/wayland_display.cpp",
    "    m_linuxDmabuf.reset();\n\n    if (m_shm) {",
    "    m_linuxDmabuf.reset();\n    if (m_iosurface) { // ios-gpu-factory-destroy\n        iosc_iosurface_destroy(m_iosurface);\n        m_iosurface = nullptr;\n    }\n\n    if (m_shm) {",
    "ios-gpu-factory-destroy",
)
replace(
    "src/backends/wayland/wayland_display.cpp",
    "WaylandLinuxDmabufV1 *WaylandDisplay::linuxDmabuf() const\n{\n    return m_linuxDmabuf.get();\n}\n",
    "WaylandLinuxDmabufV1 *WaylandDisplay::linuxDmabuf() const\n{\n    return m_linuxDmabuf.get();\n}\n\n+iosc_iosurface *WaylandDisplay::iosurface() const // ios-gpu-factory-accessor-impl\n+{\n+    return m_iosurface;\n+}\n".replace("\n+", "\n"),
    "ios-gpu-factory-accessor-impl",
)

# Accessor/setter impls live with the other WaylandDisplay methods.
replace(
    "src/backends/wayland/wayland_display.cpp",
    "iosc_iosurface *WaylandDisplay::iosurface() const // ios-gpu-factory-accessor-impl\n{\n    return m_iosurface;\n}\n",
    "iosc_iosurface *WaylandDisplay::iosurface() const // ios-gpu-factory-accessor-impl\n{\n    return m_iosurface;\n}\n"
    "\nuint32_t WaylandDisplay::iosurfaceCapabilities() const // ios-gpu-caps-accessor-impl\n{\n    return m_iosurfaceCaps;\n}\n"
    "\nvoid WaylandDisplay::setIosurfaceCapabilities(uint32_t capabilities)\n{\n    m_iosurfaceCaps = capabilities;\n}\n"
    "\nstatic void iosc_iosurface_handle_capabilities(void *data, struct iosc_iosurface *, uint32_t capabilities) // ios-gpu-caps-handler-impl\n{\n"
    "    static_cast<WaylandDisplay *>(data)->setIosurfaceCapabilities(capabilities);\n}\n",
    "ios-gpu-caps-accessor-impl",
)
replace(
    "src/backends/wayland/wayland_display.cpp",
    "    } else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {",
    "    } else if (strcmp(interface, iosc_iosurface_interface.name) == 0) { // ios-gpu-factory-bind\n"
    "        const uint32_t ioscVersion = std::min(version, uint32_t(iosc_iosurface_interface.version));\n"
    "        display->m_iosurface = static_cast<struct iosc_iosurface *>(wl_registry_bind(registry, name, &iosc_iosurface_interface, ioscVersion));\n"
    "        if (ioscVersion >= 2) {\n"
    "            iosc_iosurface_add_listener(display->m_iosurface, &s_ioscIosurfaceListener, display);\n"
    "        }\n"
    "    } else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {",
    "ios-gpu-factory-bind",
)

# linux-drm-syncobj-v1 is a DRM-only protocol. On iOS the render backend has no
# DrmDevice, so the unconditional deref here segfaulted the moment OpenGL
# compositing was actually attempted:
#   KWin::DrmDevice::supportsSyncObjTimelines() const   <- KERN_INVALID_ADDRESS 0x30
#   KWin::WaylandServer::setRenderBackend
#   KWin::AbstractEglBackend::initWayland
#   KWin::WaylandCompositor::attemptOpenGLCompositing
# Guarding the pointer lets the existing else-branch tear down any stale
# interface, which is the correct behaviour for a backend with no DRM device.
replace(
    "src/wayland_server.cpp",
    "    if (backend->drmDevice()->supportsSyncObjTimelines()) {",
    "    if (backend->drmDevice() && backend->drmDevice()->supportsSyncObjTimelines()) { // ios-gpu-no-drm-syncobj",
    "ios-gpu-no-drm-syncobj",
)

replace(
    "src/backends/wayland/wayland_backend.cpp",
    "    if (m_display->linuxDmabuf() && m_drmDevice) {\n        ret.append(OpenGLCompositing);\n    }",
    "    if (m_display->iosurface() || (m_display->linuxDmabuf() && m_drmDevice)) { // ios-gpu-supported-compositor\n        ret.append(OpenGLCompositing);\n    }",
    "ios-gpu-supported-compositor",
)

# QPA is linked statically into kwin_wayland while the concrete iosc buffer
# implementation lives in libkwin. Expose the native handle through the
# already-exported GraphicsBuffer vtable so QPA does not depend on hidden
# IoscClientBuffer RTTI or member symbols at the dylib boundary.
replace(
    "src/core/graphicsbuffer.h",
    "    virtual const ShmAttributes *shmAttributes() const;\n",
    "    virtual const ShmAttributes *shmAttributes() const;\n    virtual void *iosurface() const; // ios-gpu-native-iosurface\n",
    "ios-gpu-native-iosurface",
)
replace(
    "src/core/graphicsbuffer.cpp",
    "const ShmAttributes *GraphicsBuffer::shmAttributes() const\n{\n    return nullptr;\n}\n",
    "const ShmAttributes *GraphicsBuffer::shmAttributes() const\n{\n    return nullptr;\n}\n\nvoid *GraphicsBuffer::iosurface() const // ios-gpu-native-iosurface-impl\n{\n    return nullptr;\n}\n",
    "ios-gpu-native-iosurface-impl",
)

# Preserve the QPainter mapping fallback, but expose the imported IOSurface and
# its declared origin so the OpenGL scene can bind it directly as an EGL texture.
replace(
    "src/wayland/ioscclientbuffer.h",
    "    IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client);",
    "    IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client, bool topLeft); // ios-gpu-client-constructor",
    "ios-gpu-client-constructor",
)
replace(
    "src/wayland/ioscclientbuffer.cpp",
    "IoscClientBuffer::IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client)\n    : m_iosurface(iosurface)",
    "IoscClientBuffer::IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client, bool topLeft) // ios-gpu-client-constructor-impl\n    : m_iosurface(iosurface)\n    , m_topLeft(topLeft)",
    "ios-gpu-client-constructor-impl",
)
replace(
    "src/wayland/ioscclientbuffer.h",
    "    const ShmAttributes *shmAttributes() const override;\n\n    static IoscClientBuffer *get(wl_resource *resource);",
    "    const ShmAttributes *shmAttributes() const override;\n\n    void *iosurface() const override; // ios-gpu-client-accessor\n    bool isTopLeft() const;\n\n    static IoscClientBuffer *get(wl_resource *resource);",
    "ios-gpu-client-accessor",
)
replace(
    "src/wayland/ioscclientbuffer.h",
    "    QByteArray m_flippedData;\n",
    "    QByteArray m_flippedData;\n    bool m_topLeft = false; // ios-gpu-client-origin\n",
    "ios-gpu-client-origin",
)
replace(
    "src/wayland/ioscclientbuffer.cpp",
    "        new IoscClientBuffer(surface, QSize(importedWidth, importedHeight), id, resource->client());",
    "        new IoscClientBuffer(surface, QSize(importedWidth, importedHeight), id, resource->client(),\n            (format & IOSC_IOSURFACE_FORMAT_FLAG_TOP_LEFT) != 0); // ios-gpu-client-origin-set",
    "ios-gpu-client-origin-set",
)
replace(
    "src/wayland/ioscclientbuffer.cpp",
    "const ShmAttributes *IoscClientBuffer::shmAttributes() const\n{\n    return &m_attributes;\n}\n",
    "const ShmAttributes *IoscClientBuffer::shmAttributes() const\n{\n    return &m_attributes;\n}\n\nvoid *IoscClientBuffer::iosurface() const // ios-gpu-client-accessor-impl\n{\n    return m_iosurface;\n}\n\nbool IoscClientBuffer::isTopLeft() const\n{\n    return m_topLeft;\n}\n",
    "ios-gpu-client-accessor-impl",
)

replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.h",
    "class GraphicsBuffer;\n",
    "class GraphicsBuffer;\nclass IoscClientBuffer; // ios-gpu-client-texture-decl\n",
    "ios-gpu-client-texture-decl",
)
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.h",
    "    bool loadShmTexture(GraphicsBuffer *buffer);",
    "    bool loadIoscTexture(IoscClientBuffer *buffer); // ios-gpu-client-texture-api\n    void updateIoscTexture(IoscClientBuffer *buffer);\n    bool loadShmTexture(GraphicsBuffer *buffer);",
    "ios-gpu-client-texture-api",
)
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.h",
    "        DmaBuf,\n    };\n\n    BufferType m_bufferType = BufferType::None;",
    "        DmaBuf,\n        Iosc, // ios-gpu-client-texture-type\n    };\n\n    BufferType m_bufferType = BufferType::None;\n    EGLConfig m_iosurfaceConfig = EGL_NO_CONFIG_KHR;\n    EGLSurface m_iosurfacePbuffer = EGL_NO_SURFACE;\n    IoscClientBuffer *m_iosurfaceBuffer = nullptr;",
    "ios-gpu-client-texture-type",
)
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.h",
    '#include "openglsurfacetexture_wayland.h"\n',
    '#include "openglsurfacetexture_wayland.h"\n#include <epoxy/egl.h> // ios-gpu-client-texture-egl\n',
    "ios-gpu-client-texture-egl",
)

replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    '#include "core/graphicsbufferview.h"\n',
    '#include "core/graphicsbufferview.h"\n#include "wayland/ioscclientbuffer.h" // ios-gpu-client-texture-include\n#include "opengl/egldisplay.h"\n#include "backends/wayland/iosc_egl_helpers.h"\n#include <IOSurface/IOSurfaceRef.h>\n',
    "ios-gpu-client-texture-include",
)
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    "bool BasicEGLSurfaceTextureWayland::create()\n{\n    if (m_pixmap->buffer()->dmabufAttributes()) {",
    "bool BasicEGLSurfaceTextureWayland::create()\n{\n    if (auto *buffer = dynamic_cast<IoscClientBuffer *>(m_pixmap->buffer())) { // ios-gpu-client-texture-create\n        return loadIoscTexture(buffer);\n    } else if (m_pixmap->buffer()->dmabufAttributes()) {",
    "ios-gpu-client-texture-create",
)
# KWIN_IOS_TEXTURE_DIAG=1 reports every client-buffer texture load: which branch
# ran, whether it succeeded, and the GL error. Silence from this means create() is
# never called at all, which is a different bug from a failing texture upload --
# and the two are indistinguishable from a black screen.
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    "        return loadShmTexture(m_pixmap->buffer());\n    } else {\n        return false;\n    }\n}",
    "        const bool ok = loadShmTexture(m_pixmap->buffer());\n        if (qEnvironmentVariableIsSet(\"KWIN_IOS_TEXTURE_DIAG\")) {\n            qCWarning(KWIN_OPENGL) << \"ios-tex: shm load ok=\" << ok << \"size=\" << m_pixmap->buffer()->size() << \"glerr=\" << Qt::hex << glGetError();\n        }\n        return ok;\n    } else {\n        if (qEnvironmentVariableIsSet(\"KWIN_IOS_TEXTURE_DIAG\")) {\n            qCWarning(KWIN_OPENGL) << \"ios-tex: UNKNOWN buffer type -- no texture\";\n        }\n        return false;\n    }\n}",
    "ios-gpu-client-texture-diag",
)
# Content stats for shm uploads (still under KWIN_IOS_TEXTURE_DIAG): a texture that
# loads ok but carries all-black pixels means the CLIENT drew black, which no
# amount of compositor debugging will fix. Samples a 16px grid, so it is cheap
# enough to run on every create and (throttled) on updates.
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    "            qCWarning(KWIN_OPENGL) << \"ios-tex: shm load ok=\" << ok << \"size=\" << m_pixmap->buffer()->size() << \"glerr=\" << Qt::hex << glGetError();\n",
    "            qCWarning(KWIN_OPENGL) << \"ios-tex: shm load ok=\" << ok << \"size=\" << m_pixmap->buffer()->size() << \"glerr=\" << Qt::hex << glGetError();\n            { // ios-gpu-shm-content-diag\n                const GraphicsBufferView v(m_pixmap->buffer());\n                if (!v.isNull() && v.image()->depth() == 32) {\n                    const QImage *im = v.image();\n                    int nonblack = 0, sampled = 0;\n                    for (int y = 0; y < im->height(); y += 16) {\n                        const QRgb *row = reinterpret_cast<const QRgb *>(im->constScanLine(y));\n                        for (int x = 0; x < im->width(); x += 16) {\n                            if (qRed(row[x]) | qGreen(row[x]) | qBlue(row[x])) { nonblack++; }\n                            sampled++;\n                        }\n                    }\n                    qCWarning(KWIN_OPENGL) << \"ios-tex: shm content nonblack\" << nonblack << \"/\" << sampled << \"centre=\" << Qt::hex << im->pixel(im->width() / 2, im->height() / 2);\n                }\n            }\n",
    "ios-gpu-shm-content-diag",
)
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    "void BasicEGLSurfaceTextureWayland::updateShmTexture(GraphicsBuffer *buffer, const QRegion &region)\n{\n",
    "void BasicEGLSurfaceTextureWayland::updateShmTexture(GraphicsBuffer *buffer, const QRegion &region)\n{\n    if (qEnvironmentVariableIsSet(\"KWIN_IOS_TEXTURE_DIAG\")) { // ios-gpu-shm-update-diag\n        static unsigned long iosUpdN = 0;\n        if ((iosUpdN++ % 60) == 0) {\n            const GraphicsBufferView v(buffer);\n            if (!v.isNull() && v.image()->depth() == 32) {\n                const QImage *im = v.image();\n                int nonblack = 0, sampled = 0;\n                for (int y = 0; y < im->height(); y += 16) {\n                    const QRgb *row = reinterpret_cast<const QRgb *>(im->constScanLine(y));\n                    for (int x = 0; x < im->width(); x += 16) {\n                        if (qRed(row[x]) | qGreen(row[x]) | qBlue(row[x])) { nonblack++; }\n                        sampled++;\n                    }\n                }\n                qCWarning(KWIN_OPENGL) << \"ios-tex: shm UPDATE nonblack\" << nonblack << \"/\" << sampled << \"size=\" << im->size() << \"region=\" << region.boundingRect();\n            }\n        }\n    }\n",
    "ios-gpu-shm-update-diag",
)

# KWIN_IOS_PAINT_TRACE=1: which windows the scene actually paints, with what clip
# region, and every WindowItem visibility flip. paintWindow returning early on an
# empty region is invisible in every other diagnostic, yet it is the exact spot
# where a window silently fails to appear.
replace(
    "src/scene/workspacescene.cpp",
    "void WorkspaceScene::paintWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, WindowItem *item, int mask, const QRegion &region)\n{\n    if (region.isEmpty()) { // completely clipped\n        return;\n    }\n",
    "void WorkspaceScene::paintWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, WindowItem *item, int mask, const QRegion &region)\n{\n    static unsigned long iosPaintN = 0; // ios-gpu-paint-trace\n    if (qEnvironmentVariableIsSet(\"KWIN_IOS_PAINT_TRACE\") && (iosPaintN++ % 120) < 3) {\n        qWarning() << \"ios-paint:\" << item->window()->resourceClass() << \"clip=\" << region.boundingRect() << (region.isEmpty() ? \"(CLIPPED OUT)\" : \"\");\n    }\n    if (region.isEmpty()) { // completely clipped\n        return;\n    }\n",
    "ios-gpu-paint-trace",
)
replace(
    "src/scene/windowitem.cpp",
    "void WindowItem::updateVisibility()\n{\n    const bool visible = computeVisibility();\n",
    "void WindowItem::updateVisibility()\n{\n    const bool visible = computeVisibility();\n    if (qEnvironmentVariableIsSet(\"KWIN_IOS_PAINT_TRACE\")) { // ios-gpu-visibility-trace\n        qWarning() << \"ios-vis:\" << m_window->resourceClass() << \"visible=\" << visible << \"ready=\" << m_window->readyForPainting();\n    }\n",
    "ios-gpu-visibility-trace",
)

replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    "void BasicEGLSurfaceTextureWayland::destroy()\n{\n    m_texture.reset();\n    m_bufferType = BufferType::None;\n}",
    "void BasicEGLSurfaceTextureWayland::destroy()\n{\n    if (m_iosurfacePbuffer != EGL_NO_SURFACE) { // ios-gpu-client-texture-destroy\n        if (!m_texture.planes.empty()) {\n            m_texture.planes[0]->bind();\n            eglReleaseTexImage(backend()->eglDisplayObject()->handle(), m_iosurfacePbuffer, EGL_BACK_BUFFER);\n            m_texture.planes[0]->unbind();\n        }\n        m_texture.reset();\n        eglDestroySurface(backend()->eglDisplayObject()->handle(), m_iosurfacePbuffer);\n        m_iosurfacePbuffer = EGL_NO_SURFACE;\n        m_iosurfaceBuffer = nullptr;\n    } else {\n        m_texture.reset();\n    }\n    m_bufferType = BufferType::None;\n}",
    "ios-gpu-client-texture-destroy",
)
replace(
    "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp",
    "void BasicEGLSurfaceTextureWayland::update(const QRegion &region)\n{\n    if (m_pixmap->buffer()->dmabufAttributes()) {",
    "void BasicEGLSurfaceTextureWayland::update(const QRegion &region)\n{\n    if (auto *buffer = dynamic_cast<IoscClientBuffer *>(m_pixmap->buffer())) { // ios-gpu-client-texture-update\n        updateIoscTexture(buffer);\n    } else if (m_pixmap->buffer()->dmabufAttributes()) {",
    "ios-gpu-client-texture-update",
)

p = root / "src/platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.cpp"
text = p.read_text()
if "ios-gpu-client-texture-load" not in text:
    anchor = "bool BasicEGLSurfaceTextureWayland::loadShmTexture(GraphicsBuffer *buffer)\n"
    if anchor not in text:
        raise SystemExit(f"{p}: missing IOSurface texture insertion anchor")
    implementation = r'''bool BasicEGLSurfaceTextureWayland::loadIoscTexture(IoscClientBuffer *buffer) // ios-gpu-client-texture-load
{
    EGLDisplay display = backend()->eglDisplayObject()->handle();
    if (m_iosurfaceConfig == EGL_NO_CONFIG_KHR) {
        m_iosurfaceConfig = chooseIoscEglConfig(display);
    }
    if (m_iosurfaceConfig == EGL_NO_CONFIG_KHR) {
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex diag: no EGLConfig for IOSurface, egl=" << Qt::hex << eglGetError();
        return false;
    }
    m_iosurfacePbuffer = createIoscEglPbuffer(display, m_iosurfaceConfig, buffer->iosurface(), buffer->size());
    if (m_iosurfacePbuffer == EGL_NO_SURFACE) {
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex diag: pbuffer failed size=" << buffer->size() << "egl=" << Qt::hex << eglGetError();
        return false;
    }
    auto texture = std::make_shared<GLTexture>(GL_TEXTURE_2D);
    texture->setSize(buffer->size());
    if (!texture->create()) {
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex diag: GLTexture::create failed size=" << buffer->size() << "gl=" << Qt::hex << glGetError();
        eglDestroySurface(display, m_iosurfacePbuffer);
        m_iosurfacePbuffer = EGL_NO_SURFACE;
        return false;
    }
    texture->setWrapMode(GL_CLAMP_TO_EDGE);
    texture->setFilter(GL_LINEAR);
    texture->bind();
    if (!eglBindTexImage(display, m_iosurfacePbuffer, EGL_BACK_BUFFER)) {
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex diag: eglBindTexImage failed egl=" << Qt::hex << eglGetError();
        texture->unbind();
        eglDestroySurface(display, m_iosurfacePbuffer);
        m_iosurfacePbuffer = EGL_NO_SURFACE;
        return false;
    }
    texture->unbind();
    if (buffer->isTopLeft()) {
        texture->setContentTransform(OutputTransform::FlipY);
    }
    m_texture = {{texture}};
    m_iosurfaceBuffer = buffer;
    m_bufferType = BufferType::Iosc;
    if (qEnvironmentVariableIsSet("KWIN_IOS_TEXTURE_DIAG")) {
        // Read the client's IOSurface on the CPU. A texture that binds cleanly but
        // carries an all-black surface means the CLIENT never rendered into it --
        // the EGL_ANGLE_iosurface_client_buffer trap where drawing lands in the
        // pbuffer's default framebuffer, which is NOT backed by the IOSurface.
        int nonblack = 0, sampled = 0;
        unsigned centre = 0;
        if (IOSurfaceRef s = static_cast<IOSurfaceRef>(buffer->iosurface())) {
            if (IOSurfaceLock(s, 0x1 /* kIOSurfaceLockReadOnly */, nullptr) == 0) {
                const uint8_t *base = static_cast<const uint8_t *>(IOSurfaceGetBaseAddress(s));
                const size_t stride = IOSurfaceGetBytesPerRow(s);
                const int w = int(IOSurfaceGetWidth(s)), h = int(IOSurfaceGetHeight(s));
                if (base) {
                    for (int y = 0; y < h; y += 16) {
                        const uint8_t *row = base + size_t(y) * stride;
                        for (int x = 0; x < w; x += 16) {
                            const uint8_t *px = row + size_t(x) * 4;
                            if (px[0] | px[1] | px[2]) { nonblack++; }
                            sampled++;
                        }
                    }
                    centre = *reinterpret_cast<const uint32_t *>(base + size_t(h / 2) * stride + size_t(w / 2) * 4);
                }
                IOSurfaceUnlock(s, 0x1, nullptr);
            }
        }
        qCWarning(KWIN_OPENGL) << "ios-iosc-tex diag: OK size=" << buffer->size() << "topLeft=" << buffer->isTopLeft()
                               << "iosc content nonblack" << nonblack << "/" << sampled << "centre=" << Qt::hex << centre;
    }
    return true;
}

void BasicEGLSurfaceTextureWayland::updateIoscTexture(IoscClientBuffer *buffer)
{
    const bool changed = (m_bufferType != BufferType::Iosc || m_iosurfaceBuffer != buffer);
    if (qEnvironmentVariableIsSet("KWIN_IOS_TEXTURE_DIAG")) {
        static unsigned long updN = 0;
        if ((updN++ % 30) == 0) {
            qCWarning(KWIN_OPENGL) << "ios-iosc-upd: update() call" << updN << "buffer=" << (void *)buffer
                                   << "prev=" << (void *)m_iosurfaceBuffer << "changed=" << changed;
        }
    }
    if (changed) {
        destroy();
        loadIoscTexture(buffer);
    }
}

'''
    p.write_text(text.replace(anchor, implementation + anchor, 1))

# Internal QtQuick windows use the same IOSurface GraphicsBuffer type, but do
# not have a wl_client/wl_resource. Supply a small allocator for the QPA swapchain.
replace(
    "src/wayland/ioscclientbuffer.h",
    '#include "core/graphicsbuffer.h"\n',
    '#include "core/graphicsbuffer.h"\n#include "core/graphicsbufferallocator.h" // ios-gpu-internal-allocator\n',
    "ios-gpu-internal-allocator",
)
replace(
    "src/wayland/ioscclientbuffer.h",
    "    IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client, bool topLeft); // ios-gpu-client-constructor",
    "    IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client, bool topLeft); // ios-gpu-client-constructor\n    IoscClientBuffer(void *iosurface, const QSize &size, bool topLeft); // ios-gpu-internal-buffer",
    "ios-gpu-internal-buffer",
)
replace(
    "src/wayland/ioscclientbuffer.h",
    "};\n\n} // namespace KWin\n",
    "};\n\nclass IoscGraphicsBufferAllocator : public GraphicsBufferAllocator // ios-gpu-internal-allocator-class\n{\npublic:\n    GraphicsBuffer *allocate(const GraphicsBufferOptions &options) override;\n};\n\n} // namespace KWin\n",
    "ios-gpu-internal-allocator-class",
)

p = root / "src/wayland/ioscclientbuffer.cpp"
text = p.read_text()
if "ios-gpu-internal-buffer-impl" not in text:
    anchor = "IoscClientBuffer::IoscClientBuffer(void *iosurface, const QSize &size, uint32_t id, wl_client *client, bool topLeft) // ios-gpu-client-constructor-impl\n"
    if anchor not in text:
        raise SystemExit(f"{p}: missing internal buffer constructor anchor")
    impl = r'''IoscClientBuffer::IoscClientBuffer(void *iosurface, const QSize &size, bool topLeft) // ios-gpu-internal-buffer-impl
    : m_iosurface(iosurface)
    , m_topLeft(topLeft)
{
    const IOSurfaceRef surface = static_cast<IOSurfaceRef>(m_iosurface);
    m_attributes.stride = static_cast<int>(IOSurfaceGetBytesPerRow(surface));
    m_attributes.offset = 0;
    m_attributes.size = size;
    m_attributes.format = DRM_FORMAT_ARGB8888;
}

'''
    p.write_text(text.replace(anchor, impl + anchor, 1))

p = root / "src/wayland/ioscclientbuffer.cpp"
text = p.read_text()
if "ios-gpu-internal-allocator-impl" not in text:
    anchor = "IoscClientBufferIntegration::~IoscClientBufferIntegration() = default;\n"
    impl = r'''
static void setIOSurfaceNumber(CFMutableDictionaryRef dict, CFStringRef key, int32_t value)
{
    CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &value);
    CFDictionarySetValue(dict, key, number);
    CFRelease(number);
}

GraphicsBuffer *IoscGraphicsBufferAllocator::allocate(const GraphicsBufferOptions &options) // ios-gpu-internal-allocator-impl
{
    if (options.software || options.format != DRM_FORMAT_ARGB8888 || options.size.isEmpty()) {
        return nullptr;
    }
    const size_t stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size_t(options.size.width()) * 4);
    const size_t allocation = IOSurfaceAlignProperty(kIOSurfaceAllocSize, stride * size_t(options.size.height()));
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setIOSurfaceNumber(dict, kIOSurfaceWidth, options.size.width());
    setIOSurfaceNumber(dict, kIOSurfaceHeight, options.size.height());
    setIOSurfaceNumber(dict, kIOSurfaceBytesPerElement, 4);
    setIOSurfaceNumber(dict, kIOSurfaceBytesPerRow, int32_t(stride));
    setIOSurfaceNumber(dict, kIOSurfaceAllocSize, int32_t(allocation));
    setIOSurfaceNumber(dict, kIOSurfacePixelFormat, 0x42475241);
    IOSurfaceRef surface = IOSurfaceCreate(dict);
    CFRelease(dict);
    return surface ? new IoscClientBuffer(surface, options.size, false) : nullptr;
}
'''
    if anchor not in text:
        raise SystemExit(f"{p}: missing allocator implementation anchor")
    p.write_text(text.replace(anchor, anchor + impl, 1))

# The allocator is constructed by the static QPA plugin but implemented in
# libkwin, so its vtable must cross the dylib visibility boundary.
p = root / "src/wayland/ioscclientbuffer.h"
text = p.read_text()
text = text.replace(
    "class IoscGraphicsBufferAllocator : public GraphicsBufferAllocator // ios-gpu-internal-allocator-class",
    "class KWIN_EXPORT IoscGraphicsBufferAllocator : public GraphicsBufferAllocator // ios-gpu-internal-allocator-class",
)
p.write_text(text)

# Reverse only the first-light QPA GL stubs; keep the unrelated iOS theme and
# event-dispatch compatibility changes in place.
replace(
    "src/plugins/qpa/CMakeLists.txt",
    "    backingstore.cpp\n",
    "    backingstore.cpp\n    eglhelpers.cpp # ios-gpu-qpa-sources\n    eglplatformcontext.cpp # ios-gpu-qpa-context-source\n",
    "ios-gpu-qpa-sources",
)
replace(
    "src/plugins/qpa/CMakeLists.txt",
    "target_compile_definitions(KWinQpaPlugin PRIVATE QT_STATICPLUGIN)",
    "target_compile_definitions(KWinQpaPlugin PRIVATE QT_STATICPLUGIN KWIN_IOS_GL_COEXIST=1) # ios-gpu-qpa-coexist",
    "ios-gpu-qpa-coexist",
)
replace(
    "src/plugins/qpa/integration.h",
    "#include <QObject>\n",
    "#include <QObject>\n#include <epoxy/egl.h> // ios-gpu-qpa-egl\n",
    "ios-gpu-qpa-egl",
)
replace(
    "src/plugins/qpa/integration.cpp",
    '#include "backingstore.h"\n',
    '#include "backingstore.h"\n#include "eglplatformcontext.h" // ios-gpu-qpa-context\n#include "core/outputbackend.h"\n',
    "ios-gpu-qpa-context",
)

# KWin's EGL wrappers use libepoxy.  Including the platform EGL header first
# makes epoxy deliberately stop with an include-order diagnostic, so keep every
# QPA EGL entry point on the same wrapper as the rest of KWin.
for relative in (
    "src/plugins/qpa/integration.h",
    "src/plugins/qpa/eglhelpers.h",
    "src/plugins/qpa/offscreensurface.h",
):
    p = root / relative
    text = p.read_text()
    text = text.replace("#include <EGL/egl.h>", "#include <epoxy/egl.h>")
    p.write_text(text)
replace(
    "src/plugins/qpa/integration.cpp",
    "    case OpenGL:\n        return false;",
    "    case OpenGL:\n        return true; // ios-gpu-qpa-capability",
    "ios-gpu-qpa-capability",
)
replace(
    "src/plugins/qpa/integration.cpp",
    "QPlatformOpenGLContext *Integration::createPlatformOpenGLContext(QOpenGLContext *context) const\n{\n    Q_UNUSED(context)\n    qCWarning(KWIN_QPA) << \"QPA OpenGL contexts are disabled on the iOS first-light build\";\n    return nullptr;\n}",
    "QPlatformOpenGLContext *Integration::createPlatformOpenGLContext(QOpenGLContext *context) const\n{\n    if (kwinApp()->outputBackend()->sceneEglGlobalShareContext() == EGL_NO_CONTEXT) { // ios-gpu-qpa-create\n        qCWarning(KWIN_QPA) << \"Attempting to create a QOpenGLContext before the scene is initialized\";\n        return nullptr;\n    }\n    if (auto *display = kwinApp()->outputBackend()->sceneEglDisplayObject()) {\n        return new EGLPlatformContext(context, display);\n    }\n    return nullptr;\n}",
    "ios-gpu-qpa-create",
)

# Replace the first-light Window::swapchain body with a dual allocator: SHM for
# raster surfaces and IOSurface for OpenGL/QtQuick surfaces.
p = root / "src/plugins/qpa/window.cpp"
text = p.read_text()
if "ios-gpu-qpa-swapchain" not in text:
    text = text.replace('#include "core/shmgraphicsbufferallocator.h"\n', '#include "core/shmgraphicsbufferallocator.h"\n#include "wayland/ioscclientbuffer.h" // ios-gpu-qpa-swapchain\n', 1)
    start = text.index("Swapchain *Window::swapchain(")
    end = text.index("\nvoid Window::invalidateSurface()", start)
    function = r'''Swapchain *Window::swapchain(const std::shared_ptr<EglContext> &context, const QHash<uint32_t, QList<uint64_t>> &formats)
{
    const QSize nativeSize = geometry().size() * devicePixelRatio();
    const bool software = window()->surfaceType() == QSurface::RasterSurface;
    const QList<uint64_t> modifiers = formats.value(DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR});
    if (!m_swapchain || m_swapchain->size() != nativeSize
        || m_swapchain->format() != DRM_FORMAT_ARGB8888
        || m_swapchain->modifiers() != modifiers
        || (!software && m_eglContext.lock() != context)) {
        static ShmGraphicsBufferAllocator shmAllocator;
        static IoscGraphicsBufferAllocator ioscAllocator;
        GraphicsBufferAllocator *allocator = software
            ? static_cast<GraphicsBufferAllocator *>(&shmAllocator)
            : static_cast<GraphicsBufferAllocator *>(&ioscAllocator);
        const auto options = GraphicsBufferOptions{
            .size = nativeSize,
            .format = DRM_FORMAT_ARGB8888,
            .modifiers = modifiers,
            .software = software,
        };
        if (auto *buffer = allocator->allocate(options)) {
            m_swapchain = std::make_unique<Swapchain>(allocator, options, buffer);
            m_eglContext = context;
        }
    }
    return m_swapchain.get();
}
'''
    p.write_text(text[:start] + function + text[end:])
PY

install -m 0644 "$assets/wayland_egl_backend.h" "$backend/wayland_egl_backend.h"
install -m 0644 "$assets/wayland_egl_backend.cpp" "$backend/wayland_egl_backend.cpp"
install -m 0644 "$assets/iosc_egl_helpers.h" "$backend/iosc_egl_helpers.h"
install -m 0644 "$assets/eglplatformcontext.h" "$src/src/plugins/qpa/eglplatformcontext.h"
install -m 0644 "$assets/eglplatformcontext.cpp" "$src/src/plugins/qpa/eglplatformcontext.cpp"

echo "kwin: applied ANGLE Metal + IOSurface nested Wayland output backend"
