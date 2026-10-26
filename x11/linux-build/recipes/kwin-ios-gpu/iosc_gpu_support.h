/* Xios GPU path for KWin: ANGLE Metal render device, IOSurface textures, brokered Metal fences.
 * Lives in libkwin (backends/wayland); shared by the nested EGL backend, EglSwapchain and BufferTextureOpenGL. */
#pragma once

#include "core/graphicsbuffer.h"
#include "core/graphicsbufferallocator.h"
#include "opengl/gltexture.h"

#include <QSize>
#include <epoxy/egl.h>
#include <memory>

struct wl_buffer;

namespace KWin
{

class EglContext;
class RenderDevice;

namespace Wayland
{
class WaylandDisplay;
}

/** A GLTexture backed by an IOSurface pbuffer (EGL_ANGLE_iosurface_client_buffer). Owns the pbuffer. */
class IoscSurfaceTexture : public GLTexture
{
public:
    IoscSurfaceTexture(EGLDisplay display, EGLSurface pbuffer, uint textureId, const QSize &size, OutputTransform transform);
    ~IoscSurfaceTexture() override;

private:
    EGLDisplay m_display;
    EGLSurface m_pbuffer;
};

/** The ANGLE Metal EGL display wrapped in a RenderDevice without DRM and without Vulkan, or nullptr. */
std::unique_ptr<RenderDevice> createIoscRenderDevice();

/** Bind @p iosurface to a new GL texture. The current EGL context must be the compositor's. */
std::unique_ptr<GLTexture> createIoscSurfaceTexture(EGLDisplay display, void *iosurface, const QSize &size, OutputTransform transform);

/** Render-target flavour for swapchains: GL origin, i.e. no content transform. */
std::shared_ptr<GLTexture> importIoscBufferAsTexture(EglContext *context, GraphicsBuffer *buffer);

/** Allocator for compositor-owned IOSurface swapchain buffers. */
GraphicsBufferAllocator *ioscGpuAllocator();

/** Export the Metal acquire fence of the work just flushed and remember it on @p buffer. */
bool ioscSignalAcquireFence(EGLDisplay display, GraphicsBuffer *buffer);

/** wl_buffer for a compositor-owned IOSurface buffer (the nested host's iosc_iosurface global). */
wl_buffer *ioscCreateWlBuffer(Wayland::WaylandDisplay *display, GraphicsBuffer *buffer);

/** Send the remembered acquire fence for @p wlBuffer. No-op for buffers that are not IOSurface swapchain buffers. */
void ioscApplyAcquireFence(Wayland::WaylandDisplay *display, wl_buffer *wlBuffer, GraphicsBuffer *buffer);

} // namespace KWin
