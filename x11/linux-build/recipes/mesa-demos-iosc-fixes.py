#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]) / "src" / "egl" / "eglut"

scanner_candidates = [
    "/work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland/native-root/bin/wayland-scanner",
    "/work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland/build-native/src/wayland-scanner",
    "/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr/bin/wayland-scanner",
]
xml_candidates = [
    "/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    "/work/Procursus/build_stage/iphoneos-arm64-rootless/1900/wayland-protocols/var/jb/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    "/work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
]
scanner = next((Path(p) for p in scanner_candidates if Path(p).exists()), None)
xml = next((Path(p) for p in xml_candidates if Path(p).exists()), None)
if not scanner or not xml:
    raise SystemExit("missing wayland-scanner or xdg-shell.xml")
subprocess.run([str(scanner), "client-header", str(xml), str(root / "xdg-shell-client-protocol.h")], check=True)
try:
    subprocess.run([str(scanner), "private-code", str(xml), str(root / "xdg-shell-protocol.c")], check=True)
except subprocess.CalledProcessError:
    subprocess.run([str(scanner), "code", str(xml), str(root / "xdg-shell-protocol.c")], check=True)

h = root / "eglutint.h"
s = h.read_text()
s = s.replace(
    "extern struct eglut_state *_eglut;\n",
    "extern struct eglut_state *_eglut;\nextern void *_eglut_native_dpy_ptr;\nextern void *_eglut_native_window_ptr;\n",
)
h.write_text(s)

c = root / "eglut.c"
s = c.read_text()
s = s.replace("#include <stdarg.h>\n", "#include <stdarg.h>\n#include <stdint.h>\n")
s = s.replace(
    "struct eglut_state *_eglut = &_eglut_state;\n",
    "struct eglut_state *_eglut = &_eglut_state;\nvoid *_eglut_native_dpy_ptr;\nvoid *_eglut_native_window_ptr;\n",
)
s = s.replace(
    """eglutInit(int argc, char **argv)
{
   int i;

   for (i = 1; i < argc; i++) {
""",
    """eglutInit(int argc, char **argv)
{
   int i;

   _eglut = &_eglut_state;

   for (i = 1; i < argc; i++) {
""",
)
s = s.replace(
    """   _eglutNativeInitDisplay();
   _eglut->dpy = eglGetDisplay(_eglut->native_dpy);
""",
    """   _eglutNativeInitDisplay();
   _eglut->native_dpy = (EGLNativeDisplayType) (uintptr_t) _eglut_native_dpy_ptr;
   _eglut->surface_type = EGL_WINDOW_BIT;
   _eglut->redisplay = 1;
   _eglut->dpy = EGL_NO_DISPLAY;
   if (_eglut_native_dpy_ptr) {
#ifndef EGL_PLATFORM_WAYLAND_EXT
#define EGL_PLATFORM_WAYLAND_EXT 0x31D8
#endif
      typedef EGLDisplay (*eglut_get_platform_display_ext)(EGLenum, void *, const EGLint *);
      eglut_get_platform_display_ext get_platform_display =
         (eglut_get_platform_display_ext) eglGetProcAddress("eglGetPlatformDisplayEXT");
      if (get_platform_display)
         _eglut->dpy = get_platform_display(EGL_PLATFORM_WAYLAND_EXT,
                                            _eglut_native_dpy_ptr, NULL);
   }
   if (_eglut->dpy == EGL_NO_DISPLAY)
      _eglut->dpy = eglGetDisplay(_eglut->native_dpy);
""",
)
s = s.replace(
    """      win->surface = eglCreateWindowSurface(_eglut->dpy,
            win->config, win->native.u.window, NULL);
""",
    """      if (_eglut_native_window_ptr) {
         typedef EGLSurface (*eglut_create_platform_window_surface_ext)(
            EGLDisplay, EGLConfig, void *, const EGLint *);
         eglut_create_platform_window_surface_ext create_platform_window_surface =
            (eglut_create_platform_window_surface_ext)
            eglGetProcAddress("eglCreatePlatformWindowSurfaceEXT");
         if (create_platform_window_surface)
            win->surface = create_platform_window_surface(_eglut->dpy,
                  win->config, _eglut_native_window_ptr, NULL);
         else
            win->surface = eglCreateWindowSurface(_eglut->dpy,
                  win->config, win->native.u.window, NULL);
      } else {
         win->surface = eglCreateWindowSurface(_eglut->dpy,
               win->config, win->native.u.window, NULL);
      }
""",
)
c.write_text(s)

w = root / "eglut_wayland.c"
w.write_text(r'''#include "EGL/egl.h"
#include "EGL/eglext.h"
#include <wayland-client.h>
#include <wayland-egl.h>
#include "xdg-shell-client-protocol.h"
#include "xdg-shell-protocol.c"

#include <poll.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "eglutint.h"

struct display {
   struct wl_display *display;
   struct wl_compositor *compositor;
   struct xdg_wm_base *wm_base;
   uint32_t mask;
};

struct window {
   struct wl_surface *surface;
   struct xdg_surface *xdg_surface;
   struct xdg_toplevel *xdg_toplevel;
   struct wl_callback *callback;
};

static struct display display = {0, };
static struct window window = {0, };

static struct wl_display *
connect_wayland_display(void)
{
   const char *name = getenv("WAYLAND_DISPLAY");
   const char *runtime = getenv("XDG_RUNTIME_DIR");
   char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
   struct sockaddr_un addr;
   int fd;

   if (!name || !*name)
      name = "wayland-0";
   if (name[0] == '/') {
      snprintf(path, sizeof(path), "%s", name);
   } else if (runtime && *runtime) {
      snprintf(path, sizeof(path), "%s/%s", runtime, name);
   } else {
      return wl_display_connect(name);
   }

   fd = socket(AF_UNIX, SOCK_STREAM, 0);
   if (fd < 0) {
      fprintf(stderr, "EGLUT: socket(%s) failed: %s\n", path, strerror(errno));
      return NULL;
   }

   memset(&addr, 0, sizeof(addr));
   addr.sun_family = AF_UNIX;
   snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path);
   if (connect(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
      fprintf(stderr, "EGLUT: connect(%s) failed: %s\n", path, strerror(errno));
      close(fd);
      return NULL;
   }

   return wl_display_connect_to_fd(fd);
}

static void
xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial)
{
   (void)data;
   xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
   xdg_wm_base_ping
};

static void
xdg_surface_configure(void *data, struct xdg_surface *surface, uint32_t serial)
{
   (void)data;
   xdg_surface_ack_configure(surface, serial);
}

static const struct xdg_surface_listener xdg_surface_listener = {
   xdg_surface_configure
};

static void
xdg_toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                       int32_t width, int32_t height, struct wl_array *states)
{
   (void)data;
   (void)toplevel;
   (void)width;
   (void)height;
   (void)states;
}

static void
xdg_toplevel_close(void *data, struct xdg_toplevel *toplevel)
{
   (void)data;
   (void)toplevel;
}

static const struct xdg_toplevel_listener xdg_toplevel_listener = {
   xdg_toplevel_configure,
   xdg_toplevel_close
};

static void
registry_handle_global(void *data, struct wl_registry *registry, uint32_t id,
                       const char *interface, uint32_t version)
{
   struct display *d = data;

   if (strcmp(interface, "wl_compositor") == 0) {
      d->compositor =
         wl_registry_bind(registry, id, &wl_compositor_interface, 1);
   } else if (strcmp(interface, "xdg_wm_base") == 0) {
      uint32_t bind_version = version < 1 ? version : 1;
      d->wm_base =
         wl_registry_bind(registry, id, &xdg_wm_base_interface, bind_version);
      xdg_wm_base_add_listener(d->wm_base, &wm_base_listener, d);
   }
}

static void
registry_handle_global_remove(void *data, struct wl_registry *registry,
                              uint32_t name)
{
   (void)data;
   (void)registry;
   (void)name;
}

static const struct wl_registry_listener registry_listener = {
   registry_handle_global,
   registry_handle_global_remove
};

static void
sync_callback(void *data, struct wl_callback *callback, uint32_t serial)
{
   int *done = data;

   (void)serial;
   *done = 1;
   wl_callback_destroy(callback);
}

static const struct wl_callback_listener sync_listener = {
   sync_callback
};

static int
wayland_roundtrip(struct wl_display *display)
{
   struct wl_callback *callback;
   int done = 0, ret = 0;

   callback = wl_display_sync(display);
   wl_callback_add_listener(callback, &sync_listener, &done);
   while (ret != -1 && !done)
      ret = wl_display_dispatch(display);

   if (!done)
      wl_callback_destroy(callback);

   return ret;
}

void
_eglutNativeInitDisplay(void)
{
   struct wl_registry *registry;

   display.display = connect_wayland_display();
   _eglut_native_dpy_ptr = display.display;

   if (!display.display)
      _eglutFatal("failed to initialize native display");

   registry = wl_display_get_registry(display.display);
   wl_registry_add_listener(registry, &registry_listener, &display);
   wayland_roundtrip(display.display);
   wl_registry_destroy(registry);

   if (!display.compositor || !display.wm_base)
      _eglutFatal("missing wl_compositor or xdg_wm_base");
}

void
_eglutNativeFiniDisplay(void)
{
   if (display.display) {
      wl_display_flush(display.display);
      wl_display_disconnect(display.display);
   }
}

void
_eglutNativeInitWindow(struct eglut_window *win, const char *title,
                       int x, int y, int w, int h)
{
   struct wl_egl_window *native;
   struct wl_region *region;

   (void)x;
   (void)y;

   window.surface = wl_compositor_create_surface(display.compositor);

   region = wl_compositor_create_region(display.compositor);
   wl_region_add(region, 0, 0, w, h);
   wl_surface_set_opaque_region(window.surface, region);
   wl_region_destroy(region);

   window.xdg_surface =
      xdg_wm_base_get_xdg_surface(display.wm_base, window.surface);
   xdg_surface_add_listener(window.xdg_surface, &xdg_surface_listener, &window);
   window.xdg_toplevel = xdg_surface_get_toplevel(window.xdg_surface);
   xdg_toplevel_add_listener(window.xdg_toplevel, &xdg_toplevel_listener, &window);
   xdg_toplevel_set_title(window.xdg_toplevel, title ? title : "es2gears_wayland");
   wl_surface_commit(window.surface);
   wayland_roundtrip(display.display);

   native = wl_egl_window_create(window.surface, w, h);
   _eglut_native_window_ptr = native;

   win->native.u.window = (EGLNativeWindowType) (uintptr_t) native;
   win->native.width = w;
   win->native.height = h;
}

void
_eglutNativeFiniWindow(struct eglut_window *win)
{
   if (_eglut_native_window_ptr)
      wl_egl_window_destroy((struct wl_egl_window *) _eglut_native_window_ptr);

   if (window.xdg_toplevel)
      xdg_toplevel_destroy(window.xdg_toplevel);
   if (window.xdg_surface)
      xdg_surface_destroy(window.xdg_surface);
   if (window.surface)
      wl_surface_destroy(window.surface);

   if (window.callback)
      wl_callback_destroy(window.callback);
}

static void
draw(void *data, struct wl_callback *callback, uint32_t time);

static const struct wl_callback_listener frame_listener = {
   draw
};

static void
draw(void *data, struct wl_callback *callback, uint32_t time)
{
   struct window *window = (struct window *)data;
   struct eglut_window *win = _eglut->current;

   (void)time;

   if (callback) {
      wl_callback_destroy(callback);
      window->callback = NULL;
   }

   if (!_eglut->redisplay)
      return;
   _eglut->redisplay = 0;

   if (win->display_cb)
      win->display_cb();

   window->callback = wl_surface_frame(window->surface);
   wl_callback_add_listener(window->callback, &frame_listener, window);

   eglSwapBuffers(_eglut->dpy, win->surface);
}

void
_eglutNativeEventLoop(void)
{
   struct pollfd pollfd;
   int ret;

   pollfd.fd = wl_display_get_fd(display.display);
   pollfd.events = POLLIN;
   pollfd.revents = 0;

   while (1) {
      if (!(pollfd.events & POLLOUT)) {
         wl_display_dispatch_pending(display.display);

         if (_eglut->idle_cb)
            _eglut->idle_cb();

         if (_eglut->redisplay && !window.callback)
            draw(&window, NULL, 0);
      }

      ret = wl_display_flush(display.display);
      if (ret < 0 && errno != EAGAIN)
         break;
      else if (ret < 0 && errno == EAGAIN)
         pollfd.events |= POLLOUT;
      else
         pollfd.events &= ~POLLOUT;

      if (poll(&pollfd, 1, -1) == -1)
         break;

      if (pollfd.revents & (POLLERR | POLLHUP))
         break;

      if (pollfd.events & POLLOUT) {
         if (!(pollfd.revents & POLLOUT))
            continue;
         pollfd.events &= ~POLLOUT;
      }

      if (pollfd.revents & POLLIN) {
         ret = wl_display_dispatch(display.display);
         if (ret == -1)
            break;
      }

      ret = wl_display_flush(display.display);
      if (ret < 0 && errno != EAGAIN)
         break;
      else if (ret < 0 && errno == EAGAIN)
         pollfd.events |= POLLOUT;
      else
         pollfd.events &= ~POLLOUT;
   }
}
''')

gears = Path(sys.argv[1]) / "src" / "egl" / "opengles2" / "es2gears.c"
s = gears.read_text()
s = s.replace("   eglutInitWindowSize(300, 300);", "   eglutInitWindowSize(840, 520);")
gears.write_text(s)

sys.exit(0)

w = root / "eglut_wayland.c"
s = w.read_text()
s = s.replace("#include <errno.h>\n", "#include <errno.h>\n#include <stdint.h>\n")
s = s.replace(
    """eglutInit(int argc, char **argv)
{
   int i;

   for (i = 1; i < argc; i++) {
""",
    """eglutInit(int argc, char **argv)
{
   int i;

   _eglut = &_eglut_state;

   for (i = 1; i < argc; i++) {
""",
)
s = s.replace(
    """   _eglutNativeInitDisplay();
   _eglut->dpy = eglGetDisplay(_eglut->native_dpy);
""",
    """   _eglutNativeInitDisplay();
   _eglut->native_dpy = (EGLNativeDisplayType) (uintptr_t) _eglut_native_dpy_ptr;
   _eglut->surface_type = EGL_WINDOW_BIT;
   _eglut->redisplay = 1;
   _eglut->dpy = EGL_NO_DISPLAY;
   if (_eglut_native_dpy_ptr) {
#ifndef EGL_PLATFORM_WAYLAND_EXT
#define EGL_PLATFORM_WAYLAND_EXT 0x31D8
#endif
      typedef EGLDisplay (*eglut_get_platform_display_ext)(EGLenum, void *, const EGLint *);
      eglut_get_platform_display_ext get_platform_display =
         (eglut_get_platform_display_ext) eglGetProcAddress("eglGetPlatformDisplayEXT");
      if (get_platform_display)
         _eglut->dpy = get_platform_display(EGL_PLATFORM_WAYLAND_EXT,
                                            _eglut_native_dpy_ptr, NULL);
   }
   if (_eglut->dpy == EGL_NO_DISPLAY)
      _eglut->dpy = eglGetDisplay(_eglut->native_dpy);
""",
)
c.write_text(s)

w = root / "eglut_wayland.c"
s = w.read_text()
s = s.replace("#include <errno.h>\n", "#include <errno.h>\n#include <stdint.h>\n")
s = s.replace(
    """   _eglut->native_dpy =  display.display = wl_display_connect(NULL);
""",
    """   display.display = wl_display_connect(NULL);
   _eglut_native_dpy_ptr = display.display;
""",
)
s = s.replace("   if (!_eglut->native_dpy)", "   if (!display.display)")
s = s.replace(
    """   _eglut->surface_type = EGL_WINDOW_BIT;
   _eglut->redisplay = 1;
""",
    "",
)
s = s.replace(
    "   registry = wl_display_get_registry(_eglut->native_dpy);",
    "   registry = wl_display_get_registry(display.display);",
)
s = s.replace("   wayland_roundtrip(_eglut->native_dpy);", "   wayland_roundtrip(display.display);")
s = s.replace("   wl_display_flush(_eglut->native_dpy);", "   wl_display_flush(display.display);")
s = s.replace("   wl_display_disconnect(_eglut->native_dpy);", "   wl_display_disconnect(display.display);")
w.write_text(s)
