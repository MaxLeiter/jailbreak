/*
 * iosc_activation.c — xdg-activation-v1.
 *
 * Split out of iosc.c. A client asks for a token, hands it to another client
 * out of band, and that client presents it with xdg_activation_v1.activate to
 * raise and focus its own surface. Tokens are single-use.
 */
#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "xdg-activation-v1-server-protocol.h"

#include "iosc_internal.h"
#include "iosc_util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- xdg-activation ------------------------------------------------------ */

struct iosc_activation_token {
    int used;
    uint32_t serial;
    struct wl_resource *seat;
    struct wl_resource *surface;
    char app_id[256];
};

static uint32_t g_activation_token_id;

struct iosc_activation_record {
    char token[32];
    char app_id[256];
    struct iosc_surface *surface;
    uint32_t serial;
};

#define IOSC_ACTIVATION_RECORDS 64
static struct iosc_activation_record g_activation_records[IOSC_ACTIVATION_RECORDS];
static unsigned g_activation_record_next;

static void activation_remember(const char *token, const struct iosc_activation_token *tok)
{
    struct iosc_activation_record *rec =
        &g_activation_records[g_activation_record_next++ % IOSC_ACTIVATION_RECORDS];
    memset(rec, 0, sizeof(*rec));
    snprintf(rec->token, sizeof(rec->token), "%s", token ? token : "");
    snprintf(rec->app_id, sizeof(rec->app_id), "%s", tok && tok->app_id[0] ? tok->app_id : "");
    rec->surface = tok && tok->surface ? wl_resource_get_user_data(tok->surface) : NULL;
    rec->serial = tok ? tok->serial : 0;
}

static const struct iosc_activation_record *activation_find(const char *token)
{
    if (!token || !*token) return NULL;
    for (unsigned i = 0; i < IOSC_ACTIVATION_RECORDS; i++) {
        const struct iosc_activation_record *rec = &g_activation_records[i];
        if (rec->token[0] && strcmp(rec->token, token) == 0) return rec;
    }
    return NULL;
}

static void activation_token_destroy_resource(struct wl_resource *r)
{
    free(wl_resource_get_user_data(r));
}

static void activation_token_set_serial(struct wl_client *c, struct wl_resource *r,
                                        uint32_t serial, struct wl_resource *seat)
{
    (void)c;
    struct iosc_activation_token *tok = wl_resource_get_user_data(r);
    if (tok) { tok->serial = serial; tok->seat = seat; }
}
static void activation_token_set_app_id(struct wl_client *c, struct wl_resource *r,
                                        const char *app_id)
{
    (void)c;
    struct iosc_activation_token *tok = wl_resource_get_user_data(r);
    if (tok) snprintf(tok->app_id, sizeof(tok->app_id), "%s", app_id ? app_id : "");
}
static void activation_token_set_surface(struct wl_client *c, struct wl_resource *r,
                                         struct wl_resource *surface)
{
    (void)c;
    struct iosc_activation_token *tok = wl_resource_get_user_data(r);
    if (tok) tok->surface = surface;
}
static void activation_token_commit(struct wl_client *c, struct wl_resource *r)
{
    (void)c;
    struct iosc_activation_token *tok = wl_resource_get_user_data(r);
    if (tok->used) {
        wl_resource_post_error(r, XDG_ACTIVATION_TOKEN_V1_ERROR_ALREADY_USED,
                               "activation token already committed");
        return;
    }
    tok->used = 1;
    char token[32];
    snprintf(token, sizeof(token), "iosc-%u", ++g_activation_token_id);
    activation_remember(token, tok);
    xdg_activation_token_v1_send_done(r, token);
}
static void activation_token_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static const struct xdg_activation_token_v1_interface activation_token_impl = {
    .set_serial = activation_token_set_serial,
    .set_app_id = activation_token_set_app_id,
    .set_surface = activation_token_set_surface,
    .commit = activation_token_commit,
    .destroy = activation_token_destroy,
};

static void activation_destroy(struct wl_client *c, struct wl_resource *r)
{ (void)c; wl_resource_destroy(r); }
static void activation_get_token(struct wl_client *c, struct wl_resource *r, uint32_t id)
{
    struct iosc_activation_token *tok = calloc(1, sizeof(*tok));
    if (!tok) { wl_client_post_no_memory(c); return; }
    struct wl_resource *tr = wl_resource_create(c, &xdg_activation_token_v1_interface,
                                                wl_resource_get_version(r), id);
    if (!tr) { free(tok); wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(tr, &activation_token_impl, tok,
                                   activation_token_destroy_resource);
}
static void activation_activate(struct wl_client *c, struct wl_resource *r,
                                const char *token, struct wl_resource *surface)
{
    (void)c; (void)r;
    const struct iosc_activation_record *rec = activation_find(token);
    if (iosc_debug() && rec) {
        fprintf(stderr, "iosc: xdg-activation token=%s app_id=\"%s\" serial=%u\n",
                token ? token : "", rec->app_id, rec->serial);
    }
    struct iosc_surface *s = wl_resource_get_user_data(surface);
    if (!s || !s->mapped) return;
    surface_raise(s);
    keyboard_set_focus(s);
    if (g_output_damage_valid) recomposite_all();
}
static const struct xdg_activation_v1_interface activation_impl = {
    .destroy = activation_destroy,
    .get_activation_token = activation_get_token,
    .activate = activation_activate,
};
void activation_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id)
{
    (void)data;
    struct wl_resource *r = wl_resource_create(client, &xdg_activation_v1_interface,
                                               version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &activation_impl, NULL, NULL);
}
