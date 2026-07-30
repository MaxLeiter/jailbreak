/*
 * iosc-cfgdump.c — enumerate ANGLE-Metal's EGL configs (read-only diagnostic).
 * Determines whether any config satisfies GDK's needs (RGBA8 + ES3-renderable)
 * AND the iosurface pbuffer's need (bind-to-texture-rgba) — i.e. whether the
 * wayland-egl shim can present a single config that makes GTK4's GL renderer go.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <stdio.h>

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

int main(void)
{
    const char *client_extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    printf("EGL client extensions: %s\n\n", client_extensions ? client_extensions : "(null)");
    EGLDisplay (*getPD)(EGLenum,void*,const EGLint*) = (void*)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!getPD) { printf("FAIL eglGetPlatformDisplayEXT missing\n"); return 1; }
    const EGLint da[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    EGLDisplay d = getPD(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, da);
    if (d == EGL_NO_DISPLAY || !eglInitialize(d, 0, 0)) { printf("FAIL eglInitialize 0x%x\n", eglGetError()); return 1; }
    printf("EGL vendor: %s\n", eglQueryString(d, EGL_VENDOR));
    printf("EGL version: %s\n", eglQueryString(d, EGL_VERSION));
    printf("EGL extensions: %s\n\n", eglQueryString(d, EGL_EXTENSIONS));

    EGLint total = 0; eglGetConfigs(d, 0, 0, &total);
    EGLConfig cfgs[256]; if (total > 256) total = 256;
    eglGetConfigs(d, cfgs, total, &total);
    printf("ANGLE-Metal: %d configs\n", total);
    printf("idx  R G B A  D S  surfaceType renderable bindRGBA  (W=window P=pbuffer)\n");

    int es3_rgba8_pbuf_bind = 0, es3_rgba8_window = 0;
    for (int i = 0; i < total; i++) {
        EGLint r=0,g=0,b=0,a=0,dep=0,st=0,stype=0,rtype=0,bind=0;
        eglGetConfigAttrib(d, cfgs[i], EGL_RED_SIZE, &r);
        eglGetConfigAttrib(d, cfgs[i], EGL_GREEN_SIZE, &g);
        eglGetConfigAttrib(d, cfgs[i], EGL_BLUE_SIZE, &b);
        eglGetConfigAttrib(d, cfgs[i], EGL_ALPHA_SIZE, &a);
        eglGetConfigAttrib(d, cfgs[i], EGL_DEPTH_SIZE, &dep);
        eglGetConfigAttrib(d, cfgs[i], EGL_STENCIL_SIZE, &st);
        eglGetConfigAttrib(d, cfgs[i], EGL_SURFACE_TYPE, &stype);
        eglGetConfigAttrib(d, cfgs[i], EGL_RENDERABLE_TYPE, &rtype);
        eglGetConfigAttrib(d, cfgs[i], EGL_BIND_TO_TEXTURE_RGBA, &bind);
        char sb[8]; int k=0;
        if (stype & EGL_WINDOW_BIT) sb[k++]='W';
        if (stype & EGL_PBUFFER_BIT) sb[k++]='P';
        sb[k]=0;
        int es3 = (rtype & 0x0040) != 0;   /* EGL_OPENGL_ES3_BIT_KHR = 0x0040 */
        if (i < 24)
            printf("%3d  %d %d %d %d  %d %d  0x%-3x[%s]   0x%-4x      %d\n",
                   i, r,g,b,a, dep,st, stype, sb, rtype, bind);
        if (es3 && r==8&&g==8&&b==8&&a==8) {
            if (stype & EGL_WINDOW_BIT) es3_rgba8_window++;
            if ((stype & EGL_PBUFFER_BIT) && bind) es3_rgba8_pbuf_bind++;
        }
    }
    printf("\nES3+RGBA8 window configs: %d\n", es3_rgba8_window);
    printf("ES3+RGBA8 pbuffer+bindRGBA configs: %d  <- shim needs >=1 of these\n", es3_rgba8_pbuf_bind);
    return 0;
}
