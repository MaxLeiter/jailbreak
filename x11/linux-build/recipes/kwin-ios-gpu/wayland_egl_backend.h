/* KWin nested Wayland EGL backend for Xios: ANGLE Metal -> IOSurface. */
#pragma once

#include "core/outputlayer.h"
#include "opengl/glframebuffer.h"
#include "platformsupport/scenes/opengl/abstract_egl_backend.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <QRegion>
#include <epoxy/egl.h>
#include <memory>
#include <vector>

struct wl_buffer;

namespace KWin::Wayland
{
class WaylandBackend;
class WaylandOutput;
class WaylandEglBackend;

struct IoscEglBuffer
{
    IoscEglBuffer(WaylandEglBackend *backend, const QSize &size);
    ~IoscEglBuffer();

    static void released(void *data, wl_buffer *buffer);

    QSize size;
    IOSurfaceRef surface = nullptr;
    mach_port_t port = MACH_PORT_NULL;
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface pbuffer = EGL_NO_SURFACE;
    wl_buffer *buffer = nullptr;
    std::unique_ptr<GLFramebuffer> framebuffer;
    // EGL_ANGLE_iosurface_client_buffer reaches the IOSurface ONLY through
    // eglBindTexImage; the pbuffer's default framebuffer is not backed by it.
    // Built lazily on first use, when a context is guaranteed current.
    GLuint texture = 0;
    GLuint fbo = 0;
    bool ensureRenderTarget();
    QRegion repaint;
    bool busy = false;
};

class IoscEglSwapchain
{
public:
    IoscEglSwapchain(WaylandEglBackend *backend, const QSize &size);
    IoscEglBuffer *acquire();
    void rendered(IoscEglBuffer *buffer, const QRegion &damage);
    QSize size() const;

private:
    QSize m_size;
    std::vector<std::unique_ptr<IoscEglBuffer>> m_buffers;
};

class WaylandEglPrimaryLayer : public OutputLayer
{
public:
    WaylandEglPrimaryLayer(WaylandOutput *output, WaylandEglBackend *backend);
    void present();
    std::optional<OutputLayerBeginFrameInfo> doBeginFrame() override;
    bool doEndFrame(const QRegion &, const QRegion &damagedRegion, OutputFrame *frame) override;
    bool doAttemptScanout(GraphicsBuffer *, const ColorDescription &, const std::shared_ptr<OutputFrame> &) override;
    DrmDevice *scanoutDevice() const override;
    QHash<uint32_t, QList<uint64_t>> supportedDrmFormats() const override;

private:
    std::unique_ptr<IoscEglSwapchain> m_swapchain;
    IoscEglBuffer *m_buffer = nullptr;
    WaylandEglBackend *m_backend;
    QRegion m_damage;
    // Size the opaque region was last declared for; re-declared only on change so
    // present() does not create/destroy a wl_region every frame.
    QSize m_opaqueSize;
};

class WaylandEglCursorLayer : public OutputLayer
{
public:
    WaylandEglCursorLayer(WaylandOutput *output, WaylandEglBackend *backend);
    std::optional<OutputLayerBeginFrameInfo> doBeginFrame() override;
    bool doEndFrame(const QRegion &, const QRegion &, OutputFrame *frame) override;
    DrmDevice *scanoutDevice() const override;
    QHash<uint32_t, QList<uint64_t>> supportedDrmFormats() const override;

private:
    std::unique_ptr<IoscEglSwapchain> m_swapchain;
    IoscEglBuffer *m_buffer = nullptr;
    WaylandEglBackend *m_backend;
};

class WaylandEglBackend : public AbstractEglBackend
{
    Q_OBJECT
public:
    explicit WaylandEglBackend(WaylandBackend *backend);
    ~WaylandEglBackend() override;

    void init() override;
    void present(Output *output, const std::shared_ptr<OutputFrame> &frame) override;
    OutputLayer *primaryLayer(Output *output) override;
    OutputLayer *cursorLayer(Output *output) override;
    DrmDevice *drmDevice() const override;
    std::unique_ptr<SurfaceTexture> createSurfaceTextureWayland(SurfacePixmap *pixmap) override;
    std::pair<std::shared_ptr<GLTexture>, ColorDescription> textureForOutput(Output *output) const override;

    WaylandBackend *backend() const;
    EGLConfig config() const;

private:
    bool initializeEgl();
    bool initializeContext();
    bool createOutput(Output *output);
    void cleanupSurfaces() override;

    struct Layers {
        std::unique_ptr<WaylandEglPrimaryLayer> primary;
        std::unique_ptr<WaylandEglCursorLayer> cursor;
    };
    WaylandBackend *m_backend;
    EGLConfig m_config = EGL_NO_CONFIG_KHR;
    std::map<Output *, Layers> m_outputs;
};
}
