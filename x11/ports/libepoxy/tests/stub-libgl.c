/* Stand-in for mesa's libGL.1.dylib (GLX + desktop GL in one library), for
 * host-glx-loader-test.sh. It answers just enough GLX for epoxy_has_glx() /
 * epoxy_glx_version() and the GL bootstrap, and counts every call so the
 * probe can prove which library epoxy routed each entrypoint to. */
#include <stddef.h>
#include <string.h>

typedef unsigned int GLenum;
typedef unsigned int GLbitfield;
typedef int GLint;
typedef int GLsizei;
typedef unsigned int GLuint;
typedef unsigned char GLubyte;
typedef void *Display;
typedef void *GLXContext;

#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_EXTENSIONS 0x1F03
#define GL_NUM_EXTENSIONS 0x821D
#define GLX_SCREEN 0x800C

int stub_calls_glGetString;
int stub_calls_glClear;
int stub_calls_glGenVertexArrays;
int stub_calls_getprocaddress;

static GLXContext current_ctx;
static Display *current_dpy;

/* Test hook: pretend a GLX context became current (glXMakeContextCurrent). */
void stub_make_current(Display *dpy, int on)
{
    current_dpy = on ? dpy : NULL;
    current_ctx = on ? (GLXContext)(void *)0x1 : NULL;
}

int glXQueryExtension(Display *dpy, int *error_base, int *event_base)
{
    (void)dpy;
    if (error_base) *error_base = 0;
    if (event_base) *event_base = 0;
    return 1;
}

const char *glXQueryServerString(Display *dpy, int screen, int name)
{
    (void)dpy; (void)screen; (void)name;
    return "1.4";
}

const char *glXGetClientString(Display *dpy, int name)
{
    (void)dpy;
    return name == 1 ? "Mesa Project and SGI" : "1.4";
}

const char *glXQueryExtensionsString(Display *dpy, int screen)
{
    (void)dpy; (void)screen;
    return "GLX_ARB_create_context GLX_ARB_create_context_profile GLX_ARB_get_proc_address";
}

GLXContext glXGetCurrentContext(void) { return current_ctx; }
Display *glXGetCurrentDisplay(void) { return current_dpy; }

int glXQueryContext(Display *dpy, GLXContext ctx, int attribute, int *value)
{
    (void)dpy; (void)ctx;
    if (attribute == GLX_SCREEN && value) *value = 0;
    return 0;
}

const GLubyte *glGetString(GLenum name)
{
    stub_calls_glGetString++;
    switch (name) {
    case GL_VERSION: return (const GLubyte *)"3.3 (Core Profile) Mesa 21.0.2";
    case GL_VENDOR: return (const GLubyte *)"Mesa/X.org";
    case GL_RENDERER: return (const GLubyte *)"softpipe";
    case GL_EXTENSIONS: return (const GLubyte *)"";
    }
    return NULL;
}

void glGetIntegerv(GLenum pname, GLint *data)
{
    if (data) *data = (pname == GL_NUM_EXTENSIONS) ? 1 : 0;
}

const GLubyte *glGetStringi(GLenum name, GLuint index)
{
    (void)name; (void)index;
    return (const GLubyte *)"GL_ARB_vertex_array_object";
}

void glClear(GLbitfield mask)
{
    (void)mask;
    stub_calls_glClear++;
}

/* Deliberately NOT exported by name: mesa only hands out some entrypoints
 * through glXGetProcAddressARB, and epoxy must not dlsym-and-abort on them. */
static void stub_gen_vertex_arrays(GLsizei n, GLuint *arrays)
{
    for (GLsizei i = 0; i < n; i++) arrays[i] = 42;
    stub_calls_glGenVertexArrays++;
}

void (*glXGetProcAddressARB(const GLubyte *name))(void);

void (*glXGetProcAddress(const GLubyte *name))(void)
{
    return glXGetProcAddressARB(name);
}

/* Like mesa, also hands out the GLX entrypoints themselves: epoxy resolves
 * glXGetProcAddressARB (GLX_ARB_get_proc_address) through glXGetProcAddress. */
void (*glXGetProcAddressARB(const GLubyte *name))(void)
{
    const char *n = (const char *)name;
    stub_calls_getprocaddress++;
    if (strcmp(n, "glGenVertexArrays") == 0)
        return (void (*)(void))stub_gen_vertex_arrays;
    if (strcmp(n, "glXGetProcAddressARB") == 0)
        return (void (*)(void))glXGetProcAddressARB;
    if (strcmp(n, "glXGetProcAddress") == 0)
        return (void (*)(void))glXGetProcAddress;
    return NULL;
}
