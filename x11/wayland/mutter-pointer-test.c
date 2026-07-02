/*
 * mutter-pointer-test.c — fullscreen xdg-shell pointer logger for MetaBackendIOS.
 *
 * Maps a fullscreen shm toplevel under Mutter and logs wl_pointer enter/motion/button
 * events. A button press writes /var/jb/tmp/mutter-pointer-hit, giving a simple
 * app-bypass proof that MetaInputIOS events reached a Wayland client.
 *
 *   XDG_RUNTIME_DIR=/var/jb/tmp WAYLAND_DISPLAY=wayland-0 mutter-pointer-test
 *   iosc-input-test --mutter -c 1080 810
 */
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm_base;
static struct wl_surface *surface;
static int width = 2160;
static int height = 1620;
static int configured;
static int hit_count;

static int
create_shm_file (size_t size)
{
  const char *dir = getenv ("XDG_RUNTIME_DIR");
  char tmpl[256];
  int fd;

  if (!dir)
    dir = "/var/jb/tmp";
  snprintf (tmpl, sizeof tmpl, "%s/mutter-pointer-shm-XXXXXX", dir);
  fd = mkstemp (tmpl);
  if (fd < 0)
    {
      perror ("mkstemp");
      return -1;
    }
  unlink (tmpl);
  if (ftruncate (fd, (off_t) size) < 0)
    {
      perror ("ftruncate");
      close (fd);
      return -1;
    }
  return fd;
}

static void
draw (void)
{
  int stride = width * 4;
  size_t size = (size_t) stride * height;
  int fd = create_shm_file (size);
  uint32_t *px;
  struct wl_shm_pool *pool;
  struct wl_buffer *buffer;

  if (fd < 0)
    return;
  px = mmap (NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (px == MAP_FAILED)
    {
      perror ("mmap");
      close (fd);
      return;
    }

  for (int y = 0; y < height; y++)
    {
      for (int x = 0; x < width; x++)
        {
          int border = x < 16 || y < 16 || x >= width - 16 || y >= height - 16;
          int cross = abs (x - width / 2) < 6 || abs (y - height / 2) < 6;
          px[y * width + x] = border ? 0x00ffffffu
                            : cross ? 0x0000ff00u
                            : 0x00202090u;
        }
    }

  pool = wl_shm_create_pool (shm, fd, (int32_t) size);
  buffer = wl_shm_pool_create_buffer (pool, 0, width, height, stride,
                                      WL_SHM_FORMAT_XRGB8888);
  wl_shm_pool_destroy (pool);
  munmap (px, size);
  close (fd);

  wl_surface_attach (surface, buffer, 0, 0);
  wl_surface_damage (surface, 0, 0, width, height);
  wl_surface_commit (surface);
  fprintf (stderr, "pointer-test: drew %dx%d fullscreen probe\n", width, height);
}

static void
write_hit_marker (double x, double y, uint32_t button, uint32_t state)
{
  FILE *f;

  if (state != WL_POINTER_BUTTON_STATE_PRESSED)
    return;
  hit_count++;
  f = fopen ("/var/jb/tmp/mutter-pointer-hit", "w");
  if (!f)
    return;
  fprintf (f, "hit=%d x=%.1f y=%.1f button=%u\n", hit_count, x, y, button);
  fclose (f);
}

static double last_x;
static double last_y;

static void
ptr_enter (void *data, struct wl_pointer *pointer, uint32_t serial,
           struct wl_surface *surf, wl_fixed_t x, wl_fixed_t y)
{
  (void) data; (void) pointer; (void) serial; (void) surf;
  last_x = wl_fixed_to_double (x);
  last_y = wl_fixed_to_double (y);
  fprintf (stderr, "pointer-test: ENTER %.1f,%.1f\n", last_x, last_y);
}

static void
ptr_leave (void *data, struct wl_pointer *pointer, uint32_t serial,
           struct wl_surface *surf)
{
  (void) data; (void) pointer; (void) serial; (void) surf;
  fprintf (stderr, "pointer-test: LEAVE\n");
}

static void
ptr_motion (void *data, struct wl_pointer *pointer, uint32_t time,
            wl_fixed_t x, wl_fixed_t y)
{
  (void) data; (void) pointer; (void) time;
  last_x = wl_fixed_to_double (x);
  last_y = wl_fixed_to_double (y);
  fprintf (stderr, "pointer-test: MOTION %.1f,%.1f\n", last_x, last_y);
}

static void
ptr_button (void *data, struct wl_pointer *pointer, uint32_t serial,
            uint32_t time, uint32_t button, uint32_t state)
{
  (void) data; (void) pointer; (void) serial; (void) time;
  fprintf (stderr, "pointer-test: BUTTON button=%u state=%u at %.1f,%.1f\n",
           button, state, last_x, last_y);
  write_hit_marker (last_x, last_y, button, state);
}

static void ptr_axis (void *d, struct wl_pointer *p, uint32_t t,
                      uint32_t a, wl_fixed_t v)
{ (void) d; (void) p; (void) t; (void) a; (void) v; }
static void ptr_frame (void *d, struct wl_pointer *p)
{ (void) d; (void) p; }
static void ptr_axis_source (void *d, struct wl_pointer *p, uint32_t s)
{ (void) d; (void) p; (void) s; }
static void ptr_axis_stop (void *d, struct wl_pointer *p, uint32_t t, uint32_t a)
{ (void) d; (void) p; (void) t; (void) a; }
static void ptr_axis_discrete (void *d, struct wl_pointer *p, uint32_t a, int32_t v)
{ (void) d; (void) p; (void) a; (void) v; }

static const struct wl_pointer_listener pointer_listener = {
  .enter = ptr_enter,
  .leave = ptr_leave,
  .motion = ptr_motion,
  .button = ptr_button,
  .axis = ptr_axis,
  .frame = ptr_frame,
  .axis_source = ptr_axis_source,
  .axis_stop = ptr_axis_stop,
  .axis_discrete = ptr_axis_discrete,
};

static void
seat_capabilities (void *data, struct wl_seat *wl_seat, uint32_t caps)
{
  (void) data;
  fprintf (stderr, "pointer-test: seat caps pointer=%d keyboard=%d touch=%d\n",
           !!(caps & WL_SEAT_CAPABILITY_POINTER),
           !!(caps & WL_SEAT_CAPABILITY_KEYBOARD),
           !!(caps & WL_SEAT_CAPABILITY_TOUCH));
  if (caps & WL_SEAT_CAPABILITY_POINTER)
    {
      struct wl_pointer *pointer = wl_seat_get_pointer (wl_seat);
      wl_pointer_add_listener (pointer, &pointer_listener, NULL);
    }
}

static void seat_name (void *data, struct wl_seat *wl_seat, const char *name)
{ (void) data; (void) wl_seat; (void) name; }

static const struct wl_seat_listener seat_listener = {
  .capabilities = seat_capabilities,
  .name = seat_name,
};

static void
wm_ping (void *data, struct xdg_wm_base *base, uint32_t serial)
{
  (void) data;
  xdg_wm_base_pong (base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {
  .ping = wm_ping,
};

static void
reg_global (void *data, struct wl_registry *registry, uint32_t name,
            const char *iface, uint32_t version)
{
  (void) data;
  if (!strcmp (iface, "wl_compositor"))
    compositor = wl_registry_bind (registry, name, &wl_compositor_interface,
                                   version < 4 ? version : 4);
  else if (!strcmp (iface, "wl_shm"))
    shm = wl_registry_bind (registry, name, &wl_shm_interface, 1);
  else if (!strcmp (iface, "wl_seat"))
    {
      seat = wl_registry_bind (registry, name, &wl_seat_interface,
                               version < 5 ? version : 5);
      wl_seat_add_listener (seat, &seat_listener, NULL);
    }
  else if (!strcmp (iface, "xdg_wm_base"))
    {
      wm_base = wl_registry_bind (registry, name, &xdg_wm_base_interface, 1);
      xdg_wm_base_add_listener (wm_base, &wm_listener, NULL);
    }
}

static void reg_remove (void *data, struct wl_registry *registry, uint32_t name)
{ (void) data; (void) registry; (void) name; }

static const struct wl_registry_listener registry_listener = {
  .global = reg_global,
  .global_remove = reg_remove,
};

static void
xsurf_configure (void *data, struct xdg_surface *xdg_surface, uint32_t serial)
{
  (void) data;
  xdg_surface_ack_configure (xdg_surface, serial);
  configured = 1;
  draw ();
}

static const struct xdg_surface_listener xsurf_listener = {
  .configure = xsurf_configure,
};

static void
top_configure (void *data, struct xdg_toplevel *top, int32_t w, int32_t h,
               struct wl_array *states)
{
  (void) data; (void) top; (void) states;
  if (w > 0 && h > 0)
    {
      width = w;
      height = h;
    }
  fprintf (stderr, "pointer-test: CONFIGURE %dx%d\n", width, height);
}

static void top_close (void *data, struct xdg_toplevel *top)
{ (void) data; (void) top; exit (0); }

static const struct xdg_toplevel_listener top_listener = {
  .configure = top_configure,
  .close = top_close,
};

int
main (void)
{
  struct wl_display *display;
  struct wl_registry *registry;
  struct xdg_surface *xdg_surface;
  struct xdg_toplevel *top;

  display = wl_display_connect (NULL);
  if (!display)
    {
      fprintf (stderr, "pointer-test: wl_display_connect failed\n");
      return 1;
    }

  registry = wl_display_get_registry (display);
  wl_registry_add_listener (registry, &registry_listener, NULL);
  wl_display_roundtrip (display);
  wl_display_roundtrip (display);

  if (!compositor || !shm || !seat || !wm_base)
    {
      fprintf (stderr, "pointer-test: missing globals compositor=%p shm=%p seat=%p wm=%p\n",
               (void *) compositor, (void *) shm, (void *) seat, (void *) wm_base);
      return 1;
    }

  surface = wl_compositor_create_surface (compositor);
  xdg_surface = xdg_wm_base_get_xdg_surface (wm_base, surface);
  xdg_surface_add_listener (xdg_surface, &xsurf_listener, NULL);
  top = xdg_surface_get_toplevel (xdg_surface);
  xdg_toplevel_add_listener (top, &top_listener, NULL);
  xdg_toplevel_set_title (top, "mutter pointer test");
  xdg_toplevel_set_app_id (top, "com.max.mutter-pointer-test");
  xdg_toplevel_set_fullscreen (top, NULL);
  wl_surface_commit (surface);
  fprintf (stderr, "pointer-test: committed fullscreen xdg_toplevel\n");

  while (wl_display_dispatch (display) != -1)
    {
      if (!configured)
        wl_display_flush (display);
    }

  wl_display_disconnect (display);
  return 0;
}
