/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-onscreen-ios.h — a CoglOnscreen whose EGLSurface is the output IOSurface pbuffer.
 *
 * MetaRendererIOS renders the stage into the Xios app's output IOSurface. ANGLE-Metal has
 * no working IOSurface->EGLImage for a render target (eglCreateImageKHR(GL_TEXTURE_2D) fails
 * 0x3000), and the mutter cogl fork dropped the foreign-GL-texture wrap, so the IOSurface
 * cannot be wrapped as an offscreen. Instead we bind it as the DEFAULT framebuffer (FBO 0):
 * the view's framebuffer is a CoglOnscreenEgl whose EGLSurface is the ANGLE iosurface pbuffer
 * (EGL_ANGLE_iosurface_client_buffer, the proven pbuffer-as-FBO-0 path). Cogl then renders to
 * FBO 0 == the IOSurface with no copy. This subclass only overrides the present: a pbuffer has
 * no swappable back buffer, so swap_buffers_with_damage does cogl_framebuffer_finish (commit the
 * writes to Metal) + xios_notify_dirty (nudge the Xios app to re-present), NOT eglSwapBuffers.
 * GPL-2.0+, modeled on meta-onscreen-native.c.
 */
#pragma once

/* cogl/cogl.h (the mutter fork) includes cogl-mutter.h, which exposes CoglOnscreenEgl +
 * CoglOnscreenEglClass — same as meta-onscreen-native.h. Do NOT include the winsys header
 * directly (it trips cogl's "Only <cogl/cogl.h> can be included directly" guard). */
#include "cogl/cogl.h"

#define META_TYPE_ONSCREEN_IOS (meta_onscreen_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaOnscreenIOS, meta_onscreen_ios,
                      META, ONSCREEN_IOS, CoglOnscreenEgl)

/* Allocate an onscreen for the output IOSurface pbuffer. The caller must, before allocating
 * the framebuffer, set the EGLSurface with cogl_onscreen_egl_set_egl_surface() to the pbuffer
 * from xios_egl_create_iosurface_pbuffer(). `width`/`height` are the output pixel size. */
MetaOnscreenIOS *meta_onscreen_ios_new (CoglContext *cogl_context,
                                        int          width,
                                        int          height);
