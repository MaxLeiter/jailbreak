/* Shared ANGLE IOSurface EGL setup for KWin's Xios rendering paths. */
#pragma once

#include <QSize>
#include <epoxy/egl.h>
#include <epoxy/gl.h>

/* EGL_ANGLE_iosurface_client_buffer. These are ANGLE-private and absent from the
 * Khronos egl.xml epoxy generates from, so they must be declared here -- but each
 * one is guarded individually. A single #ifndef around the whole block is what let
 * a mis-transcribed value survive: if any future header defines one of these, the
 * others would silently keep hand-written values.
 *
 * Values must match EGL/eglext_angle.h. Getting EGL_TEXTURE_TYPE_ANGLE wrong is not
 * a compile error -- it makes eglCreatePbufferFromClientBuffer fail EGL_BAD_ATTRIBUTE
 * (0x3004) at runtime, because 0x345E is EGL_PLATFORM_ANGLE_DEVICE_TYPE_NULL_ANGLE,
 * a display attribute that is not legal in a pbuffer attribute list. */
#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE 0x3454
#endif
#ifndef EGL_IOSURFACE_PLANE_ANGLE
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#endif
#ifndef EGL_TEXTURE_RECTANGLE_ANGLE
#define EGL_TEXTURE_RECTANGLE_ANGLE 0x345B
#endif
#ifndef EGL_TEXTURE_TYPE_ANGLE
#define EGL_TEXTURE_TYPE_ANGLE 0x345C
#endif
#ifndef EGL_TEXTURE_INTERNAL_FORMAT_ANGLE
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
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
