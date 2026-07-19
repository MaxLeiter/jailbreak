/* KWin QPA EGL context backed by ANGLE IOSurface pbuffers on Xios. */
#pragma once

#include <QObject>
#include <epoxy/egl.h>
#include <qpa/qplatformopenglcontext.h>
#include <memory>
#include <unordered_map>
#include <vector>

namespace KWin
{
class EglContext;
class EglDisplay;
class GraphicsBuffer;

namespace QPA
{
class EGLRenderTarget
{
public:
    EGLRenderTarget(GraphicsBuffer *buffer, EGLDisplay display, EGLSurface surface);
    ~EGLRenderTarget();

    GraphicsBuffer *buffer;
    EGLDisplay display;
    EGLSurface surface;
};

class EGLPlatformContext : public QObject, public QPlatformOpenGLContext
{
public:
    EGLPlatformContext(QOpenGLContext *context, EglDisplay *display);
    ~EGLPlatformContext() override;

    bool makeCurrent(QPlatformSurface *surface) override;
    void doneCurrent() override;
    bool isValid() const override;
    bool isSharing() const override;
    QSurfaceFormat format() const override;
    GLuint defaultFramebufferObject(QPlatformSurface *surface) const override;
    QFunctionPointer getProcAddress(const char *procName) override;
    void swapBuffers(QPlatformSurface *surface) override;

private:
    void create(const QSurfaceFormat &format, ::EGLContext shareContext);
    void updateFormatFromContext();
    EglDisplay *const m_eglDisplay;
    QSurfaceFormat m_format;
    EGLConfig m_config = EGL_NO_CONFIG_KHR;
    std::shared_ptr<EglContext> m_eglContext;
    std::unordered_map<GraphicsBuffer *, std::shared_ptr<EGLRenderTarget>> m_renderTargets;
    std::vector<std::shared_ptr<EGLRenderTarget>> m_zombieRenderTargets;
    std::shared_ptr<EGLRenderTarget> m_current;
};
}
}
