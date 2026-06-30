/*
 * ios-inputd.c -- bridge Xios' iosc input socket to another Wayland compositor.
 *
 * This is the external-compositor sibling of iosc's built-in input socket: Xios
 * can keep writing the same small AF_UNIX protocol, while this process connects
 * to Mutter/wlroots/etc. as an input-method-v2 + virtual-keyboard-v1 client.
 */
#include <wayland-client.h>
#include <wayland-client-protocol.h>
#include "input-method-unstable-v2-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "iosc_input.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define IOSC_IN_TEXT_MAX 4096u
#define IOSC_IN_MOTION 1
#define IOSC_IN_BUTTON 2
#define IOSC_IN_KEY    3
#define IOSC_IN_TEXT   4

struct iosc_in_msg {
    uint32_t type;
    int32_t x, y;
    uint32_t code;
    uint32_t state;
    uint32_t mods;
};

struct app_state {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_seat *seat;
    struct zwp_input_method_manager_v2 *im_mgr;
    struct zwp_input_method_v2 *im;
    struct zwp_virtual_keyboard_manager_v1 *vk_mgr;
    struct zwp_virtual_keyboard_v1 *vk;
    int im_active;
    uint32_t im_done_count;
    int listen_fd;
    int client_fd;
    uint8_t hdr[sizeof(struct iosc_in_msg)];
    int hdr_have;
    struct iosc_in_msg msg;
    char *payload;
    uint32_t payload_have;
};

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static int make_keymap_fd(void)
{
    const char *str = iosc_input_keymap_string();
    uint32_t size = iosc_input_keymap_size();
    const char *dir = getenv("XDG_RUNTIME_DIR");
    if (!dir) dir = "/tmp";
    char tmpl[256];
    snprintf(tmpl, sizeof(tmpl), "%s/ios-inputd-keymap-XXXXXX", dir);
    int fd = mkstemp(tmpl);
    if (fd < 0) return -1;
    unlink(tmpl);
    if (write(fd, str, size) != (ssize_t)size) { close(fd); return -1; }
    lseek(fd, 0, SEEK_SET);
    return fd;
}

static void app_client_reset(struct app_state *s)
{
    free(s->payload);
    s->payload = NULL;
    s->payload_have = 0;
    s->hdr_have = 0;
    memset(&s->msg, 0, sizeof(s->msg));
}

static void app_client_drop(struct app_state *s)
{
    if (s->client_fd >= 0) close(s->client_fd);
    s->client_fd = -1;
    app_client_reset(s);
    fprintf(stderr, "ios-inputd: app input client disconnected\n");
}

static void send_virtual_key(struct app_state *s, uint32_t keysym, uint32_t appmods)
{
    if (!s->vk) return;
    uint32_t evdev = 0;
    int needs_shift = 0;
    if (iosc_input_lookup(keysym, &evdev, &needs_shift) != 0) {
        fprintf(stderr, "ios-inputd: keysym 0x%x not in keymap\n", keysym);
        return;
    }
    uint32_t mods = (needs_shift || (appmods & 1) ? iosc_input_mod_shift() : 0)
                  | ((appmods & 2) ? iosc_input_mod_ctrl() : 0)
                  | ((appmods & 4) ? iosc_input_mod_alt() : 0);
    uint32_t t = now_ms();
    zwp_virtual_keyboard_v1_modifiers(s->vk, mods, 0, 0, 0);
    zwp_virtual_keyboard_v1_key(s->vk, t, evdev, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_key(s->vk, t, evdev, WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_modifiers(s->vk, 0, 0, 0, 0);
}

static void send_text(struct app_state *s, const char *text, size_t len)
{
    if (s->im && s->im_active) {
        char *copy = malloc(len + 1);
        if (!copy) return;
        memcpy(copy, text, len);
        copy[len] = 0;
        zwp_input_method_v2_commit_string(s->im, copy);
        zwp_input_method_v2_commit(s->im, s->im_done_count);
        free(copy);
        return;
    }
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x80) send_virtual_key(s, c == '\n' ? 0xff0d : (uint32_t)c, 0);
    }
}

static void dispatch_msg(struct app_state *s, const struct iosc_in_msg *m)
{
    switch (m->type) {
    case IOSC_IN_KEY:
        send_virtual_key(s, m->code, m->mods);
        break;
    case IOSC_IN_MOTION:
    case IOSC_IN_BUTTON:
        break;
    }
    wl_display_flush(s->display);
}

static void dispatch_text(struct app_state *s, const char *text, size_t len)
{
    send_text(s, text, len);
    wl_display_flush(s->display);
}

static void service_app_client(struct app_state *s)
{
    if (s->client_fd < 0) return;
    for (;;) {
        if (s->hdr_have < (int)sizeof(s->hdr)) {
            ssize_t r = read(s->client_fd, s->hdr + s->hdr_have, sizeof(s->hdr) - (size_t)s->hdr_have);
            if (r > 0) {
                s->hdr_have += (int)r;
                if (s->hdr_have < (int)sizeof(s->hdr)) continue;
                memcpy(&s->msg, s->hdr, sizeof(s->msg));
                if (s->msg.type == IOSC_IN_TEXT) {
                    if (s->msg.code == 0 || s->msg.code > IOSC_IN_TEXT_MAX) { app_client_drop(s); return; }
                    s->payload = calloc(1, s->msg.code + 1u);
                    if (!s->payload) { app_client_drop(s); return; }
                } else {
                    dispatch_msg(s, &s->msg);
                    app_client_reset(s);
                }
                continue;
            }
            if (r == 0) { app_client_drop(s); return; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            app_client_drop(s);
            return;
        }
        while (s->msg.type == IOSC_IN_TEXT && s->payload_have < s->msg.code) {
            ssize_t r = read(s->client_fd, s->payload + s->payload_have, s->msg.code - s->payload_have);
            if (r > 0) { s->payload_have += (uint32_t)r; continue; }
            if (r == 0) { app_client_drop(s); return; }
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            if (errno == EINTR) continue;
            app_client_drop(s);
            return;
        }
        if (s->msg.type == IOSC_IN_TEXT) {
            dispatch_text(s, s->payload, s->msg.code);
            app_client_reset(s);
            continue;
        }
    }
}

static int start_socket(const char *path)
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
    if (listen(fd, 4) < 0) { close(fd); return -1; }
    chmod(path, 0777);
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    return fd;
}

static void accept_app_client(struct app_state *s)
{
    int fd = accept(s->listen_fd, NULL, NULL);
    if (fd < 0) return;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    if (s->client_fd >= 0) app_client_drop(s);
    s->client_fd = fd;
    fprintf(stderr, "ios-inputd: app input client connected\n");
}

static void im_activate(void *data, struct zwp_input_method_v2 *im)
{ (void)im; ((struct app_state *)data)->im_active = 1; }
static void im_deactivate(void *data, struct zwp_input_method_v2 *im)
{ (void)im; ((struct app_state *)data)->im_active = 0; }
static void im_surrounding_text(void *data, struct zwp_input_method_v2 *im,
                                const char *text, uint32_t cursor, uint32_t anchor)
{ (void)data; (void)im; (void)text; (void)cursor; (void)anchor; }
static void im_text_change_cause(void *data, struct zwp_input_method_v2 *im, uint32_t cause)
{ (void)data; (void)im; (void)cause; }
static void im_content_type(void *data, struct zwp_input_method_v2 *im, uint32_t hint, uint32_t purpose)
{ (void)data; (void)im; (void)hint; (void)purpose; }
static void im_done(void *data, struct zwp_input_method_v2 *im)
{ (void)im; ((struct app_state *)data)->im_done_count++; }
static void im_unavailable(void *data, struct zwp_input_method_v2 *im)
{ (void)im; ((struct app_state *)data)->im_active = 0; }

static const struct zwp_input_method_v2_listener im_listener = {
    .activate = im_activate,
    .deactivate = im_deactivate,
    .surrounding_text = im_surrounding_text,
    .text_change_cause = im_text_change_cause,
    .content_type = im_content_type,
    .done = im_done,
    .unavailable = im_unavailable,
};

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
                            const char *iface, uint32_t version)
{
    struct app_state *s = data;
    if (!strcmp(iface, wl_seat_interface.name)) {
        s->seat = wl_registry_bind(reg, name, &wl_seat_interface, version < 5 ? version : 5);
    } else if (!strcmp(iface, zwp_input_method_manager_v2_interface.name)) {
        s->im_mgr = wl_registry_bind(reg, name, &zwp_input_method_manager_v2_interface, 1);
    } else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name)) {
        s->vk_mgr = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}

static void registry_remove(void *data, struct wl_registry *reg, uint32_t name)
{ (void)data; (void)reg; (void)name; }

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_remove,
};

static int init_wayland(struct app_state *s)
{
    s->display = wl_display_connect(NULL);
    if (!s->display) return -1;
    s->registry = wl_display_get_registry(s->display);
    wl_registry_add_listener(s->registry, &registry_listener, s);
    wl_display_roundtrip(s->display);
    wl_display_roundtrip(s->display);
    if (!s->seat) {
        fprintf(stderr, "ios-inputd: compositor has no wl_seat\n");
        return -1;
    }
    if (s->im_mgr) {
        s->im = zwp_input_method_manager_v2_get_input_method(s->im_mgr, s->seat);
        zwp_input_method_v2_add_listener(s->im, &im_listener, s);
    } else {
        fprintf(stderr, "ios-inputd: compositor has no input-method-v2; text falls back to virtual keys\n");
    }
    if (s->vk_mgr) {
        s->vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(s->vk_mgr, s->seat);
        int fd = make_keymap_fd();
        if (fd >= 0) {
            zwp_virtual_keyboard_v1_keymap(s->vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                           fd, iosc_input_keymap_size());
            close(fd);
        }
    } else {
        fprintf(stderr, "ios-inputd: compositor has no virtual-keyboard-v1; key fallback unavailable\n");
    }
    wl_display_flush(s->display);
    return 0;
}

int main(int argc, char **argv)
{
    const char *socket_path = "/var/jb/tmp/iosc-input.sock";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-s") && i + 1 < argc)
            socket_path = argv[++i];
    }

    if (iosc_input_init() != 0) {
        fprintf(stderr, "ios-inputd: xkb keymap init failed\n");
        return 1;
    }

    struct app_state s;
    memset(&s, 0, sizeof(s));
    s.listen_fd = -1;
    s.client_fd = -1;
    if (init_wayland(&s) != 0) return 1;
    s.listen_fd = start_socket(socket_path);
    if (s.listen_fd < 0) {
        perror("ios-inputd: input socket");
        return 1;
    }
    fprintf(stderr, "ios-inputd: listening on %s\n", socket_path);

    for (;;) {
        wl_display_dispatch_pending(s.display);
        wl_display_flush(s.display);
        struct pollfd fds[3];
        nfds_t n = 0;
        fds[n++] = (struct pollfd){ .fd = wl_display_get_fd(s.display), .events = POLLIN };
        fds[n++] = (struct pollfd){ .fd = s.listen_fd, .events = POLLIN };
        if (s.client_fd >= 0)
            fds[n++] = (struct pollfd){ .fd = s.client_fd, .events = POLLIN | POLLHUP | POLLERR };
        if (poll(fds, n, -1) < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            return 1;
        }
        if (fds[0].revents & (POLLHUP | POLLERR)) return 1;
        if (fds[0].revents & POLLIN) {
            if (wl_display_dispatch(s.display) < 0) return 1;
        }
        if (fds[1].revents & POLLIN) accept_app_client(&s);
        if (n > 2 && (fds[2].revents & (POLLIN | POLLHUP | POLLERR)))
            service_app_client(&s);
    }
}
