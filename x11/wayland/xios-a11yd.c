/*
 * xios-a11yd.c — first read-only AT-SPI -> Xios NDJSON bridge helper.
 *
 * v0 polls periodically instead of handling AT-SPI events, but only republishes
 * when the snapshot changes. It is enough to exercise the HostA11y/Xios client
 * side while the event/action bridge is built out.
 */
#include <atspi/atspi.h>
#include <glib.h>

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define SOCK_PATH "/var/jb/tmp/xios-a11y.sock"
#define MAX_CLIENTS 16
#define MAX_NODES 300
#define MAX_DEPTH 8
#define MAX_REFS MAX_NODES

struct node_ref {
    unsigned id;
    unsigned win;
    AtspiRect rect;
    AtspiAccessible *obj;
};

struct client {
    int fd;
    int enabled;
    unsigned gen;
    char bind_appid[256];
    char bind_exec[256];
    char *last_snapshot;
    struct node_ref refs[MAX_REFS];
    unsigned ref_count;
};

struct emit_ctx {
    struct client *c;
    GString *out;
    unsigned win;
    unsigned next_id;
    unsigned count;
};

static struct client clients[MAX_CLIENTS];
static unsigned global_gen = 1;

static char *json_escape(const char *s)
{
    if (!s) return g_strdup("");
    GString *out = g_string_new("");
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '\\': g_string_append(out, "\\\\"); break;
        case '"': g_string_append(out, "\\\""); break;
        case '\n': g_string_append(out, "\\n"); break;
        case '\r': g_string_append(out, "\\r"); break;
        case '\t': g_string_append(out, "\\t"); break;
        default:
            if (*p < 0x20) g_string_append_printf(out, "\\u%04x", *p);
            else g_string_append_c(out, (char)*p);
        }
    }
    return g_string_free(out, FALSE);
}

static void client_printf(struct client *c, const char *fmt, ...)
{
    if (!c || c->fd < 0) return;
    char buf[8192];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if ((size_t)n >= sizeof(buf)) n = (int)sizeof(buf) - 1;
    if (write(c->fd, buf, (size_t)n) < 0 && (errno == EPIPE || errno == ECONNRESET)) {
        close(c->fd);
        c->fd = -1;
    }
}

static const char *trait_for_role(const char *role)
{
    if (!role) return "";
    if (strstr(role, "button") || strstr(role, "menu item")) return "\"button\"";
    if (strstr(role, "link")) return "\"link\"";
    if (strstr(role, "heading")) return "\"header\"";
    if (strstr(role, "label") || strstr(role, "static")) return "\"static-text\"";
    if (strstr(role, "image") || strstr(role, "icon")) return "\"image\"";
    if (strstr(role, "slider") || strstr(role, "spin") || strstr(role, "scroll bar")) return "\"adjustable\"";
    if (strstr(role, "page tab list")) return "\"tab-bar\"";
    return "";
}

static int json_get_string(const char *json, const char *key, char *out, size_t out_len)
{
    if (!json || !key || !out || out_len == 0) return 0;
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return 0;
    p += strlen(needle);
    p = strchr(p, ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return 0;
    p++;

    size_t n = 0;
    while (*p && *p != '"' && n + 1 < out_len) {
        if (*p == '\\' && p[1]) p++;
        out[n++] = *p++;
    }
    out[n] = 0;
    return n > 0;
}

static int json_get_uint(const char *json, const char *key, unsigned *out)
{
    if (!json || !key || !out) return 0;
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return 0;
    p += strlen(needle);
    p = strchr(p, ':');
    if (!p) return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p < '0' || *p > '9') return 0;
    unsigned v = 0;
    while (*p >= '0' && *p <= '9') {
        v = v * 10u + (unsigned)(*p - '0');
        p++;
    }
    *out = v;
    return 1;
}

static const char *basename_no_args(const char *s, char *buf, size_t len)
{
    if (!s || !*s || !buf || len == 0) return "";
    while (*s == ' ' || *s == '\t') s++;
    const char *end = s;
    while (*end && *end != ' ' && *end != '\t') end++;
    const char *base = end;
    while (base > s && base[-1] != '/') base--;
    size_t n = (size_t)(end - base);
    if (n >= len) n = len - 1;
    memcpy(buf, base, n);
    buf[n] = 0;
    return buf;
}

static int str_eq(const char *a, const char *b)
{
    return a && b && *a && *b && strcmp(a, b) == 0;
}

static int client_wants_app(struct client *c, const char *app_name, const char *title)
{
    if (!c || (!c->bind_appid[0] && !c->bind_exec[0])) return 1;
    if (str_eq(c->bind_appid, app_name) || str_eq(c->bind_appid, title)) return 1;
    if (str_eq(c->bind_exec, app_name) || str_eq(c->bind_exec, title)) return 1;

    char appid_base[128] = {0};
    const char *dot = strrchr(c->bind_appid, '.');
    if (dot && dot[1]) {
        snprintf(appid_base, sizeof(appid_base), "%s", dot + 1);
        if (str_eq(appid_base, app_name) || str_eq(appid_base, title)) return 1;
    }

    char exec_base[128] = {0};
    basename_no_args(c->bind_exec, exec_base, sizeof(exec_base));
    if (str_eq(exec_base, app_name) || str_eq(exec_base, title)) return 1;
    return 0;
}

static AtspiRect node_rect(AtspiAccessible *obj)
{
    AtspiRect out = {0, 0, 1, 1};
    AtspiComponent *component = atspi_accessible_get_component(obj);
    if (!component) return out;
    GError *error = NULL;
    AtspiRect *r = atspi_component_get_extents(component, ATSPI_COORD_TYPE_WINDOW, &error);
    if (!error && r) out = *r;
    if (error) g_clear_error(&error);
    if (r) g_boxed_free(ATSPI_TYPE_RECT, r);
    g_object_unref(component);
    if (out.width <= 0) out.width = 1;
    if (out.height <= 0) out.height = 1;
    return out;
}

static void client_clear_refs(struct client *c)
{
    if (!c) return;
    for (unsigned i = 0; i < c->ref_count; i++) {
        if (c->refs[i].obj) g_object_unref(c->refs[i].obj);
        c->refs[i].obj = NULL;
        c->refs[i].id = 0;
    }
    c->ref_count = 0;
}

static void client_remember_node(struct client *c, unsigned id, unsigned win, AtspiRect rect, AtspiAccessible *obj)
{
    if (!c || !obj || c->ref_count >= MAX_REFS) return;
    c->refs[c->ref_count].id = id;
    c->refs[c->ref_count].win = win;
    c->refs[c->ref_count].rect = rect;
    c->refs[c->ref_count].obj = g_object_ref(obj);
    c->ref_count++;
}

static struct node_ref *client_find_node(struct client *c, unsigned id)
{
    if (!c) return NULL;
    for (unsigned i = 0; i < c->ref_count; i++) {
        if (c->refs[i].id == id) return &c->refs[i];
    }
    return NULL;
}

static char *node_actions_json(AtspiAccessible *obj)
{
    GString *out = g_string_new("");
    AtspiAction *action = atspi_accessible_get_action(obj);
    if (!action) return g_string_free(out, FALSE);

    GError *error = NULL;
    int n_actions = atspi_action_get_n_actions(action, &error);
    if (error) {
        g_clear_error(&error);
        n_actions = 0;
    }
    if (n_actions > 16) n_actions = 16;

    for (int i = 0; i < n_actions; i++) {
        char *name = atspi_action_get_localized_name(action, i, &error);
        if (error) {
            g_clear_error(&error);
            name = NULL;
        }
        if (!name || !*name) {
            g_free(name);
            name = atspi_action_get_action_name(action, i, &error);
            if (error) {
                g_clear_error(&error);
                name = NULL;
            }
        }
        if (!name || !*name) {
            g_free(name);
            continue;
        }
        char *jname = json_escape(name);
        if (out->len > 0) g_string_append_c(out, ',');
        g_string_append_printf(out, "\"%s\"", jname);
        g_free(jname);
        g_free(name);
    }

    g_object_unref(action);
    return g_string_free(out, FALSE);
}

static void emit_node(struct emit_ctx *ctx, AtspiAccessible *obj, unsigned parent, int idx, int depth)
{
    if (!ctx || !obj || depth > MAX_DEPTH || ctx->count >= MAX_NODES) return;

    GError *error = NULL;
    char *name = atspi_accessible_get_name(obj, &error);
    if (error) { g_clear_error(&error); name = NULL; }
    char *role = atspi_accessible_get_role_name(obj, &error);
    if (error) { g_clear_error(&error); role = NULL; }
    char *desc = atspi_accessible_get_description(obj, &error);
    if (error) { g_clear_error(&error); desc = NULL; }
    int child_count = atspi_accessible_get_child_count(obj, &error);
    if (error) { g_clear_error(&error); child_count = 0; }

    AtspiRect r = node_rect(obj);
    char *jname = json_escape(name);
    char *jrole = json_escape(role && *role ? role : "unknown");
    char *jdesc = json_escape(desc);
    const char *trait = trait_for_role(role);
    unsigned id = ctx->next_id++;
    ctx->count++;
    client_remember_node(ctx->c, id, ctx->win, r, obj);
    char *actions = node_actions_json(obj);

    g_string_append_printf(ctx->out,
                           "{\"t\":\"upsert\",\"id\":%u,\"win\":%u,\"parent\":%u,\"idx\":%d,"
                           "\"role\":\"%s\",\"label\":\"%s\",\"value\":\"\",\"hint\":\"%s\","
                           "\"traits\":[%s],\"actions\":[%s],\"frame\":[%d,%d,%d,%d]}\n",
                           id, ctx->win, parent, idx, jrole, jname, jdesc, trait, actions,
                           r.x, r.y, r.width, r.height);

    g_free(actions);
    g_free(jname);
    g_free(jrole);
    g_free(jdesc);
    g_free(name);
    g_free(role);
    g_free(desc);

    if (child_count > 80) child_count = 80;
    for (int i = 0; i < child_count; i++) {
        AtspiAccessible *child = atspi_accessible_get_child_at_index(obj, i, &error);
        if (error) { g_clear_error(&error); continue; }
        emit_node(ctx, child, id, i, depth + 1);
        if (child) g_object_unref(child);
    }
}

static void snapshot_client(struct client *c)
{
    if (!c || c->fd < 0 || !c->enabled) return;

    client_clear_refs(c);
    GString *snapshot = g_string_new("");

    int desktops = atspi_get_desktop_count();
    unsigned win_id = 1;
    for (int d = 0; d < desktops; d++) {
        AtspiAccessible *desktop = atspi_get_desktop(d);
        if (!desktop) continue;
        GError *error = NULL;
        int apps = atspi_accessible_get_child_count(desktop, &error);
        if (error) { g_clear_error(&error); apps = 0; }
        for (int a = 0; a < apps; a++) {
            AtspiAccessible *app = atspi_accessible_get_child_at_index(desktop, a, &error);
            if (error) { g_clear_error(&error); continue; }
            char *app_name = atspi_accessible_get_name(app, NULL);
            int tops = atspi_accessible_get_child_count(app, &error);
            if (error) { g_clear_error(&error); tops = 0; }
            for (int t = 0; t < tops; t++) {
                AtspiAccessible *top = atspi_accessible_get_child_at_index(app, t, &error);
                if (error) { g_clear_error(&error); continue; }
                char *title = atspi_accessible_get_name(top, NULL);
                if (!client_wants_app(c, app_name, title)) {
                    g_free(title);
                    if (top) g_object_unref(top);
                    continue;
                }
                char *japp = json_escape(app_name);
                char *jtitle = json_escape(title && *title ? title : app_name);
                unsigned win = win_id++;
                g_string_append_printf(snapshot,
                                       "{\"t\":\"window\",\"id\":%u,\"appid\":\"%s\",\"title\":\"%s\","
                                       "\"frame\":[0,0,1,1],\"focused\":true}\n",
                                       win, japp, jtitle);
                struct emit_ctx ctx = { .c = c, .out = snapshot, .win = win, .next_id = win * 1000, .count = 0 };
                int kids = atspi_accessible_get_child_count(top, &error);
                if (error) { g_clear_error(&error); kids = 0; }
                for (int i = 0; i < kids; i++) {
                    AtspiAccessible *child = atspi_accessible_get_child_at_index(top, i, &error);
                    if (error) { g_clear_error(&error); continue; }
                    emit_node(&ctx, child, 0, i, 1);
                    if (child) g_object_unref(child);
                }
                g_free(japp);
                g_free(jtitle);
                g_free(title);
                if (top) g_object_unref(top);
            }
            g_free(app_name);
            if (app) g_object_unref(app);
        }
        g_object_unref(desktop);
    }

    if (c->last_snapshot && strcmp(c->last_snapshot, snapshot->str) == 0) {
        g_string_free(snapshot, TRUE);
        return;
    }

    g_free(c->last_snapshot);
    c->last_snapshot = g_strdup(snapshot->str);
    c->gen = global_gen++;
    client_printf(c, "{\"t\":\"reset\",\"gen\":%u}\n", c->gen);
    if (snapshot->len > 0 && write(c->fd, snapshot->str, snapshot->len) < 0 &&
        (errno == EPIPE || errno == ECONNRESET)) {
        close(c->fd);
        c->fd = -1;
    }
    g_string_free(snapshot, TRUE);
}

static int do_node_action(struct client *c, unsigned id, unsigned idx)
{
    struct node_ref *ref = client_find_node(c, id);
    if (!ref || !ref->obj) return 0;
    AtspiAction *action = atspi_accessible_get_action(ref->obj);
    if (!action) return 0;

    GError *error = NULL;
    int n_actions = atspi_action_get_n_actions(action, &error);
    if (error) {
        g_clear_error(&error);
        n_actions = 0;
    }

    int ok = 0;
    if (idx < (unsigned)n_actions) {
        ok = atspi_action_do_action(action, (int)idx, &error) ? 1 : 0;
        if (error) g_clear_error(&error);
    }
    g_object_unref(action);
    return ok;
}

static void activate_node(struct client *c, unsigned id)
{
    if (do_node_action(c, id, 0)) return;

    struct node_ref *ref = client_find_node(c, id);
    if (!ref) return;
    int x = ref->rect.x + ref->rect.width / 2;
    int y = ref->rect.y + ref->rect.height / 2;
    client_printf(c, "{\"t\":\"tap\",\"win\":%u,\"x\":%d,\"y\":%d}\n", ref->win, x, y);
}

static int make_listener(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    unlink(SOCK_PATH);
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strncpy(sa.sun_path, SOCK_PATH, sizeof(sa.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    struct passwd *pw = getpwnam("mobile");
    struct group *gr = getgrnam("mobile");
    if (pw && gr) {
        chown(SOCK_PATH, pw->pw_uid, gr->gr_gid);
        chmod(SOCK_PATH, 0660);
    } else {
        chmod(SOCK_PATH, 0600);
        fprintf(stderr, "xios-a11yd: warning: mobile user/group missing; socket is root-only\n");
    }
    if (listen(fd, 8) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void accept_client(int listener)
{
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return;
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (clients[i].fd < 0) {
            clients[i].fd = fd;
            clients[i].enabled = 0;
            clients[i].gen = global_gen++;
            clients[i].bind_appid[0] = 0;
            clients[i].bind_exec[0] = 0;
            g_free(clients[i].last_snapshot);
            clients[i].last_snapshot = NULL;
            client_printf(&clients[i], "{\"t\":\"hello\",\"gen\":%u}\n", clients[i].gen);
            return;
        }
    }
    close(fd);
}

static void read_client(struct client *c)
{
    char buf[1024];
    ssize_t n = read(c->fd, buf, sizeof(buf) - 1);
    if (n <= 0) {
        close(c->fd);
        c->fd = -1;
        g_free(c->last_snapshot);
        c->last_snapshot = NULL;
        client_clear_refs(c);
        return;
    }
    buf[n] = 0;
    if (strstr(buf, "\"bind\"")) {
        json_get_string(buf, "appid", c->bind_appid, sizeof(c->bind_appid));
        json_get_string(buf, "exec", c->bind_exec, sizeof(c->bind_exec));
        g_free(c->last_snapshot);
        c->last_snapshot = NULL;
        snapshot_client(c);
    }
    if (strstr(buf, "\"enable\"") && (strstr(buf, "\"on\":true") || strstr(buf, "\"on\": true"))) {
        c->enabled = 1;
        snapshot_client(c);
    }
    if (strstr(buf, "\"enable\"") && (strstr(buf, "\"on\":false") || strstr(buf, "\"on\": false"))) {
        c->enabled = 0;
        g_free(c->last_snapshot);
        c->last_snapshot = NULL;
        client_clear_refs(c);
    }
    if (strstr(buf, "\"activate\"")) {
        unsigned id = 0;
        if (json_get_uint(buf, "id", &id)) activate_node(c, id);
    }
    if (strstr(buf, "\"action\"")) {
        unsigned id = 0;
        unsigned idx = 0;
        if (json_get_uint(buf, "id", &id) && json_get_uint(buf, "idx", &idx)) {
            do_node_action(c, id, idx);
        }
    }
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        clients[i].fd = -1;
        clients[i].bind_appid[0] = 0;
        clients[i].bind_exec[0] = 0;
        clients[i].last_snapshot = NULL;
        clients[i].ref_count = 0;
    }
    if (atspi_init() != 0) {
        fprintf(stderr, "xios-a11yd: atspi_init failed\n");
        return 1;
    }
    int listener = make_listener();
    if (listener < 0) {
        perror("xios-a11yd: listen");
        return 1;
    }
    fprintf(stderr, "xios-a11yd: listening on %s\n", SOCK_PATH);

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(listener, &rfds);
        int maxfd = listener;
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i].fd >= 0) {
                FD_SET(clients[i].fd, &rfds);
                if (clients[i].fd > maxfd) maxfd = clients[i].fd;
            }
        }
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        int rc = select(maxfd + 1, &rfds, NULL, NULL, &tv);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0) break;
        if (FD_ISSET(listener, &rfds)) accept_client(listener);
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (clients[i].fd >= 0 && FD_ISSET(clients[i].fd, &rfds)) read_client(&clients[i]);
        }
        if (rc == 0) {
            for (int i = 0; i < MAX_CLIENTS; i++) snapshot_client(&clients[i]);
        }
    }
    close(listener);
    unlink(SOCK_PATH);
    return 1;
}
