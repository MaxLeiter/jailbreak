/*
 * iosc-fbtest.c — decisive de-risk for the wayland-egl↔ANGLE shim.
 *
 * Question: can ANGLE-Metal render to an IOSurface-backed pbuffer as the DEFAULT
 * framebuffer (FBO 0)? GDK/GSK render to FBO 0; if a client-buffer pbuffer is
 * renderable as FBO 0, the shim is fully zero-copy (eglSwapBuffers just hands the
 * IOSurface to iosc). If NOT, the shim must render to a normal pbuffer and
 * GPU-blit into an IOSurface at swap.
 *
 * Test: make an IOSurface pbuffer, eglMakeCurrent on it (no explicit FBO),
 * glClear green, then read the IOSurface back. Green = renderable as FBO 0.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <stdio.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_IOSURFACE_ANGLE
#define EGL_IOSURFACE_ANGLE 0x3454
#define EGL_IOSURFACE_PLANE_ANGLE 0x345A
#define EGL_TEXTURE_TYPE_ANGLE 0x345C
#define EGL_TEXTURE_INTERNAL_FORMAT_ANGLE 0x345D
#endif
#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif
#define LOCK_RO 1u

static void num(CFMutableDictionaryRef d, CFStringRef k, int32_t v)
{ CFNumberRef n = CFNumberCreate(0, kCFNumberSInt32Type, &v); CFDictionarySetValue(d,k,n); CFRelease(n); }

int main(void)
{
    const int W = 256, H = 256;
    size_t bpr = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, W*4);
    size_t al  = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bpr*H);
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(0,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    num(d,kIOSurfaceWidth,W); num(d,kIOSurfaceHeight,H); num(d,kIOSurfaceBytesPerElement,4);
    num(d,kIOSurfaceBytesPerRow,(int)bpr); num(d,kIOSurfaceAllocSize,(int)al);
    num(d,kIOSurfacePixelFormat,0x42475241);
    IOSurfaceRef s = IOSurfaceCreate(d); CFRelease(d);
    if(!s){ printf("FAIL IOSurfaceCreate\n"); return 1; }

    EGLDisplay (*getPD)(EGLenum,void*,const EGLint*) = (void*)eglGetProcAddress("eglGetPlatformDisplayEXT");
    const EGLint da[]={EGL_PLATFORM_ANGLE_TYPE_ANGLE,EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,EGL_NONE};
    EGLDisplay dpy=getPD(EGL_PLATFORM_ANGLE_ANGLE,EGL_DEFAULT_DISPLAY,da);
    eglInitialize(dpy,0,0);
    const EGLint ca[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,
        EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,
        EGL_BIND_TO_TEXTURE_RGBA,EGL_TRUE,EGL_NONE};
    EGLConfig cfg; EGLint n=0; eglChooseConfig(dpy,ca,&cfg,1,&n);
    if(!n){ printf("FAIL no config\n"); return 1; }
    const EGLint cx[]={EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE};
    EGLContext ctx=eglCreateContext(dpy,cfg,EGL_NO_CONTEXT,cx);
    const EGLint pa[]={EGL_WIDTH,W,EGL_HEIGHT,H,EGL_IOSURFACE_PLANE_ANGLE,0,
        EGL_TEXTURE_TARGET,EGL_TEXTURE_2D,EGL_TEXTURE_INTERNAL_FORMAT_ANGLE,GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT,EGL_TEXTURE_RGBA,EGL_TEXTURE_TYPE_ANGLE,GL_UNSIGNED_BYTE,EGL_NONE};
    EGLSurface pb=eglCreatePbufferFromClientBuffer(dpy,EGL_IOSURFACE_ANGLE,(EGLClientBuffer)s,cfg,pa);
    if(pb==EGL_NO_SURFACE){ printf("FAIL pbuffer 0x%x\n",eglGetError()); return 1; }

    if(!eglMakeCurrent(dpy,pb,pb,ctx)){ printf("FAIL makeCurrent 0x%x\n",eglGetError()); return 1; }
    printf("GL_RENDERER=%s\n", glGetString(GL_RENDERER));
    /* Render to the DEFAULT framebuffer (FBO 0) — NO explicit FBO. */
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    printf("default-FBO status=0x%x (0x8CD5=COMPLETE)\n", glCheckFramebufferStatus(GL_FRAMEBUFFER));
    glViewport(0,0,W,H);
    glClearColor(0.f,1.f,0.f,1.f);   /* green */
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    printf("GL error after clear=0x%x\n", glGetError());

    /* Read the IOSurface back. */
    IOSurfaceLock(s,LOCK_RO,0);
    unsigned char *p=IOSurfaceGetBaseAddress(s);
    size_t st=IOSurfaceGetBytesPerRow(s);
    unsigned int px=*(unsigned int*)(p + (H/2)*st + (W/2)*4);
    IOSurfaceUnlock(s,LOCK_RO,0);
    printf("IOSurface center BGRA=0x%08x  (green=0xff00ff00 => default-FB render WORKS)\n", px);
    printf(px==0xff00ff00 ? "RESULT: ZERO-COPY OK (iosurface pbuffer renderable as FBO 0)\n"
                          : "RESULT: needs FBO+blit fallback (FBO 0 did not reach the IOSurface)\n");
    return 0;
}
