/* Xios GPU path for KWin: see iosc_gpu_support.h. */
#include "iosc_gpu_support.h"

#include "core/drmdevice.h"
#include "core/renderdevice.h"
#include "iosc-iosurface-client-protocol.h"
#include "iosc_egl_helpers.h"
#include "opengl/eglcontext.h"
#include "opengl/egldisplay.h"
#include "wayland/ioscclientbuffer.h"
#include "wayland_display.h"
#include "wayland_logging.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>

#include <wayland-client-core.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

extern "C" int xios_metal_sync_signal(EGLDisplay display, const void **token, size_t *tokenSize, uint64_t *value);

namespace KWin
{

IoscSurfaceTexture::IoscSurfaceTexture(EGLDisplay display, EGLSurface pbuffer, uint textureId, const QSize &size, OutputTransform transform)
    : GLTexture(GL_TEXTURE_2D, textureId, GL_RGBA8, size, 1, true, transform)
    , m_display(display)
    , m_pbuffer(pbuffer)
{
}

IoscSurfaceTexture::~IoscSurfaceTexture()
{
    // The binding must be dropped before the texture (deleted by ~GLTexture) and the pbuffer go away.
    eglReleaseTexImage(m_display, m_pbuffer, EGL_BACK_BUFFER);
    eglDestroySurface(m_display, m_pbuffer);
}

std::unique_ptr<GLTexture> createIoscSurfaceTexture(EGLDisplay display, void *iosurface, const QSize &size, OutputTransform transform)
{
    const EGLConfig config = chooseIoscEglConfig(display);
    if (config == EGL_NO_CONFIG_KHR) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: no IOSurface-compatible EGL config" << Qt::hex << eglGetError();
        return nullptr;
    }
    EGLSurface pbuffer = createIoscEglPbuffer(display, config, iosurface, size);
    if (pbuffer == EGL_NO_SURFACE) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: IOSurface pbuffer failed, size" << size << "egl" << Qt::hex << eglGetError();
        return nullptr;
    }
    // Order matters: the texture must exist and be bound BEFORE eglBindTexImage, and binding twice is EGL_BAD_ACCESS.
    GLuint texture = 0;
    glGenTextures(1, &texture);
    if (!texture) {
        eglDestroySurface(display, pbuffer);
        return nullptr;
    }
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (!eglBindTexImage(display, pbuffer, EGL_BACK_BUFFER)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglBindTexImage failed" << Qt::hex << eglGetError();
        glBindTexture(GL_TEXTURE_2D, 0);
        glDeleteTextures(1, &texture);
        eglDestroySurface(display, pbuffer);
        return nullptr;
    }
    glBindTexture(GL_TEXTURE_2D, 0);
    return std::make_unique<IoscSurfaceTexture>(display, pbuffer, texture, size, transform);
}

std::shared_ptr<GLTexture> importIoscBufferAsTexture(EglContext *context, GraphicsBuffer *buffer)
{
    return createIoscSurfaceTexture(context->displayObject()->handle(), buffer->iosurface(), buffer->size(), OutputTransform::Normal);
}

GraphicsBufferAllocator *ioscGpuAllocator()
{
    static IoscGraphicsBufferAllocator allocator;
    return &allocator;
}

std::unique_ptr<RenderDevice> createIoscRenderDevice()
{
    const EGLint displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE,
    };
    auto getPlatformDisplay = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!getPlatformDisplay) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglGetPlatformDisplayEXT is unavailable";
        return nullptr;
    }
    const EGLDisplay handle = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, displayAttributes);
    if (handle == EGL_NO_DISPLAY) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: ANGLE Metal display creation failed" << Qt::hex << eglGetError();
        return nullptr;
    }

    // EglDisplay::create() is not used on purpose: it asks Qt whether the process uses desktop GL and rejects an
    // otherwise initialized display when a stale pre-initialize EGL error is pending. This stack is
    // unconditionally ANGLE/GLES; the explicit sequence below is the one exercised by iosc-cfgdump and the GPU
    // client smoke.
    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(handle, &major, &minor)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglInitialize failed" << Qt::hex << eglGetError();
        return nullptr;
    }
    const EGLint initializeError = eglGetError();
    if (initializeError != EGL_SUCCESS) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: ignoring stale EGL error after successful initialize" << Qt::hex << initializeError;
    }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: eglBindAPI(OpenGL ES) failed" << Qt::hex << eglGetError();
        eglTerminate(handle);
        return nullptr;
    }
    const char *extensionString = eglQueryString(handle, EGL_EXTENSIONS);
    const QList<QByteArray> extensions = extensionString ? QByteArray(extensionString).split(' ') : QList<QByteArray>{};
    if (!extensions.contains(QByteArrayLiteral("EGL_KHR_no_config_context"))
        || !extensions.contains(QByteArrayLiteral("EGL_KHR_surfaceless_context"))) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: ANGLE lacks required surfaceless/no-config EGL extensions";
        eglTerminate(handle);
        return nullptr;
    }
    qCInfo(KWIN_WAYLAND_BACKEND) << "ios-gpu: ANGLE Metal EGL initialized" << major << "." << minor;
    auto display = std::make_unique<EglDisplay>(handle, extensions, nullptr);
    return std::make_unique<RenderDevice>(std::unique_ptr<DrmDevice>(), std::move(display));
}

bool ioscSignalAcquireFence(EGLDisplay display, GraphicsBuffer *buffer)
{
    auto *ioscBuffer = dynamic_cast<IoscClientBuffer *>(buffer);
    const void *token = nullptr;
    size_t tokenSize = 0;
    uint64_t value = 0;
    if (!ioscBuffer || !xios_metal_sync_signal(display, &token, &tokenSize, &value) || !token || tokenSize != 32 || value == 0) {
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: failed to export mandatory Metal acquire fence";
        return false;
    }
    ioscBuffer->setPendingAcquireFence(token, tokenSize, value);
    return true;
}

// Freeing the IOSurface mach port: a send right handed to iosc must outlive the request that carries its NAME.
//
// The name in iosc_iosurface.create_buffer is a one-shot handoff token. iosc extracts its own COPY_SEND right
// (mach_port_extract_right on our task) while it processes that request, which happens whenever iosc gets round to
// draining its socket -- not when we send it. Deallocating the port when the buffer dies races with that: a buffer
// can be constructed and destroyed inside the window where its create_buffer is still queued, iosc then fails the
// extract and answers with a protocol error, which is fatal for the whole Plasma session. Mach names are also
// recycled, so a freed name can be re-issued to an unrelated port and imported as if it were ours.
//
// So ownership moves to a wl_display sync, whose callback cannot run until the compositor has processed everything
// queued before it, create_buffer included. Same contract the EGL shim enforces with a roundtrip
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
        mach_port_deallocate(mach_task_self(), port);
        return;
    }
    wl_callback_add_listener(callback, &portFreeListener, new PendingPortFree{port});
}
}

wl_buffer *ioscCreateWlBuffer(Wayland::WaylandDisplay *display, GraphicsBuffer *buffer)
{
    IOSurfaceRef surface = static_cast<IOSurfaceRef>(buffer->iosurface());
    if (!surface || !display->iosurface()) {
        return nullptr;
    }
    const mach_port_t port = IOSurfaceCreateMachPort(surface);
    if (port == MACH_PORT_NULL) {
        // Sending name 0 would fail iosc's import, which is a fatal protocol error for this connection.
        qCWarning(KWIN_WAYLAND_BACKEND) << "ios-gpu: IOSurfaceCreateMachPort failed for" << buffer->size();
        return nullptr;
    }
    wl_buffer *handle = iosc_iosurface_create_buffer(display->iosurface(), uint32_t(port),
        buffer->size().width(), buffer->size().height(), IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN);
    freePortAfterSync(display->nativeDisplay(), port);
    return handle;
}

void ioscApplyAcquireFence(Wayland::WaylandDisplay *display, wl_buffer *wlBuffer, GraphicsBuffer *buffer)
{
    auto *ioscBuffer = dynamic_cast<IoscClientBuffer *>(buffer);
    if (!ioscBuffer || !wlBuffer || !display->iosurface()) {
        return;
    }
    QByteArray token;
    uint64_t value = 0;
    if (!ioscBuffer->pendingAcquireFence(&token, &value)) {
        return;
    }
    wl_array tokenArray = {};
    tokenArray.size = token.size();
    tokenArray.alloc = token.size();
    tokenArray.data = token.data();
    iosc_iosurface_set_acquire_fence(display->iosurface(), wlBuffer, &tokenArray, uint32_t(value), uint32_t(value >> 32));
}

} // namespace KWin
