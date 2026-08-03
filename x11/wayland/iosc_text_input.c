/*
 * iosc_text_input.c — text-input-v3, input-method-v2 and virtual-keyboard-v1.
 *
 * Split out of iosc.c. This is the compositor half of on-screen/IME text entry:
 * clients advertise an editable field via zwp_text_input_v3, an input-method
 * client (or the Xios iOS keyboard bridge, which drives it through
 * text_input_commit_text()) supplies the text, and zwp_virtual_keyboard_v1 lets
 * a client synthesize raw key events.
 *
 * The module owns all of that state privately; iosc.c reaches it only through
 * the handful of entry points declared in iosc_internal.h.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "text-input-unstable-v3-server-protocol.h"
#include "input-method-unstable-v2-server-protocol.h"
#include "virtual-keyboard-unstable-v1-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_input.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


#define IOSC_MAX_TEXT_INPUTS 64

struct iosc_text_input {
    struct wl_resource *resource;
    struct wl_client *client;
    struct iosc_surface *focus_surface;
    int pending_enabled;
    int enabled;
    char *surrounding;
    int32_t cursor, anchor;
    uint32_t change_cause;
    uint32_t content_hint, content_purpose;
    int32_t rect_x, rect_y, rect_w, rect_h;
    uint32_t serial;
};

static struct iosc_text_input *g_text_inputs[IOSC_MAX_TEXT_INPUTS];
static int g_ntext_inputs;

struct iosc_input_popup {
    struct wl_resource *resource;
    struct iosc_surface *surface;
};

struct iosc_input_method {
    struct wl_resource *resource;
    int active;
    uint32_t done_count;
    char *commit_text;
    char *preedit_text;
    int32_t preedit_begin, preedit_end;
    uint32_t delete_before, delete_after;
    struct wl_resource *keyboard_grab;
    struct iosc_input_popup *popups[8];
    int npopups;
};

struct iosc_virtual_keyboard {
    struct wl_resource *resource;
    int has_keymap;
};

static struct iosc_input_method *g_input_method;

static void text_input_reset_state(struct iosc_text_input *ti)
{
    if (!ti) return;
    ti->pending_enabled = 0;
    ti->enabled = 0;
    free(ti->surrounding);
    ti->surrounding = NULL;
    ti->cursor = 0;
    ti->anchor = 0;
    ti->change_cause = ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD;
    ti->content_hint = ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE;
    ti->content_purpose = ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL;
    ti->rect_x = ti->rect_y = ti->rect_w = ti->rect_h = 0;
}

void text_input_focus_surface(struct iosc_surface *old, struct iosc_surface *next)
{
    struct wl_client *old_client = old ? wl_resource_get_client(old->resource) : NULL;
    struct wl_client *next_client = next ? wl_resource_get_client(next->resource) : NULL;
    for (int i = 0; i < g_ntext_inputs; i++) {
        struct iosc_text_input *ti = g_text_inputs[i];
        if (!ti || !ti->resource) continue;
        if (old && ti->focus_surface == old && ti->client == old_client) {
            zwp_text_input_v3_send_leave(ti->resource, old->resource);
            ti->focus_surface = NULL;
            text_input_reset_state(ti);
        }
        if (next && ti->client == next_client) {
            ti->focus_surface = next;
            zwp_text_input_v3_send_enter(ti->resource, next->resource);
        }
    }
    input_method_update_active();
    input_clients_send_traits();
}

static struct iosc_text_input *text_input_for_focus(void)
{
    if (!g_kbd_focus) return NULL;
    struct wl_client *client = wl_resource_get_client(g_kbd_focus->resource);
    for (int i = 0; i < g_ntext_inputs; i++) {
        struct iosc_text_input *ti = g_text_inputs[i];
        if (ti && ti->client == client && ti->focus_surface == g_kbd_focus && ti->enabled)
            return ti;
    }
    return NULL;
}

int text_input_focus_traits(uint32_t *content_hint, uint32_t *content_purpose,
                            int *enabled)
{
    struct iosc_text_input *ti = text_input_for_focus();
    if (content_hint)    *content_hint    = ti ? ti->content_hint : 0;
    if (content_purpose) *content_purpose = ti ? ti->content_purpose : 0;
    if (enabled)         *enabled         = ti ? ti->enabled : 0;
    return ti != NULL;
}

int text_input_commit_text(const char *text, size_t len)
{
    struct iosc_text_input *ti = text_input_for_focus();
    if (!ti || !text || len == 0) return 0;
    char *copy = malloc(len + 1);
    if (!copy) return -1;
    memcpy(copy, text, len);
    copy[len] = 0;
    zwp_text_input_v3_send_commit_string(ti->resource, copy);
    zwp_text_input_v3_send_done(ti->resource, ti->serial);
    free(copy);
    return 1;
}

static void input_method_clear_pending(struct iosc_input_method *im)
{
    if (!im) return;
    free(im->commit_text);
    free(im->preedit_text);
    im->commit_text = NULL;
    im->preedit_text = NULL;
    im->preedit_begin = im->preedit_end = 0;
    im->delete_before = im->delete_after = 0;
}

static void input_method_send_done(struct iosc_input_method *im)
{
    if (!im || !im->resource) return;
    zwp_input_method_v2_send_done(im->resource);
    im->done_count++;
}

static void input_method_send_state(struct iosc_input_method *im, struct iosc_text_input *ti, int activate)
{
    if (!im || !im->resource || !ti) return;
    if (activate) zwp_input_method_v2_send_activate(im->resource);
    zwp_input_method_v2_send_surrounding_text(im->resource, ti->surrounding ? ti->surrounding : "",
                                              (uint32_t)ti->cursor, (uint32_t)ti->anchor);
    zwp_input_method_v2_send_text_change_cause(im->resource, ti->change_cause);
    zwp_input_method_v2_send_content_type(im->resource, ti->content_hint, ti->content_purpose);
    input_method_send_done(im);
    for (int i = 0; i < im->npopups; i++) {
        struct iosc_input_popup *p = im->popups[i];
        if (p && p->resource)
            zwp_input_popup_surface_v2_send_text_input_rectangle(p->resource, ti->rect_x, ti->rect_y,
                                                                 ti->rect_w, ti->rect_h);
    }
}

void input_method_update_active(void)
{
    if (!g_input_method || !g_input_method->resource) return;
    struct iosc_text_input *ti = text_input_for_focus();
    if (ti) {
        input_method_send_state(g_input_method, ti, !g_input_method->active);
        g_input_method->active = 1;
    } else if (g_input_method->active) {
        zwp_input_method_v2_send_deactivate(g_input_method->resource);
        input_method_send_done(g_input_method);
        g_input_method->active = 0;
        input_method_clear_pending(g_input_method);
    }
}

/* The keyboard path calls this for every real key transition BEFORE normal
 * wl_keyboard delivery; a bound input-method with an active grab swallows the
 * key (returns 1) so it is not also delivered to the focused client. */
int input_method_forward_grab_key(uint32_t time, uint32_t key, uint32_t state,
                                  uint32_t depressed, uint32_t locked)
{
    if (!g_input_method || !g_input_method->active || !g_input_method->keyboard_grab) return 0;
    struct wl_resource *grab = g_input_method->keyboard_grab;
    uint32_t serial = wl_display_next_serial(g_display);
    zwp_input_method_keyboard_grab_v2_send_modifiers(grab, serial, depressed, 0, locked, 0);
    zwp_input_method_keyboard_grab_v2_send_key(grab, serial, time, key, state);
    return 1;
}

static void input_method_commit_string(struct wl_client *c, struct wl_resource *r, const char *text)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    char *copy = strdup(text ? text : "");
    if (!copy) { wl_client_post_no_memory(c); return; }
    free(im->commit_text);
    im->commit_text = copy;
}

static void input_method_set_preedit_string(struct wl_client *c, struct wl_resource *r,
                                            const char *text, int32_t begin, int32_t end)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    char *copy = strdup(text ? text : "");
    if (!copy) { wl_client_post_no_memory(c); return; }
    free(im->preedit_text);
    im->preedit_text = copy;
    im->preedit_begin = begin;
    im->preedit_end = end;
}

static void input_method_delete_surrounding_text(struct wl_client *c, struct wl_resource *r,
                                                 uint32_t before, uint32_t after)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    im->delete_before = before;
    im->delete_after = after;
}

static void input_method_commit(struct wl_client *c, struct wl_resource *r, uint32_t serial)
{ (void)c;
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    struct iosc_text_input *ti = text_input_for_focus();
    if (!im || !ti || !im->active || serial != im->done_count) {
        input_method_clear_pending(im);
        return;
    }
    int sent = 0;
    if (im->delete_before || im->delete_after) {
        zwp_text_input_v3_send_delete_surrounding_text(ti->resource, im->delete_before, im->delete_after);
        sent = 1;
    }
    if (im->commit_text && im->commit_text[0]) {
        zwp_text_input_v3_send_commit_string(ti->resource, im->commit_text);
        sent = 1;
    }
    if (im->preedit_text) {
        zwp_text_input_v3_send_preedit_string(ti->resource, im->preedit_text,
                                              im->preedit_begin, im->preedit_end);
        sent = 1;
    }
    if (sent) zwp_text_input_v3_send_done(ti->resource, ti->serial);
    input_method_clear_pending(im);
}

static void input_popup_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_popup_surface_v2_interface input_popup_impl = {
    .destroy = input_popup_destroy,
};

static void input_popup_resource_destroy(struct wl_resource *r)
{
    struct iosc_input_popup *p = wl_resource_get_user_data(r);
    if (!p) return;
    if (g_input_method) {
        for (int i = 0; i < g_input_method->npopups; i++)
            if (g_input_method->popups[i] == p) {
                g_input_method->popups[i] = g_input_method->popups[--g_input_method->npopups];
                break;
            }
    }
    free(p);
}

static void input_method_get_popup_surface(struct wl_client *c, struct wl_resource *r,
                                           uint32_t id, struct wl_resource *surface)
{
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im || im->npopups >= 8) { wl_client_post_no_memory(c); return; }
    struct iosc_input_popup *p = calloc(1, sizeof(*p));
    if (!p) { wl_client_post_no_memory(c); return; }
    p->surface = wl_resource_get_user_data(surface);
    p->resource = wl_resource_create(c, &zwp_input_popup_surface_v2_interface,
                                     wl_resource_get_version(r), id);
    if (!p->resource) { free(p); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(p->resource, &input_popup_impl, p,
                                   input_popup_resource_destroy);
    im->popups[im->npopups++] = p;
}

static void input_method_grab_release(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_method_keyboard_grab_v2_interface input_method_grab_impl = {
    .release = input_method_grab_release,
};

static void input_method_grab_destroy(struct wl_resource *r)
{
    if (g_input_method && g_input_method->keyboard_grab == r)
        g_input_method->keyboard_grab = NULL;
}

static void input_method_grab_keyboard(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) { wl_client_post_no_memory(c); return; }
    struct wl_resource *grab = wl_resource_create(c, &zwp_input_method_keyboard_grab_v2_interface,
                                                  wl_resource_get_version(r), id);
    if (!grab) { wl_client_post_no_memory(c); return; }
    if (im->keyboard_grab) wl_resource_destroy(im->keyboard_grab);
    im->keyboard_grab = grab;
    wl_resource_set_implementation(grab, &input_method_grab_impl, NULL, input_method_grab_destroy);
    if (g_keymap_fd >= 0)
        zwp_input_method_keyboard_grab_v2_send_keymap(grab, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                                      g_keymap_fd, iosc_input_keymap_size());
    zwp_input_method_keyboard_grab_v2_send_repeat_info(grab, 25, 600);
}

static void input_method_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_method_v2_interface input_method_impl = {
    .commit_string = input_method_commit_string,
    .set_preedit_string = input_method_set_preedit_string,
    .delete_surrounding_text = input_method_delete_surrounding_text,
    .commit = input_method_commit,
    .get_input_popup_surface = input_method_get_popup_surface,
    .grab_keyboard = input_method_grab_keyboard,
    .destroy = input_method_destroy,
};

static void input_method_resource_destroy(struct wl_resource *r)
{
    struct iosc_input_method *im = wl_resource_get_user_data(r);
    if (!im) return;
    if (im->keyboard_grab) wl_resource_destroy(im->keyboard_grab);
    while (im->npopups > 0)
        wl_resource_destroy(im->popups[im->npopups - 1]->resource);
    input_method_clear_pending(im);
    if (g_input_method == im) g_input_method = NULL;
    free(im);
}

static void input_method_manager_get_input_method(struct wl_client *c, struct wl_resource *r,
                                                  struct wl_resource *seat, uint32_t id)
{ (void)seat;
    struct iosc_input_method *im = calloc(1, sizeof(*im));
    if (!im) { wl_client_post_no_memory(c); return; }
    struct wl_resource *res = wl_resource_create(c, &zwp_input_method_v2_interface,
                                                 wl_resource_get_version(r), id);
    if (!res) { free(im); wl_client_post_no_memory(c); return; }
    im->resource = res;
    wl_resource_set_implementation(res, &input_method_impl, im, input_method_resource_destroy);
    if (g_input_method) {
        zwp_input_method_v2_send_unavailable(res);
        return;
    }
    g_input_method = im;
    input_method_update_active();
}

static void input_method_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_input_method_manager_v2_interface input_method_manager_impl = {
    .get_input_method = input_method_manager_get_input_method,
    .destroy = input_method_manager_destroy,
};

void input_method_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwp_input_method_manager_v2_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &input_method_manager_impl, NULL, NULL);
}

static void virtual_keyboard_keymap(struct wl_client *c, struct wl_resource *r,
                                    uint32_t format, int32_t fd, uint32_t size)
{ (void)c; (void)format; (void)size;
    struct iosc_virtual_keyboard *vk = wl_resource_get_user_data(r);
    if (vk) vk->has_keymap = 1;
    if (fd >= 0) close(fd);
}

static void virtual_keyboard_key(struct wl_client *c, struct wl_resource *r,
                                 uint32_t time, uint32_t key, uint32_t state)
{ (void)c;
    struct iosc_virtual_keyboard *vk = wl_resource_get_user_data(r);
    if (!vk || !vk->has_keymap) {
        wl_resource_post_error(r, ZWP_VIRTUAL_KEYBOARD_V1_ERROR_NO_KEYMAP,
                               "virtual keyboard key before keymap");
        return;
    }
    keyboard_send_raw_key(time ? time : now_ms(), key, state);
}

static void virtual_keyboard_modifiers(struct wl_client *c, struct wl_resource *r,
                                       uint32_t depressed, uint32_t latched,
                                       uint32_t locked, uint32_t group)
{ (void)c; (void)group;
    struct iosc_virtual_keyboard *vk = wl_resource_get_user_data(r);
    if (!vk || !vk->has_keymap) {
        wl_resource_post_error(r, ZWP_VIRTUAL_KEYBOARD_V1_ERROR_NO_KEYMAP,
                               "virtual keyboard modifiers before keymap");
        return;
    }
    keyboard_send_mods(depressed | latched, locked);
}

static void virtual_keyboard_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static const struct zwp_virtual_keyboard_v1_interface virtual_keyboard_impl = {
    .keymap = virtual_keyboard_keymap,
    .key = virtual_keyboard_key,
    .modifiers = virtual_keyboard_modifiers,
    .destroy = virtual_keyboard_destroy,
};

static void virtual_keyboard_resource_destroy(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void virtual_keyboard_manager_create(struct wl_client *c, struct wl_resource *r,
                                            struct wl_resource *seat, uint32_t id)
{ (void)seat;
    struct iosc_virtual_keyboard *vk = calloc(1, sizeof(*vk));
    if (!vk) { wl_client_post_no_memory(c); return; }
    vk->resource = wl_resource_create(c, &zwp_virtual_keyboard_v1_interface,
                                      wl_resource_get_version(r), id);
    if (!vk->resource) { free(vk); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(vk->resource, &virtual_keyboard_impl, vk,
                                   virtual_keyboard_resource_destroy);
}

static const struct zwp_virtual_keyboard_manager_v1_interface virtual_keyboard_manager_impl = {
    .create_virtual_keyboard = virtual_keyboard_manager_create,
};

void virtual_keyboard_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwp_virtual_keyboard_manager_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &virtual_keyboard_manager_impl, NULL, NULL);
}

static void text_input_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void text_input_enable(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_text_input *ti = wl_resource_get_user_data(r); if (ti) ti->pending_enabled = 1; }

static void text_input_disable(struct wl_client *c, struct wl_resource *r)
{ (void)c; struct iosc_text_input *ti = wl_resource_get_user_data(r); if (ti) ti->pending_enabled = 0; }

static void text_input_set_surrounding_text(struct wl_client *c, struct wl_resource *r,
                                            const char *text, int32_t cursor, int32_t anchor)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    char *copy = strdup(text ? text : "");
    if (!copy) { wl_client_post_no_memory(c); return; }
    free(ti->surrounding);
    ti->surrounding = copy;
    ti->cursor = cursor;
    ti->anchor = anchor;
}

static void text_input_set_text_change_cause(struct wl_client *c, struct wl_resource *r, uint32_t cause)
{ (void)c; struct iosc_text_input *ti = wl_resource_get_user_data(r); if (ti) ti->change_cause = cause; }

static void text_input_set_content_type(struct wl_client *c, struct wl_resource *r,
                                        uint32_t hint, uint32_t purpose)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    ti->content_hint = hint;
    ti->content_purpose = purpose;
}

static void text_input_set_cursor_rectangle(struct wl_client *c, struct wl_resource *r,
                                            int32_t x, int32_t y, int32_t w, int32_t h)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    ti->rect_x = x;
    ti->rect_y = y;
    ti->rect_w = w;
    ti->rect_h = h;
}

static void text_input_commit(struct wl_client *c, struct wl_resource *r)
{ (void)c;
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    ti->enabled = ti->pending_enabled;
    zwp_text_input_v3_send_done(r, ++ti->serial);
    input_method_update_active();
    input_clients_send_traits();
}

static const struct zwp_text_input_v3_interface text_input_impl = {
    .destroy = text_input_destroy,
    .enable = text_input_enable,
    .disable = text_input_disable,
    .set_surrounding_text = text_input_set_surrounding_text,
    .set_text_change_cause = text_input_set_text_change_cause,
    .set_content_type = text_input_set_content_type,
    .set_cursor_rectangle = text_input_set_cursor_rectangle,
    .commit = text_input_commit,
};

static void text_input_resource_destroy(struct wl_resource *r)
{
    struct iosc_text_input *ti = wl_resource_get_user_data(r);
    if (!ti) return;
    for (int i = 0; i < g_ntext_inputs; i++)
        if (g_text_inputs[i] == ti) {
            g_text_inputs[i] = g_text_inputs[--g_ntext_inputs];
            break;
        }
    free(ti->surrounding);
    free(ti);
    input_method_update_active();
    input_clients_send_traits();
}

static void text_input_manager_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }

static void text_input_manager_get_text_input(struct wl_client *c, struct wl_resource *r,
                                              uint32_t id, struct wl_resource *seat)
{ (void)seat;
    if (g_ntext_inputs >= IOSC_MAX_TEXT_INPUTS) { wl_client_post_no_memory(c); return; }
    struct iosc_text_input *ti = calloc(1, sizeof(*ti));
    if (!ti) { wl_client_post_no_memory(c); return; }
    ti->client = c;
    ti->change_cause = ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD;
    ti->content_purpose = ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL;
    ti->resource = wl_resource_create(c, &zwp_text_input_v3_interface,
                                      wl_resource_get_version(r), id);
    if (!ti->resource) { free(ti); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(ti->resource, &text_input_impl, ti,
                                   text_input_resource_destroy);
    g_text_inputs[g_ntext_inputs++] = ti;
    if (g_kbd_focus && wl_resource_get_client(g_kbd_focus->resource) == c) {
        ti->focus_surface = g_kbd_focus;
        zwp_text_input_v3_send_enter(ti->resource, g_kbd_focus->resource);
    }
}

static const struct zwp_text_input_manager_v3_interface text_input_manager_impl = {
    .destroy = text_input_manager_destroy,
    .get_text_input = text_input_manager_get_text_input,
};

void text_input_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{ (void)data;
    struct wl_resource *r = wl_resource_create(client, &zwp_text_input_manager_v3_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &text_input_manager_impl, NULL, NULL);
}

