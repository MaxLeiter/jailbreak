/* Host probe for the iOS epoxy GLX/desktop-GL loader (patch 0002).
 *
 * epoxy is built natively on macOS with the same __APPLE__ code path the iOS
 * build takes, and EPOXY_IOS_LIBGL pointed at stub-libgl.c's dylib. With a
 * "GLX context" current, every desktop GL call must land in that stub: the
 * GL bootstrap (glGetString), a core 1.x dlsym (glClear), and a GL 3.0 entry
 * the stub only hands out through glXGetProcAddressARB (glGenVertexArrays).
 * Unpatched epoxy sends all of them to OpenGL.framework instead (an abort on
 * iOS, which has no such framework).
 *
 *   glx-loader-probe <path-to-stub-libGL.dylib>
 */
#include <epoxy/gl.h>
#include <epoxy/glx.h>
#include <dlfcn.h>
#include <stdio.h>

static int failures;

#define CHECK(cond, ...) do { \
    if (cond) { printf("ok   "); } else { printf("FAIL "); failures++; } \
    printf(__VA_ARGS__); printf("\n"); \
} while (0)

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <stub libGL path>\n", argv[0]);
        return 2;
    }
    /* Unbuffered: the unpatched build crashes inside OpenGL.framework. */
    setvbuf(stdout, NULL, _IONBF, 0);
    /* The stub never dereferences the display. */
    Display *dpy = (Display *)(void *)0x1234;

    CHECK(epoxy_has_glx(dpy), "epoxy_has_glx() finds GLX in the libGL");
    CHECK(epoxy_glx_version(dpy, 0) == 14, "epoxy_glx_version() == 14");

    void *gl = dlopen(argv[1], RTLD_NOW | RTLD_NOLOAD);
    CHECK(gl != NULL, "epoxy dlopened the libGL path it was built with");
    if (!gl)
        return 1;

    void (*make_current)(Display *, int) = (void (*)(Display *, int))dlsym(gl, "stub_make_current");
    int *n_getstring = dlsym(gl, "stub_calls_glGetString");
    int *n_clear = dlsym(gl, "stub_calls_glClear");
    int *n_vao = dlsym(gl, "stub_calls_glGenVertexArrays");
    int *n_gpa = dlsym(gl, "stub_calls_getprocaddress");
    if (!make_current || !n_getstring || !n_clear || !n_vao || !n_gpa) {
        printf("FAIL stub hooks missing\n");
        return 1;
    }
    make_current(dpy, 1);

    int version = epoxy_gl_version();
    CHECK(*n_getstring > 0, "glGetString bootstrap resolved from the libGL (%d calls)", *n_getstring);
    CHECK(version == 33, "epoxy_gl_version() == 33 (got %d)", version);
    CHECK(epoxy_is_desktop_gl(), "context reads as desktop GL");

    glClear(0);
    CHECK(*n_clear == 1, "glClear (GL 1.0, dlsym) reached the libGL");

    GLuint vao = 0;
    glGenVertexArrays(1, &vao);
    CHECK(*n_vao == 1 && vao == 42, "glGenVertexArrays (GL 3.0) resolved via glXGetProcAddressARB");
    CHECK(*n_gpa > 0, "glXGetProcAddressARB was used (%d calls)", *n_gpa);

    void *fw = dlopen("/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL",
                      RTLD_LAZY | RTLD_NOLOAD);
    CHECK(fw == NULL, "OpenGL.framework was never loaded");

    printf(failures ? "FAILED (%d)\n" : "PASS\n", failures);
    return failures ? 1 : 0;
}
