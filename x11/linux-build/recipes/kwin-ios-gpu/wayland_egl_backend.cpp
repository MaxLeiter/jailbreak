/* KWin nested Wayland EGL backend for Xios: ANGLE Metal -> IOSurface. */
#include "wayland_egl_backend.h"

#include "iosc_egl_helpers.h"

#include "iosc-iosurface-client-protocol.h"
#include "opengl/glutils.h"
#include "platformsupport/scenes/opengl/basiceglsurfacetexture_wayland.h"
#include "scene/surfaceitem_wayland.h"
#include "wayland_backend.h"
#include "wayland_display.h"
#include "wayland_logging.h"
#include "wayland_output.h"

#include <KWayland/Client/surface.h>
#include <drm_fourcc.h>
#include <mach/mach.h>
#include <cmath>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
namespace KWin::Wayland
{
static void setNumber(CFMutableDictionaryRef dict, CFStringRef key, int32_t value)
{
    CFNumberRef number = CFNumberCreate(nullptr, kCFNumberSInt32Type, &value);
    CFDictionarySetValue(dict, key, number);
    CFRelease(number);
}

static IOSurfaceRef createIOSurface(const QSize &size)
{
    const size_t stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, size_t(size.width()) * 4);
    const size_t allocation = IOSurfaceAlignProperty(kIOSurfaceAllocSize, stride * size_t(size.height()));
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setNumber(dict, kIOSurfaceWidth, size.width());
    setNumber(dict, kIOSurfaceHeight, size.height());
    setNumber(dict, kIOSurfaceBytesPerElement, 4);
    setNumber(dict, kIOSurfaceBytesPerRow, int32_t(stride));
    setNumber(dict, kIOSurfaceAllocSize, int32_t(allocation));
    setNumber(dict, kIOSurfacePixelFormat, 0x42475241); // 'BGRA'
    IOSurfaceRef surface = IOSurfaceCreate(dict);
    CFRelease(dict);
    return surface;
}

static const wl_buffer_listener bufferListener = {IoscEglBuffer::released};

IoscEglBuffer::IoscEglBuffer(WaylandEglBackend *backend, const QSize &size)
    : size(size)
    , surface(createIOSurface(size))
    , display(backend->eglDisplayObject()->handle())
    , repaint(QRect(QPoint(0, 0), size))
{
    if (!surface) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: IOSurfaceCreate failed for" << size;
        return;
    }
    pbuffer = createIoscEglPbuffer(display, backend->config(), surface, size);
    if (pbuffer == EGL_NO_SURFACE) {
        const EGLint err = eglGetError();
        qCWarning(KWIN_WAYLAND_BACKEND) << "ANGLE IOSurface pbuffer creation failed" << Qt::hex << err;
        // ios-gpu-pbuffer-diag: EGL_BAD_ATTRIBUTE here means ANGLE rejected the
        // (display, config, surface geometry) triple. Dump all three plus the real
        // IOSurface geometry so the mismatch is identifiable without a second build.
        qCWarning(KWIN_WAYLAND_BACKEND).nospace()
            << "ios-gpu-diag: requested=" << size.width() << "x" << size.height()
            << " display=" << (void *)display
            << " backendDisplay=" << (void *)(backend->eglDisplayObject() ? backend->eglDisplayObject()->handle() : EGL_NO_DISPLAY)
            << " config=" << (void *)backend->config()
            << " iosurface=" << (void *)surface
            << " ioW=" << (int)IOSurfaceGetWidth(surface)
            << " ioH=" << (int)IOSurfaceGetHeight(surface)
            << " ioBPR=" << (int)IOSurfaceGetBytesPerRow(surface)
            << " ioBPE=" << (int)IOSurfaceGetBytesPerElement(surface)
            << " ioFmt=" << Qt::hex << (unsigned)IOSurfaceGetPixelFormat(surface);
        return;
    }
    port = IOSurfaceCreateMachPort(surface);
    buffer = iosc_iosurface_create_buffer(backend->backend()->display()->iosurface(), uint32_t(port),
        size.width(), size.height(), IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN);
    wl_buffer_add_listener(buffer, &bufferListener, this);
    // The GL texture + FBO cannot be built here: no context is current during
    // swapchain construction. ensureRenderTarget() does it on first beginFrame.
}

// Bind the IOSurface-backed pbuffer as a GL texture and wrap it in a real FBO.
//
// This is the load-bearing detail of EGL_ANGLE_iosurface_client_buffer: rendering
// into the pbuffer's DEFAULT framebuffer (FBO 0) does not touch the IOSurface, so
// every frame landed somewhere invisible -- the compositor reported success, iosc
// imported the buffers, and the screen stayed black. The IOSurface is reachable
// only via eglBindTexImage + glFramebufferTexture2D, which is exactly what iosc's
// own proven output path does (iosc_gl.c: bind_pbuffer_texture -> FBO).
//
// Caller must have made the context current on `pbuffer` first.
bool IoscEglBuffer::ensureRenderTarget()
{
    if (fbo) {
        return true;
    }
    if (pbuffer == EGL_NO_SURFACE) {
        return false;
    }
    if (!eglBindTexImage(display, pbuffer, EGL_BACK_BUFFER)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglBindTexImage failed" << Qt::hex << eglGetError();
        return false;
    }
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    // eglBindTexImage targets whatever texture is bound to GL_TEXTURE_2D, so the
    // bind above must happen before the image is associated. Re-issue now that the
    // texture object exists.
    eglBindTexImage(display, pbuffer, EGL_BACK_BUFFER);

    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: IOSurface FBO incomplete" << Qt::hex << status;
        glDeleteFramebuffers(1, &fbo);
        fbo = 0;
        glDeleteTextures(1, &texture);
        texture = 0;
        return false;
    }
    framebuffer = std::make_unique<GLFramebuffer>(fbo, size);
    return true;
}

IoscEglBuffer::~IoscEglBuffer()
{
    framebuffer.reset();
    // Release the IOSurface texture binding before the pbuffer goes away, and drop
    // the GL objects. Leaking these would strand an IOSurface + mach port per
    // swapchain resize.
    if (fbo) {
        glDeleteFramebuffers(1, &fbo);
        fbo = 0;
    }
    if (texture) {
        eglReleaseTexImage(display, pbuffer, EGL_BACK_BUFFER);
        glDeleteTextures(1, &texture);
        texture = 0;
    }
    if (buffer) {
        wl_buffer_destroy(buffer);
    }
    if (port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), port);
    }
    if (pbuffer != EGL_NO_SURFACE) {
        eglDestroySurface(display, pbuffer);
    }
    if (surface) {
        CFRelease(surface);
    }
}

void IoscEglBuffer::released(void *data, wl_buffer *)
{
    static_cast<IoscEglBuffer *>(data)->busy = false;
}

IoscEglSwapchain::IoscEglSwapchain(WaylandEglBackend *backend, const QSize &size)
    : m_size(size)
{
    for (int i = 0; i < 3; ++i) {
        m_buffers.push_back(std::make_unique<IoscEglBuffer>(backend, size));
    }
}

IoscEglBuffer *IoscEglSwapchain::acquire()
{
    for (const auto &buffer : m_buffers) {
        if (buffer->pbuffer != EGL_NO_SURFACE && !buffer->busy) {
            return buffer.get();
        }
    }
    return nullptr;
}

void IoscEglSwapchain::rendered(IoscEglBuffer *current, const QRegion &damage)
{
    for (const auto &buffer : m_buffers) {
        if (buffer.get() == current) {
            buffer->repaint = QRegion();
        } else {
            buffer->repaint |= damage;
        }
    }
}

QSize IoscEglSwapchain::size() const
{
    return m_size;
}

WaylandEglPrimaryLayer::WaylandEglPrimaryLayer(WaylandOutput *output, WaylandEglBackend *backend)
    : OutputLayer(output)
    , m_backend(backend)
{
}

std::optional<OutputLayerBeginFrameInfo> WaylandEglPrimaryLayer::doBeginFrame()
{
    const QSize size = m_output->modeSize();
    if (!m_swapchain || m_swapchain->size() != size) {
        m_swapchain = std::make_unique<IoscEglSwapchain>(m_backend, size);
    }
    m_buffer = m_swapchain->acquire();
    if (!m_buffer || !m_backend->openglContext()->makeCurrent(m_buffer->pbuffer)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "No free Xios IOSurface render target";
        return std::nullopt;
    }
    if (!m_buffer->ensureRenderTarget()) {
        return std::nullopt;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, m_buffer->fbo);
    return OutputLayerBeginFrameInfo{.renderTarget = RenderTarget(m_buffer->framebuffer.get()), .repaint = m_buffer->repaint};
}

bool WaylandEglPrimaryLayer::doEndFrame(const QRegion &, const QRegion &damagedRegion, OutputFrame *)
{
    glFinish(); // correctness first: iosc samples the IOSurface in another process
    m_damage = damagedRegion;
    m_swapchain->rendered(m_buffer, damagedRegion);
    return true;
}

void WaylandEglPrimaryLayer::present()
{
    if (!m_buffer) {
        return;
    }
    auto *output = static_cast<WaylandOutput *>(m_output);
    output->surface()->attachBuffer(m_buffer->buffer);
    for (const QRect &rect : m_damage) {
        output->surface()->damageBuffer(rect);
    }
    output->surface()->setScale(std::ceil(output->scale()));
    m_buffer->busy = true;
    output->surface()->commit(KWayland::Client::Surface::CommitFlag::None);
    m_buffer = nullptr;
}

bool WaylandEglPrimaryLayer::doAttemptScanout(GraphicsBuffer *, const ColorDescription &, const std::shared_ptr<OutputFrame> &)
{
    return false;
}

DrmDevice *WaylandEglPrimaryLayer::scanoutDevice() const
{
    return nullptr;
}

QHash<uint32_t, QList<uint64_t>> WaylandEglPrimaryLayer::supportedDrmFormats() const
{
    return {{DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR}}};
}

WaylandEglCursorLayer::WaylandEglCursorLayer(WaylandOutput *output, WaylandEglBackend *backend)
    : OutputLayer(output)
    , m_backend(backend)
{
}

std::optional<OutputLayerBeginFrameInfo> WaylandEglCursorLayer::doBeginFrame()
{
    const QSize target = targetRect().size().expandedTo(QSize(64, 64));
    if (!m_swapchain || m_swapchain->size() != target) {
        m_swapchain = std::make_unique<IoscEglSwapchain>(m_backend, target);
    }
    m_buffer = m_swapchain->acquire();
    if (!m_buffer || !m_backend->openglContext()->makeCurrent(m_buffer->pbuffer)) {
        return std::nullopt;
    }
    if (!m_buffer->ensureRenderTarget()) {
        return std::nullopt;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, m_buffer->fbo);
    return OutputLayerBeginFrameInfo{.renderTarget = RenderTarget(m_buffer->framebuffer.get()), .repaint = infiniteRegion()};
}

bool WaylandEglCursorLayer::doEndFrame(const QRegion &, const QRegion &, OutputFrame *)
{
    glFinish();
    m_buffer->busy = true;
    static_cast<WaylandOutput *>(m_output)->cursor()->update(m_buffer->buffer, scale(), hotspot().toPoint());
    m_buffer = nullptr;
    return true;
}

DrmDevice *WaylandEglCursorLayer::scanoutDevice() const
{
    return nullptr;
}

QHash<uint32_t, QList<uint64_t>> WaylandEglCursorLayer::supportedDrmFormats() const
{
    return {{DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR}}};
}

WaylandEglBackend::WaylandEglBackend(WaylandBackend *backend)
    : m_backend(backend)
{
    connect(backend, &WaylandBackend::outputAdded, this, &WaylandEglBackend::createOutput);
    connect(backend, &WaylandBackend::outputRemoved, this, [this](Output *output) {
        m_outputs.erase(output);
    });
    backend->setEglBackend(this);
}

WaylandEglBackend::~WaylandEglBackend()
{
    cleanup();
}

WaylandBackend *WaylandEglBackend::backend() const
{
    return m_backend;
}

EGLConfig WaylandEglBackend::config() const
{
    return m_config;
}

DrmDevice *WaylandEglBackend::drmDevice() const
{
    return nullptr;
}

bool WaylandEglBackend::initializeEgl()
{
    initClientExtensions();
    const EGLint displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE,
    };
    auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!getPlatformDisplay) {
        return false;
    }
    auto display = EglDisplay::create(getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, displayAttributes));
    if (!display) {
        return false;
    }
    m_backend->setEglDisplay(std::move(display));
    setEglDisplay(m_backend->sceneEglDisplayObject());

    m_config = chooseIoscEglConfig(eglDisplayObject()->handle());
    return m_config != EGL_NO_CONFIG_KHR;
}

bool WaylandEglBackend::initializeContext()
{
    if (!createContext(m_config)) {
        return false;
    }
    const auto outputs = m_backend->waylandOutputs();
    if (outputs.isEmpty()) {
        return false;
    }
    for (Output *output : outputs) {
        if (!createOutput(output)) {
            return false;
        }
    }
    return true;
}

void WaylandEglBackend::init()
{
    if (!m_backend->display()->iosurface()) {
        setFailed("iosc_iosurface global is unavailable");
        return;
    }
    if (!initializeEgl()) {
        setFailed("Could not initialize ANGLE Metal EGL");
        return;
    }
    if (!initializeContext()) {
        setFailed("Could not initialize ANGLE GLES context");
        return;
    }
    initWayland();
}

bool WaylandEglBackend::createOutput(Output *output)
{
    m_outputs[output] = Layers{
        .primary = std::make_unique<WaylandEglPrimaryLayer>(static_cast<WaylandOutput *>(output), this),
        .cursor = std::make_unique<WaylandEglCursorLayer>(static_cast<WaylandOutput *>(output), this),
    };
    return true;
}

void WaylandEglBackend::cleanupSurfaces()
{
    m_outputs.clear();
}

void WaylandEglBackend::present(Output *output, const std::shared_ptr<OutputFrame> &frame)
{
    m_outputs.at(output).primary->present();
    auto *waylandOutput = static_cast<WaylandOutput *>(output);
    waylandOutput->setPendingFrame(frame);
    Q_EMIT waylandOutput->outputChange(frame->damage());
}

OutputLayer *WaylandEglBackend::primaryLayer(Output *output)
{
    return m_outputs.at(output).primary.get();
}

OutputLayer *WaylandEglBackend::cursorLayer(Output *output)
{
    return m_outputs.at(output).cursor.get();
}

std::unique_ptr<SurfaceTexture> WaylandEglBackend::createSurfaceTextureWayland(SurfacePixmap *pixmap)
{
    return std::make_unique<BasicEGLSurfaceTextureWayland>(this, pixmap);
}

std::pair<std::shared_ptr<GLTexture>, ColorDescription> WaylandEglBackend::textureForOutput(Output *) const
{
    return {nullptr, ColorDescription::sRGB};
}
}

#include "moc_wayland_egl_backend.cpp"
