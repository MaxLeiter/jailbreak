/*
 * ios-inputd.c -- bridge Xios' iosc input socket to another Wayland compositor.
 *
 * Two modes, picked from the globals the compositor advertises:
 *
 * ROOT (wlroots-style, zwp_input_method_v2 + zwp_virtual_keyboard_v1): this
 * process stands in for iosc entirely. It LISTENS on the input socket path, Xios
 * connects to it, and typed text/keys go into the compositor. Mutter does not
 * implement either protocol, so this mode is for wlroots-family compositors.
 *
 * PROXY (KDE flavor, zwp_input_method_v1): iosc stays the root compositor and
 * still owns the input socket; kwin_wayland runs NESTED as an iosc client and is
 * the one holding the text-input state. iosc therefore cannot derive OSK traits
 * on its own (its text_input_for_focus() is permanently NULL) and cannot commit
 * text into the focused Plasma app. So here we CONNECT to iosc's input socket as
 * a client, register with XIOS_IN_IMPROXY, and become the missing half in both
 * directions: KWin's activate/content_type/commit_state become XIOS_IN_TRAITS
 * records that iosc rebroadcasts to the Xios app (which raises the iOS keyboard),
 * and XIOS_IN_TEXT records that iosc forwards to us become commit_string on the
 * IM context (so autocorrect, emoji and dictation land in the app instead of the
 * ASCII-keysym fallback). KWin must LAUNCH us for this to work: it filters
 * zwp_input_method_v1 to the connection it hands its own child in WAYLAND_SOCKET
 * (kwin_wayland --inputmethod, see x11/docs/osk-plan.md "KDE flavor").
 */
#include <wayland-client.h>
#include <wayland-client-protocol.h>
#include "input-method-unstable-v1-client-protocol.h"
#include "input-method-unstable-v2-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "iosc_input.h"

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
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
#define IOSC_IN_TRAITS 5    /* proxy->iosc here: OSK traits, rebroadcast to hosts */
#define IOSC_IN_IMPROXY 15  /* proxy->iosc: claim the input-method-proxy role.
                             * 14 is XIOS_IN_GESTURE, already on the wire in
                             * shipped iosc/Xios builds; this role was never
                             * published, so it renumbered rather than it.        */

/* text-input-v1 -> text-input-v3 content_purpose. KWin converts down to v1 before
 * handing the IM a content_type (inputmethod_v1.cpp sendContentType), but the Xios
 * app's UITextInputTraits table is frozen on v3 numbering, so translate here. The
 * two agree on 0..8 and then shift, because v3 inserted `pin` at 9.
 * v1 has no `pin` at all and KWin's switch has no Pin case, so a v3 pin field
 * arrives as normal(0): the number pad is unrecoverable, secure entry still comes
 * through on the hidden_text hint. Hint BITS are numerically identical between v1
 * and v3 (0x1..0x200) so they pass through untouched; note v1's 0x2 means
 * auto_correction where v3 calls the same bit spellcheck, and that KWin 6.1.5 maps
 * SensitiveData to content_hint_lowercase (upstream bug), so 0x80 never arrives. */
static uint32_t v1_purpose_to_v3(uint32_t purpose)
{
    switch (purpose) {
    case 9:  return 10;  /* date     */
    case 10: return 11;  /* time     */
    case 11: return 12;  /* datetime */
    case 12: return 13;  /* terminal */
    default: return purpose <= 8 ? purpose : 0;
    }
}

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
    /* PROXY mode (zwp_input_method_v1, KDE) */
    int proxy;                                    /* 1 = proxy mode, 0 = root mode */
    struct zwp_input_method_v1 *im1;
    struct zwp_input_method_context_v1 *ctx1;
    uint32_t ctx_serial;                          /* newest commit_state serial     */
    uint32_t tr_hint, tr_purpose, tr_enabled;     /* traits as last pushed to iosc  */
    char sock_path[108];                          /* for reconnect after iosc restart */
    int listen_fd;
    int client_fd;
    uint8_t hdr[sizeof(struct iosc_in_msg)];
    int hdr_have;
    struct iosc_in_msg msg;
    char *payload;
    uint32_t payload_have;
    uint32_t key_mods_depressed;
    uint32_t key_mods_locked;
};

static void set_nonblock(int fd)
{
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
}

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
    fprintf(stderr, s->proxy ? "ios-inputd: iosc input socket closed; will reconnect\n"
                             : "ios-inputd: app input client disconnected\n");
}

static void app_modifier_masks(uint32_t appmods, int needs_shift,
                               uint32_t *depressed, uint32_t *locked)
{
    *depressed = (needs_shift || (appmods & 1) ? iosc_input_mod_shift() : 0)
               | ((appmods & 2) ? iosc_input_mod_ctrl() : 0)
               | ((appmods & 4) ? iosc_input_mod_alt() : 0)
               | ((appmods & 8) ? iosc_input_mod_super() : 0);
    *locked = ((appmods & 16) ? iosc_input_mod_caps() : 0)
            | ((appmods & 32) ? iosc_input_mod_num() : 0);
}

static void send_virtual_key(struct app_state *s, uint32_t keysym,
                             uint32_t state, uint32_t appmods)
{
    if (!s->vk) return;
    uint32_t evdev = 0;
    int needs_shift = 0;
    if (iosc_input_lookup(keysym, &evdev, &needs_shift) != 0) {
        fprintf(stderr, "ios-inputd: keysym 0x%x not in keymap\n", keysym);
        return;
    }
    uint32_t depressed = 0, locked = 0;
    /* Synthetic level selection is press-only. On release, use only the real
     * wire snapshot or an uppercase tap would leave Shift latched. */
    app_modifier_masks(appmods, state && needs_shift, &depressed, &locked);
    uint32_t t = now_ms();
    if (state)
        zwp_virtual_keyboard_v1_modifiers(s->vk, depressed, 0, locked, 0);
    zwp_virtual_keyboard_v1_key(s->vk, t, evdev,
                                state ? WL_KEYBOARD_KEY_STATE_PRESSED
                                      : WL_KEYBOARD_KEY_STATE_RELEASED);
    if (!state)
        zwp_virtual_keyboard_v1_modifiers(s->vk, depressed, 0, locked, 0);
    s->key_mods_depressed = depressed;
    s->key_mods_locked = locked;
}

static void send_virtual_key_tap(struct app_state *s, uint32_t keysym, uint32_t appmods)
{
    send_virtual_key(s, keysym, 1, appmods);
    send_virtual_key(s, keysym, 0, 0);
}

static void send_text(struct app_state *s, const char *text, size_t len)
{
    if (s->proxy) {
        /* iosc only forwards TEXT to us, so a null context means the field went
         * away between the app's keystroke and this record. Dropping it is right:
         * there is nothing to commit into, and iosc has already skipped its own
         * fallback on our behalf. */
        if (!s->ctx1) return;
        char *copy = malloc(len + 1);
        if (!copy) return;
        memcpy(copy, text, len);
        copy[len] = 0;
        zwp_input_method_context_v1_commit_string(s->ctx1, s->ctx_serial, copy);
        free(copy);
        return;
    }
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
        if (c < 0x80) send_virtual_key_tap(s, c == '\n' ? 0xff0d : (uint32_t)c, 0);
    }
}

/* ---- PROXY mode: the iosc input socket, as a client ------------------------- */

static int proxy_write(struct app_state *s, const void *buf, size_t len)
{
    if (s->client_fd < 0) return -1;
    const char *p = buf;
    size_t put = 0;
    while (put < len) {
        ssize_t w = write(s->client_fd, p + put, len - put);
        if (w > 0) { put += (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

/* Push the current traits to iosc, which rebroadcasts them verbatim to the Xios
 * app. Deliberately NO dedupe: the app's responder policy uses repeat pushes to
 * cancel its pending hide during same-field activity, and a focus hop between two
 * fields must arrive as disable-then-enable. See x11/docs/osk-plan.md. */
static void proxy_send_traits(struct app_state *s)
{
    if (!s->proxy) return;
    struct iosc_in_msg m;
    memset(&m, 0, sizeof(m));
    m.type = IOSC_IN_TRAITS;
    m.code = s->tr_hint;
    m.state = s->tr_purpose;
    m.mods = s->tr_enabled;
    if (proxy_write(s, &m, sizeof(m)) != 0) {
        fprintf(stderr, "ios-inputd: traits push failed: %s\n", strerror(errno));
        app_client_drop(s);
    }
}

static void proxy_set_traits(struct app_state *s, uint32_t hint, uint32_t purpose,
                            uint32_t enabled)
{
    s->tr_hint = hint;
    s->tr_purpose = purpose;
    s->tr_enabled = enabled;
    proxy_send_traits(s);
}

/* Connect to iosc's input socket and claim the proxy role. Returns 0 on success.
 * Failure is not fatal: iosc may not be up yet (KWin can start us first), so the
 * poll loop retries. */
static int proxy_connect(struct app_state *s)
{
    if (s->client_fd >= 0) return 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, s->sock_path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { close(fd); return -1; }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    s->client_fd = fd;
    app_client_reset(s);

    struct iosc_in_msg reg;
    memset(&reg, 0, sizeof(reg));
    reg.type = IOSC_IN_IMPROXY;
    reg.code = 1;
    if (proxy_write(s, &reg, sizeof(reg)) != 0) {
        fprintf(stderr, "ios-inputd: IMPROXY register failed: %s\n", strerror(errno));
        app_client_drop(s);
        return -1;
    }
    set_nonblock(fd);   /* after the register write, so it cannot short-write */
    fprintf(stderr, "ios-inputd: registered as input-method proxy on %s\n", s->sock_path);
    /* Re-state where the field currently stands: iosc latches whatever it last
     * heard from us, and a reconnect must not leave it stale. */
    proxy_send_traits(s);
    return 0;
}

/* ---- PROXY mode: zwp_input_method_v1 (what KWin actually implements) -------- */

static void ctx_surrounding_text(void *data, struct zwp_input_method_context_v1 *c,
                                 const char *text, uint32_t cursor, uint32_t anchor)
{ (void)data; (void)c; (void)text; (void)cursor; (void)anchor; }

static void ctx_reset(void *data, struct zwp_input_method_context_v1 *c)
{ (void)data; (void)c; }   /* no preedit is ever pending: iOS composes on its side */

static void ctx_content_type(void *data, struct zwp_input_method_context_v1 *c,
                             uint32_t hint, uint32_t purpose)
{
    (void)c;
    struct app_state *s = data;
    proxy_set_traits(s, hint, v1_purpose_to_v3(purpose), 1);
}

static void ctx_invoke_action(void *data, struct zwp_input_method_context_v1 *c,
                              uint32_t button, uint32_t index)
{ (void)data; (void)c; (void)button; (void)index; }

static void ctx_commit_state(void *data, struct zwp_input_method_context_v1 *c,
                             uint32_t serial)
{
    (void)c;
    struct app_state *s = data;
    s->ctx_serial = serial;
    /* The v1 analogue of iosc's "broadcast on every text_input.commit": caret
     * moves and same-field edits land here, and the app needs them to keep the
     * keyboard up. */
    proxy_send_traits(s);
}

static void ctx_preferred_language(void *data, struct zwp_input_method_context_v1 *c,
                                   const char *language)
{ (void)data; (void)c; (void)language; }

static const struct zwp_input_method_context_v1_listener ctx_listener = {
    .surrounding_text = ctx_surrounding_text,
    .reset = ctx_reset,
    .content_type = ctx_content_type,
    .invoke_action = ctx_invoke_action,
    .commit_state = ctx_commit_state,
    .preferred_language = ctx_preferred_language,
};

static void im1_activate(void *data, struct zwp_input_method_v1 *im,
                         struct zwp_input_method_context_v1 *ctx)
{
    (void)im;
    struct app_state *s = data;
    if (s->ctx1) zwp_input_method_context_v1_destroy(s->ctx1);
    s->ctx1 = ctx;
    s->ctx_serial = 0;
    zwp_input_method_context_v1_add_listener(ctx, &ctx_listener, s);
    /* content_type follows immediately (KWin sends it from
     * adoptInputMethodContext), but raise the keyboard now rather than waiting:
     * a field with default traits still deserves a keyboard. */
    proxy_set_traits(s, s->tr_hint, s->tr_purpose, 1);
}

static void im1_deactivate(void *data, struct zwp_input_method_v1 *im,
                           struct zwp_input_method_context_v1 *ctx)
{
    (void)im;
    struct app_state *s = data;
    if (ctx) zwp_input_method_context_v1_destroy(ctx);
    if (s->ctx1 == ctx) s->ctx1 = NULL;
    s->ctx_serial = 0;
    proxy_set_traits(s, 0, 0, 0);
}

static const struct zwp_input_method_v1_listener im1_listener = {
    .activate = im1_activate,
    .deactivate = im1_deactivate,
};

static void dispatch_msg(struct app_state *s, const struct iosc_in_msg *m)
{
    /* Proxy mode gets TEXT and nothing else: iosc is still the root compositor,
     * so pointer/keyboard/touch already reach KWin through its wl_seat. Injecting
     * them a second time here would double every keystroke. */
    if (s->proxy) return;
    switch (m->type) {
    case IOSC_IN_KEY:
        send_virtual_key(s, m->code, m->state, m->mods);
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
    struct passwd *pw = getpwnam("mobile");
    uid_t uid = pw ? pw->pw_uid : 501;
    gid_t gid = pw ? pw->pw_gid : 501;
    if (chown(path, uid, gid) == 0) {
        chmod(path, 0660);
    } else {
        chmod(path, 0600);
        fprintf(stderr, "ios-inputd: keeping %s owner-only; chown mobile failed: %s\n",
                path, strerror(errno));
    }
    set_nonblock(fd);
    return fd;
}

static void accept_app_client(struct app_state *s)
{
    int fd = accept(s->listen_fd, NULL, NULL);
    if (fd < 0) return;
    set_nonblock(fd);
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
    } else if (!strcmp(iface, zwp_input_method_v1_interface.name)) {
        /* KWin. Note this is the global itself, not a manager: activate/deactivate
         * arrive on it directly, no per-seat get_input_method call. */
        s->im1 = wl_registry_bind(reg, name, &zwp_input_method_v1_interface, 1);
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
    /* wl_display_connect honours WAYLAND_SOCKET, which is how KWin hands its
     * input-method child the one connection allowed to bind zwp_input_method_v1
     * (wayland_server.cpp allowInterface filters it to that client). */
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
    /* input-method-v1 means a nested KWin: proxy mode, and none of the root-mode
     * machinery below applies (no virtual keyboard, no listen socket). */
    if (s->im1) {
        s->proxy = 1;
        zwp_input_method_v1_add_listener(s->im1, &im1_listener, s);
        wl_display_flush(s->display);
        fprintf(stderr, "ios-inputd: zwp_input_method_v1 present -> proxy mode\n");
        return 0;
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

    /* The keymap only feeds the root-mode virtual keyboard. Proxy mode commits
     * strings through the IM context and lets iosc own the keyboard, so a missing
     * xkb tree must not stop KWin's input method from starting. */
    int have_keymap = iosc_input_init() == 0;

    struct app_state s;
    memset(&s, 0, sizeof(s));
    s.listen_fd = -1;
    s.client_fd = -1;
    snprintf(s.sock_path, sizeof(s.sock_path), "%s", socket_path);
    if (init_wayland(&s) != 0) return 1;
    if (!s.proxy && !have_keymap) {
        fprintf(stderr, "ios-inputd: xkb keymap init failed\n");
        return 1;
    }
    if (!s.proxy) {
        s.listen_fd = start_socket(socket_path);
        if (s.listen_fd < 0) {
            perror("ios-inputd: input socket");
            return 1;
        }
        fprintf(stderr, "ios-inputd: listening on %s\n", socket_path);
    } else {
        proxy_connect(&s);   /* best effort; the loop retries if iosc is not up yet */
    }

    for (;;) {
        wl_display_dispatch_pending(s.display);
        wl_display_flush(s.display);
        struct pollfd fds[3];
        nfds_t n = 0;
        fds[n++] = (struct pollfd){ .fd = wl_display_get_fd(s.display), .events = POLLIN };
        int listen_slot = -1, client_slot = -1;
        if (s.listen_fd >= 0) {
            listen_slot = (int)n;
            fds[n++] = (struct pollfd){ .fd = s.listen_fd, .events = POLLIN };
        }
        if (s.client_fd >= 0) {
            client_slot = (int)n;
            fds[n++] = (struct pollfd){ .fd = s.client_fd, .events = POLLIN | POLLHUP | POLLERR };
        }
        /* Proxy mode with no connection: poll with a timeout so a late or
         * restarted iosc gets picked up without spinning. */
        int timeout = (s.proxy && s.client_fd < 0) ? 1000 : -1;
        if (poll(fds, n, timeout) < 0) {
            if (errno == EINTR) continue;
            perror("poll");
            return 1;
        }
        if (fds[0].revents & (POLLHUP | POLLERR)) return 1;
        if (fds[0].revents & POLLIN) {
            if (wl_display_dispatch(s.display) < 0) return 1;
        }
        if (listen_slot >= 0 && (fds[listen_slot].revents & POLLIN))
            accept_app_client(&s);
        if (client_slot >= 0 && (fds[client_slot].revents & (POLLIN | POLLHUP | POLLERR)))
            service_app_client(&s);
        if (s.proxy && s.client_fd < 0) proxy_connect(&s);
    }
}
