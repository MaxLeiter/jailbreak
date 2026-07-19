/* Shared ANGLE IOSurface EGL setup for KWin's Xios rendering paths. */
#pragma once

#include <QSize>
#include <epoxy/egl.h>
#include <epoxy/gl.h>

#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE 0x3454
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
#define EGL_TEXTURE_TYPE_ANGLE 0x345E
#endif

namespace KWin
{
inline EGLConfig chooseIoscEglConfig(EGLDisplay display)
{
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
        EGL_NONE,
    };
    EGLConfig config = EGL_NO_CONFIG_KHR;
    EGLint count = 0;
    return eglChooseConfig(display, attributes, &config, 1, &count) && count == 1
        ? config
        : EGL_NO_CONFIG_KHR;
}

inline EGLSurface createIoscEglPbuffer(EGLDisplay display, EGLConfig config, void *iosurface, const QSize &size)
{
    const EGLint attributes[] = {
        EGL_WIDTH, size.width(),
        EGL_HEIGHT, size.height(),
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE,
    };
    return eglCreatePbufferFromClientBuffer(display, EGL_IOSURFACE_ANGLE,
        reinterpret_cast<EGLClientBuffer>(iosurface), config, attributes);
}
}
