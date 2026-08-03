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

#include <KWayland/Client/compositor.h>
#include <KWayland/Client/region.h>
#include <KWayland/Client/surface.h>
#include <drm_fourcc.h>
#include <mach/mach.h>
#include <cmath>
#include <cstddef>
#include <cstdint>

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
extern "C" int xios_metal_sync_signal(EGLDisplay display,
                                        const void **token,
                                        size_t *tokenSize,
                                        uint64_t *value);

static bool setAcquireFence(WaylandEglBackend *backend, IoscEglBuffer *buffer)
{
    const void *token = nullptr;
    size_t tokenSize = 0;
    uint64_t value = 0;
    if (!xios_metal_sync_signal(buffer->display, &token, &tokenSize, &value)
        || !token || tokenSize != 32 || value == 0) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: failed to export mandatory Metal acquire fence";
        return false;
    }

    wl_array tokenArray = {};
    tokenArray.size = tokenSize;
    tokenArray.alloc = tokenSize;
    tokenArray.data = const_cast<void *>(token);
    iosc_iosurface_set_acquire_fence(backend->backend()->display()->iosurface(),
        buffer->buffer, &tokenArray, uint32_t(value), uint32_t(value >> 32));
    return true;
}

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

// Freeing the IOSurface mach port: a send right handed to iosc must outlive the
// request that carries its NAME.
//
// The name in iosc_iosurface.create_buffer is a one-shot handoff token. iosc
// extracts its own COPY_SEND right (mach_port_extract_right on our task) while it
// processes that request, which happens whenever iosc gets round to draining its
// socket -- not when we send it. Deallocating the port in ~IoscEglBuffer() was
// therefore a race: the cursor layer rebuilds its ENTIRE swapchain every time the
// cursor image changes size (arrow -> I-beam over a text field and back), so a
// buffer can be constructed and destroyed inside the window where its create_buffer
// is still queued. iosc then fails the extract and answers with a protocol error,
// which is fatal -- it kills kwin_wayland and the whole Plasma session with it.
// Mach names are also recycled, so a freed name can be re-issued to an unrelated
// port and imported as if it were ours.
//
// So the port outlives the buffer: ownership moves to a wl_display sync, whose
// callback cannot run until the compositor has processed everything queued before
// it, create_buffer included. Same contract the EGL shim enforces with a roundtrip
// (x11/wayland/iosc_egl_shim.c, win_alloc_bufs), minus the blocking.
namespace
{
struct PendingPortFree
{
    mach_port_t port;
};

void portFreed(void *data, wl_callback *callback, uint32_t)
{
    auto *pending = static_cast<PendingPortFree *>(data);
    wl_callback_destroy(callback);
    mach_port_deallocate(mach_task_self(), pending->port);
    delete pending;
}

const wl_callback_listener portFreeListener = {portFreed};

void freePortAfterSync(wl_display *display, mach_port_t port)
{
    if (port == MACH_PORT_NULL) {
        return;
    }
    wl_callback *callback = display ? wl_display_sync(display) : nullptr;
    if (!callback) {
        // Nothing was queued (no display), so nothing can still need the name.
        mach_port_deallocate(mach_task_self(), port);
        return;
    }
    wl_callback_add_listener(callback, &portFreeListener, new PendingPortFree{port});
}
}

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
    const mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (port == MACH_PORT_NULL) {
        // Sending name 0 would fail iosc's import, and an import failure there is a
        // fatal protocol error for this connection. Stay buffer-less instead: the
        // layer treats that as "no free render target" and skips the frame.
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: IOSurfaceCreateMachPort failed for" << size;
        return;
    }
    buffer = iosc_iosurface_create_buffer(backend->backend()->display()->iosurface(), uint32_t(port),
        size.width(), size.height(), IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN);
    // Hand the send right to the sync, not to ~IoscEglBuffer(); see portFreed().
    freePortAfterSync(backend->backend()->display()->nativeDisplay(), port);
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
// Caller must have made the context current SURFACELESS first -- NOT on `pbuffer`.
// Once eglBindTexImage binds a pbuffer to a texture, eglMakeCurrent on that same
// pbuffer fails with EGL_BAD_ACCESS, which silently starved the render loop.
bool IoscEglBuffer::ensureRenderTarget()
{
    if (fbo) {
        return true;
    }
    if (pbuffer == EGL_NO_SURFACE) {
        return false;
    }
    // Order matters and is not symmetric: eglBindTexImage associates the pbuffer
    // with whatever texture is currently bound to GL_TEXTURE_2D, so the texture
    // must exist and be bound FIRST. Calling it twice returns EGL_BAD_ACCESS
    // (0x3002) because the surface is already bound, and leaves the FBO's
    // attachment imageless -> GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT (0x8CD6).
    // Same sequence as wayland/xios_egl.c:xios_egl_bind_pbuffer_texture().
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (!eglBindTexImage(display, pbuffer, EGL_BACK_BUFFER)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglBindTexImage failed" << Qt::hex << eglGetError();
        glDeleteTextures(1, &texture);
        texture = 0;
        return false;
    }

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

    // KWIN_IOS_GL_CLEARTEST=1: paint a known colour straight into the IOSurface,
    // bypassing KWin's scene entirely. This splits "the FBO -> IOSurface path is
    // broken" from "the path works but the scene paints nothing" -- two failures
    // that are indistinguishable from the compositor side, since both arrive at
    // iosc as an opaque black surface with no GL errors anywhere.
    // Magenta because it cannot be confused with a cleared/zeroed buffer.
    if (qEnvironmentVariableIsSet("KWIN_IOS_GL_CLEARTEST")) {
        glClearColor(1.0f, 0.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
        // NOTE ON SCOPE: this clear happens at FBO creation, so KWin's scene
        // renders over it before the buffer is ever committed. It therefore proves
        // only that the FBO -> IOSurface transport works; it says NOTHING about
        // what the compositor eventually samples. Do not read a magenta result
        // here as "the pixels reach the screen".
        //
        // Read the SAME pixel two ways to locate where the magenta is lost:
        //   gl=   what GL says is in the framebuffer we just cleared
        //   cpu=  what the IOSurface's own memory holds, which is what iosc
        //         imports by mach port and samples
        // gl magenta + cpu black  -> GL writes never reach IOSurface memory
        //                            (the ANGLE bind/render path is wrong)
        // gl magenta + cpu magenta -> transport is fine; iosc's import or
        //                            sampling of this surface is at fault
        GLubyte gl[4] = {0, 0, 0, 0};
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, gl);
        uint32_t cpu = 0xdeadbeef;
        if (IOSurfaceLock(surface, 0x1 /* kIOSurfaceLockReadOnly */, nullptr) == 0) {
            if (const uint32_t *base = static_cast<const uint32_t *>(IOSurfaceGetBaseAddress(surface))) {
                cpu = base[0];
            }
            IOSurfaceUnlock(surface, 0x1, nullptr);
        }
        qCWarning(KWIN_WAYLAND_BACKEND).nospace()
            << "ios-gpu: CLEARTEST " << size.width() << "x" << size.height()
            << " gl=" << gl[0] << "," << gl[1] << "," << gl[2] << "," << gl[3]
            << " iosurface_cpu=0x" << Qt::hex << cpu;
    }
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
    if (!m_buffer) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "No free Xios IOSurface render target";
        return std::nullopt;
    }
    // Make the context current SURFACELESS, never on m_buffer->pbuffer.
    //
    // eglMakeCurrent fails with EGL_BAD_ACCESS on a pbuffer that is bound to a
    // texture, and ensureRenderTarget() binds every buffer permanently via
    // eglBindTexImage. So making the pbuffer current worked only until each
    // buffer had been used once; after that every frame failed here, the paint
    // pass was skipped -- and present() still shipped the un-rendered buffer,
    // so the compositor kept re-presenting a blank frame with no GL error
    // anywhere. Nothing needs the pbuffer to be current: we render into the FBO
    // that wraps its IOSurface texture, so the draw surface is irrelevant.
    if (!m_backend->openglContext()->makeCurrent()) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: surfaceless makeCurrent failed" << Qt::hex << eglGetError();
        m_buffer = nullptr; // do not let present() attach a buffer we never rendered
        return std::nullopt;
    }
    if (!m_buffer->ensureRenderTarget()) {
        m_buffer = nullptr;
        return std::nullopt;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, m_buffer->fbo);
    return OutputLayerBeginFrameInfo{.renderTarget = RenderTarget(m_buffer->framebuffer.get()), .repaint = m_buffer->repaint};
}

bool WaylandEglPrimaryLayer::doEndFrame(const QRegion &, const QRegion &damagedRegion, OutputFrame *)
{
    if (!setAcquireFence(m_backend, m_buffer)) {
        m_buffer = nullptr;
        return false;
    }
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

    // Declare the output surface fully opaque.
    //
    // These IOSurfaces are BGRA, so the compositor sees a real alpha channel and
    // -- absent an opaque region -- must treat the surface as translucent and
    // blend it (iosc.c:surface_blends()). KWin's OpenGL renderer clears the output
    // background to (0,0,0,0), so a blended output composites to nothing and the
    // screen is black no matter how correct the rendering was. The old QPainter
    // backend was unaffected because it presented XRGB buffers, whose alpha is
    // undefined and which iosc therefore keeps on the opaque fast path.
    //
    // An output surface is opaque by definition -- it is the whole screen -- so
    // this is a statement of fact, not a workaround, and it also puts the frame
    // back on the compositor's cheaper non-blending path.
    if (m_opaqueSize != m_buffer->size) {
        if (auto *compositor = m_backend->backend()->display()->compositor()) {
            // Region is copied by setOpaqueRegion, so it can die immediately after.
            const auto opaque = compositor->createRegion(QRegion(QRect(QPoint(0, 0), m_buffer->size)));
            output->surface()->setOpaqueRegion(opaque.get());
            m_opaqueSize = m_buffer->size;
        }
    }

    output->surface()->attachBuffer(m_buffer->buffer);
    for (const QRect &rect : m_damage) {
        output->surface()->damageBuffer(rect);
    }
    output->surface()->setScale(std::ceil(output->scale()));
    m_buffer->busy = true;
    // MUST request a frame callback. WaylandOutput drives the whole render loop
    // off Surface::frameRendered, which is emitted only from the wl_callback
    // installed here; with CommitFlag::None no callback is installed, the pending
    // OutputFrame is never presented, and KWin renders exactly ONE frame and then
    // waits forever. That is why this backend showed a black screen while the
    // QPainter one did not: it commits via the default argument, which is
    // CommitFlag::FrameCallback.
    output->surface()->commit(KWayland::Client::Surface::CommitFlag::FrameCallback);
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
    if (!m_buffer) {
        return std::nullopt;
    }
    // Surfaceless for the same reason as the primary layer: a pbuffer bound to a
    // texture cannot be made current.
    if (!m_backend->openglContext()->makeCurrent()) {
        m_buffer = nullptr;
        return std::nullopt;
    }
    if (!m_buffer->ensureRenderTarget()) {
        m_buffer = nullptr;
        return std::nullopt;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, m_buffer->fbo);
    return OutputLayerBeginFrameInfo{.renderTarget = RenderTarget(m_buffer->framebuffer.get()), .repaint = infiniteRegion()};
}

bool WaylandEglCursorLayer::doEndFrame(const QRegion &, const QRegion &, OutputFrame *)
{
    if (!setAcquireFence(m_backend, m_buffer)) {
        m_buffer = nullptr;
        return false;
    }
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
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglGetPlatformDisplayEXT is unavailable";
        return false;
    }
    const EGLDisplay handle = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, displayAttributes);
    if (handle == EGL_NO_DISPLAY) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: ANGLE Metal display creation failed" << Qt::hex << eglGetError();
        return false;
    }

    // This backend is unconditionally ANGLE/GLES. KWin's generic EglDisplay::create()
    // asks Qt whether the process uses desktop GL and rejects an otherwise initialized
    // display if a stale pre-initialize EGL error is pending. Both assumptions are
    // wrong for KWin's private iOS QPA process, while this explicit sequence is the
    // same one exercised by iosc-cfgdump and the GPU client smoke.
    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(handle, &major, &minor)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglInitialize failed" << Qt::hex << eglGetError();
        return false;
    }
    const EGLint initializeError = eglGetError();
    if (initializeError != EGL_SUCCESS) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: ignoring stale EGL error after successful initialize"
                                       << Qt::hex << initializeError;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglBindAPI(OpenGL ES) failed" << Qt::hex << eglGetError();
        eglTerminate(handle);
        return false;
    }
    const char *extensionString = eglQueryString(handle, EGL_EXTENSIONS);
    const QList<QByteArray> extensions = extensionString
        ? QByteArray(extensionString).split(' ')
        : QList<QByteArray>{};
    if (!extensions.contains(QByteArrayLiteral("EGL_KHR_no_config_context"))
        || !extensions.contains(QByteArrayLiteral("EGL_KHR_surfaceless_context"))) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: ANGLE lacks required surfaceless/no-config EGL extensions";
        eglTerminate(handle);
        return false;
    }
    auto display = std::make_unique<EglDisplay>(handle, extensions);
    qCInfo(KWIN_WAYLAND_BACKEND) << "ios-gpu: ANGLE Metal EGL initialized" << major << "." << minor;
    m_backend->setEglDisplay(std::move(display));
    setEglDisplay(m_backend->sceneEglDisplayObject());

    m_config = chooseIoscEglConfig(eglDisplayObject()->handle());
    if (m_config == EGL_NO_CONFIG_KHR) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: no IOSurface-compatible EGL config" << Qt::hex << eglGetError();
    }
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
