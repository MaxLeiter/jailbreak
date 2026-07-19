/* KWin QPA EGL context backed by ANGLE IOSurface pbuffers on Xios. */
#include "eglplatformcontext.h"

#include "backends/wayland/iosc_egl_helpers.h"
#include "core/outputbackend.h"
#include "eglhelpers.h"
#include "internalwindow.h"
#include "logging.h"
#include "opengl/eglcontext.h"
#include "opengl/egldisplay.h"
#include "opengl/glutils.h"
#include "swapchain.h"
#include "window.h"

#include <drm_fourcc.h>
#include <epoxy/gl.h>

namespace KWin::QPA
{
EGLRenderTarget::EGLRenderTarget(GraphicsBuffer *buffer, EGLDisplay display, EGLSurface surface)
    : buffer(buffer)
    , display(display)
    , surface(surface)
{
}

EGLRenderTarget::~EGLRenderTarget()
{
    if (surface != EGL_NO_SURFACE) {
        eglDestroySurface(display, surface);
    }
}

EGLPlatformContext::EGLPlatformContext(QOpenGLContext *context, EglDisplay *display)
    : m_eglDisplay(display)
{
    create(context->format(), kwinApp()->outputBackend()->sceneEglGlobalShareContext());
}

EGLPlatformContext::~EGLPlatformContext()
{
    m_current.reset();
    m_renderTargets.clear();
    m_zombieRenderTargets.clear();
}

bool EGLPlatformContext::makeCurrent(QPlatformSurface *surface)
{
    if (!m_eglContext || !m_eglContext->makeCurrent()) {
        return false;
    }
    if (m_eglContext->checkGraphicsResetStatus() != GL_NO_ERROR) {
        m_renderTargets.clear();
        m_zombieRenderTargets.clear();
        m_eglContext.reset();
        return false;
    }

    // Retired pbuffers are destroyed only after the shared context is current
    // without one of them bound.
    m_zombieRenderTargets.clear();
    if (surface->surface()->surfaceClass() != QSurface::Window) {
        return true;
    }

    auto *window = static_cast<Window *>(surface);
    static const QHash<uint32_t, QList<uint64_t>> formats = {
        {DRM_FORMAT_ARGB8888, {DRM_FORMAT_MOD_LINEAR}},
    };
    auto *swapchain = window->swapchain(m_eglContext, formats);
    if (!swapchain) {
        return false;
    }
    GraphicsBuffer *graphicsBuffer = swapchain->acquire();
    void *iosurface = graphicsBuffer->iosurface();
    if (!iosurface) {
        return false;
    }

    auto it = m_renderTargets.find(graphicsBuffer);
    if (it == m_renderTargets.end()) {
        EGLSurface pbuffer = createIoscEglPbuffer(m_eglDisplay->handle(), m_config, iosurface, graphicsBuffer->size());
        if (pbuffer == EGL_NO_SURFACE) {
            return false;
        }
        auto target = std::make_shared<EGLRenderTarget>(graphicsBuffer, m_eglDisplay->handle(), pbuffer);
        it = m_renderTargets.emplace(graphicsBuffer, target).first;
        QObject::connect(graphicsBuffer, &QObject::destroyed, this, [this, graphicsBuffer]() {
            auto found = m_renderTargets.find(graphicsBuffer);
            if (found == m_renderTargets.end()) {
                return;
            }
            m_zombieRenderTargets.push_back(std::move(found->second));
            m_renderTargets.erase(found);
        });
    }

    m_current = it->second;
    if (!m_eglContext->makeCurrent(m_current->surface)) {
        return false;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return true;
}

void EGLPlatformContext::doneCurrent()
{
    if (m_eglContext) {
        m_eglContext->doneCurrent();
    }
}

bool EGLPlatformContext::isValid() const
{
    return bool(m_eglContext);
}

bool EGLPlatformContext::isSharing() const
{
    return false;
}

QSurfaceFormat EGLPlatformContext::format() const
{
    return m_format;
}

QFunctionPointer EGLPlatformContext::getProcAddress(const char *name)
{
    return eglGetProcAddress(name);
}

void EGLPlatformContext::swapBuffers(QPlatformSurface *surface)
{
    if (surface->surface()->surfaceClass() != QSurface::Window || !m_current) {
        return;
    }
    auto *window = static_cast<Window *>(surface);
    if (InternalWindow *internal = window->internalWindow()) {
        glFinish();
        internal->present(InternalWindowFrame{
            .buffer = m_current->buffer,
            .bufferDamage = QRect(QPoint(0, 0), m_current->buffer->size()),
            .bufferOrigin = GraphicsBufferOrigin::BottomLeft,
        });
    }
    m_current.reset();
}

GLuint EGLPlatformContext::defaultFramebufferObject(QPlatformSurface *) const
{
    return 0;
}

void EGLPlatformContext::create(const QSurfaceFormat &format, ::EGLContext shareContext)
{
    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        return;
    }
    m_config = configFromFormat(m_eglDisplay, format, EGL_PBUFFER_BIT);
    if (m_config == EGL_NO_CONFIG_KHR) {
        return;
    }
    m_format = formatFromConfig(m_eglDisplay, m_config);
    m_eglContext = EglContext::create(m_eglDisplay, m_config, shareContext);
    if (m_eglContext) {
        updateFormatFromContext();
    }
}

void EGLPlatformContext::updateFormatFromContext()
{
    if (!m_eglContext->makeCurrent()) {
        return;
    }
    const char *version = reinterpret_cast<const char *>(glGetString(GL_VERSION));
    int major = 0;
    int minor = 0;
    if (version && parseOpenGLVersion(QByteArray(version), major, minor)) {
        m_format.setMajorVersion(major);
        m_format.setMinorVersion(minor);
    }
    m_format.setProfile(QSurfaceFormat::NoProfile);
    m_format.setRenderableType(QSurfaceFormat::OpenGLES);
}
}
