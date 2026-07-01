/*
 * iosc-screenshot-test.c — validate wlr-screencopy-v1 end-to-end without grim.
 *
 * Binds zwlr_screencopy_manager_v1 + wl_shm + wl_output, captures the whole
 * output into a wl_shm XRGB8888 buffer, and on `ready` prints a small app-space
 * probe map of the CAPTURED pixels (same legend as iosc's IOSC_PROBE) plus a
 * corner sample, then exits. If iosc is showing e.g. the iosc-client frame or
 * the spb-test orange field, the captured map should match what's on screen.
 *
 * MIT. Standard libwayland-client boilerplate.
 */
#include <wayland-client.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

static struct wl_shm                       *shm;
static struct wl_output                    *output;
static struct zwlr_screencopy_manager_v1   *scm;

static struct zwlr_screencopy_frame_v1 *frame;
static struct wl_buffer *buffer;
static uint8_t *pixels;         /* mmap'd XRGB8888 */
static int buf_w, buf_h, buf_stride;
static size_t buf_size;
static int failed = 0, done = 0;

static int create_shm_file(size_t size)
{
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir) dir = "/var/jb/tmp";
    char tmpl[256];
    snprintf(tmpl, sizeof(tmpl), "%s/iosc-shot-XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0) { perror("mkstemp"); return -1; }
    unlink(tmpl);
    if (ftruncate(fd, (off_t)size) < 0) { perror("ftruncate"); close(fd); return -1; }
    return fd;
}

/* Same legend as iosc's probe_ch, for BGRA/XRGB memory. */
static char probe_ch(uint32_t p)
{
    int b = p & 0xff, g = (p >> 8) & 0xff, r = (p >> 16) & 0xff;
#define NEAR(v, t) ((v) >= (t) - 28 && (v) <= (t) + 28)
    if (NEAR(b,0)   && NEAR(g,0)   && NEAR(r,0))   return '.';
    if (NEAR(b,128) && NEAR(g,128) && NEAR(r,0))   return 't';
    if (NEAR(b,0)   && NEAR(g,128) && NEAR(r,255)) return 'O';
    if (NEAR(b,143) && NEAR(g,58)  && NEAR(r,32))  return 'b';
    if (NEAR(b,48)  && NEAR(g,192) && NEAR(r,48))  return 'g';
    if (NEAR(b,32)  && NEAR(g,32)  && NEAR(r,224)) return 'r';
#undef NEAR
    return '?';
}

static void print_capture(void)
{
    fprintf(stderr, "shot: captured %dx%d (stride %d); app-space map:\n",
            buf_w, buf_h, buf_stride);
    for (int ry = 0; ry <= 12; ry++) {
        int y = (int)((long)ry * (buf_h - 1) / 12);
        char row[40]; int rc = 0;
        for (int rx = 0; rx <= 24; rx++) {
            int x = (int)((long)rx * (buf_w - 1) / 24);
            uint32_t px = *(uint32_t *)(pixels + (size_t)y * buf_stride + (size_t)x * 4);
            row[rc++] = probe_ch(px);
        }
        row[rc] = 0;
        fprintf(stderr, "   %s\n", row);
    }
}

static void frame_buffer(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t format,
                         uint32_t w, uint32_t h, uint32_t stride)
{
    (void)d; (void)f; (void)format;
    buf_w = (int)w; buf_h = (int)h; buf_stride = (int)stride;
    buf_size = (size_t)stride * h;
    int fd = create_shm_file(buf_size);
    if (fd < 0) { failed = 1; return; }
    pixels = mmap(NULL, buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) { perror("mmap"); close(fd); failed = 1; return; }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)buf_size);
    buffer = wl_shm_pool_create_buffer(pool, 0, buf_w, buf_h, buf_stride, format);
    wl_shm_pool_destroy(pool);
    close(fd);
    fprintf(stderr, "shot: buffer %ux%u fmt %u stride %u\n", w, h, format, stride);
}
static void frame_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags)
{ (void)d; (void)f; fprintf(stderr, "shot: flags 0x%x\n", flags); }
static void frame_ready(void *d, struct zwlr_screencopy_frame_v1 *f,
                        uint32_t sh, uint32_t sl, uint32_t ns)
{ (void)d; (void)f; (void)sh; (void)sl; (void)ns;
    print_capture(); done = 1; }
static void frame_failed(void *d, struct zwlr_screencopy_frame_v1 *f)
{ (void)d; (void)f; fprintf(stderr, "shot: FAILED\n"); failed = 1; }
static void frame_damage(void *d, struct zwlr_screencopy_frame_v1 *f,
                         uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{ (void)d; (void)f; (void)x; (void)y; (void)w; (void)h; }
static void frame_linux_dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f,
                               uint32_t fmt, uint32_t w, uint32_t h)
{ (void)d; (void)f; (void)fmt; (void)w; (void)h; }
static void frame_buffer_done(void *d, struct zwlr_screencopy_frame_v1 *f)
{ (void)d;
    if (!buffer) { failed = 1; return; }
    zwlr_screencopy_frame_v1_copy(f, buffer);
    fprintf(stderr, "shot: copy() issued\n");
}
static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer = frame_buffer, .flags = frame_flags, .ready = frame_ready,
    .failed = frame_failed, .damage = frame_damage,
    .linux_dmabuf = frame_linux_dmabuf, .buffer_done = frame_buffer_done,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version)
{
    (void)data; (void)version;
    if (!strcmp(iface, "wl_shm"))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, "wl_output"))
        output = wl_registry_bind(reg, name, &wl_output_interface, 1);
    else if (!strcmp(iface, "zwlr_screencopy_manager_v1"))
        scm = wl_registry_bind(reg, name, &zwlr_screencopy_manager_v1_interface, 3);
}
static void reg_global_remove(void *d, struct wl_registry *r, uint32_t n)
{ (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {
    .global = reg_global, .global_remove = reg_global_remove,
};

int main(void)
{
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "shot: wl_display_connect failed\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);

    if (!shm || !output || !scm) {
        fprintf(stderr, "shot: missing globals (shm=%p output=%p scm=%p)\n",
                (void*)shm, (void*)output, (void*)scm);
        return 1;
    }
    frame = zwlr_screencopy_manager_v1_capture_output(scm, 0 /*no cursor*/, output);
    zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, NULL);

    while (!done && !failed && wl_display_dispatch(dpy) != -1)
        ;
    wl_display_disconnect(dpy);
    return failed ? 1 : 0;
}
