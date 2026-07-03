/*
 * shell-draw.h — shared non-drawing helpers for the iosc shell clients
 * (ioscbar/ioscdock, ioscoverview, ioscbg). Header-only, all `static`: each binary
 * compiles its own copy (they are separate executables, so no link conflict).
 *
 * Provides: jbroot path resolution, an anonymous wl_shm-pool fd, the shared
 * wl_buffer release listener, the cairo-wrapped wl_shm buffer (SD_CAIRO), the
 * .desktop launcher scan, and the fork+exec launch used by all clients. Actual
 * drawing lives in panel-render.h (cairo/pango); the original 5x7-bitmap
 * renderer that gave this header its name is gone.
 */
#ifndef SHELL_DRAW_H
#define SHELL_DRAW_H

#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>

static const char *sd_jbroot(void)
{
    const char *env = getenv("IOSC_JBROOT");
    if (env && *env) return env;
    env = getenv("JBROOT");
    if (env && *env) return env;
    if (access("/var/jb/usr", X_OK) == 0) return "/var/jb";
    return "";
}

static void sd_join_path(char *dst, size_t dstsz, const char *root,
                         const char *suffix)
{
    if (!root || !*root || !strcmp(root, "/")) snprintf(dst, dstsz, "%s", suffix);
    else {
        size_t n = strlen(root);
        const char *tail = (n && root[n - 1] == '/' && suffix[0] == '/') ? suffix + 1 : suffix;
        snprintf(dst, dstsz, "%s%s", root, tail);
    }
}

static int sd_env_truthy(const char *name)
{
    const char *v = getenv(name);
    return v && *v && strcmp(v, "0") != 0 &&
           strcasecmp(v, "false") != 0 &&
           strcasecmp(v, "no") != 0 &&
           strcasecmp(v, "off") != 0;
}

static int sd_socket_exists(const char *path)
{
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISSOCK(st.st_mode);
}

static int sd_shared_session_bus(const char *root, const char *busdir,
                                 char *addr, size_t addr_n)
{
    char sock[256], daemon[256], address_arg[320];
    if (!busdir || !*busdir || !addr || addr_n == 0) return 0;
    snprintf(sock, sizeof sock, "%s/session-bus", busdir);
    snprintf(addr, addr_n, "unix:path=%s", sock);
    if (sd_socket_exists(sock)) return 1;

    mkdir(busdir, 0700);
    chmod(busdir, 0700);
    unlink(sock);
    sd_join_path(daemon, sizeof daemon, root, "/usr/bin/dbus-daemon");
    snprintf(address_arg, sizeof address_arg, "--address=%s", addr);

    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        int fd = open("/dev/null", O_RDWR);
        if (fd >= 0) {
            dup2(fd, 0);
            dup2(fd, 1);
            dup2(fd, 2);
            if (fd > 2) close(fd);
        }
        execl(daemon, "dbus-daemon", "--session", "--fork",
              address_arg, "--print-address", (char*)NULL);
        _exit(127);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    return sd_socket_exists(sock);
}

/* An anonymous, unlinked, sized fd for a wl_shm pool (backs the clients'
 * cairo-drawn wl_shm buffers). */
static int sd_create_anon_fd(size_t size)
{
    const char *root = sd_jbroot();
    char rooted_tmp[256];
    sd_join_path(rooted_tmp, sizeof rooted_tmp, root, "/tmp");
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    const char *dirs[] = { xdg, rooted_tmp, "/tmp" };
    for (size_t i = 0; i < sizeof(dirs)/sizeof(dirs[0]); i++) {
        if (!dirs[i] || !*dirs[i]) continue;
        char tmpl[512];
        snprintf(tmpl, sizeof tmpl, "%s/ioscshell-XXXXXX", dirs[i]);
        int fd = mkstemp(tmpl);
        if (fd < 0) continue;
        unlink(tmpl);
        if (ftruncate(fd, (off_t)size) < 0) { close(fd); continue; }
        return fd;
    }
    return -1;
}

/* -------------------------------------------------- cairo wl_shm buffers ---
 * Opt in with `#define SD_CAIRO` before including (ioscbar/ioscdock,
 * ioscoverview, and ioscbg). */
#ifdef SD_CAIRO
#include <cairo/cairo.h>

struct sd_cairo_slot {
    struct wl_buffer *buffer;
    void *map;
    size_t size;
    int lw, lh, scale, bw, bh, stride;
    int busy;
    int retire;
};

struct sd_cairo_pool {
    struct sd_cairo_slot slots[3];
};

static void sd_cairo_slot_destroy(struct sd_cairo_slot *slot)
{
    if (!slot) return;
    if (slot->buffer) wl_buffer_destroy(slot->buffer);
    if (slot->map && slot->size) munmap(slot->map, slot->size);
    memset(slot, 0, sizeof *slot);
}

static void sd_cairo_pool_release(void *d, struct wl_buffer *b)
{
    struct sd_cairo_slot *slot = d;
    (void)b;
    if (!slot) return;
    slot->busy = 0;
    if (slot->retire)
        sd_cairo_slot_destroy(slot);
}

static const struct wl_buffer_listener sd_cairo_pool_listener = {
    .release = sd_cairo_pool_release,
};

static int sd_cairo_slot_matches(const struct sd_cairo_slot *slot,
                                 int lw, int lh, int scale)
{
    return slot->buffer && !slot->retire &&
           slot->lw == lw && slot->lh == lh && slot->scale == scale;
}

static int sd_cairo_slot_init(struct sd_cairo_slot *slot, struct wl_shm *shm,
                              int lw, int lh, int scale)
{
    int s = scale > 0 ? scale : 1;
    int bw = lw * s, bh = lh * s;
    int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, bw);
    size_t size = (size_t)stride * (size_t)bh;
    int fd = sd_create_anon_fd(size);
    if (fd < 0) return 0;
    void *map = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { close(fd); return 0; }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, bw, bh, stride,
                                                      WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    if (!buf) { munmap(map, size); return 0; }

    memset(slot, 0, sizeof *slot);
    slot->buffer = buf;
    slot->map = map;
    slot->size = size;
    slot->lw = lw;
    slot->lh = lh;
    slot->scale = s;
    slot->bw = bw;
    slot->bh = bh;
    slot->stride = stride;
    wl_buffer_add_listener(buf, &sd_cairo_pool_listener, slot);
    return 1;
}

static struct sd_cairo_slot *sd_cairo_pool_begin(struct sd_cairo_pool *pool,
                                                 struct wl_shm *shm,
                                                 int lw, int lh, int scale,
                                                 cairo_t **out_cr,
                                                 cairo_surface_t **out_surf)
{
    if (!pool || !shm || lw <= 0 || lh <= 0) return NULL;

    struct sd_cairo_slot *chosen = NULL;
    for (size_t i = 0; i < sizeof(pool->slots)/sizeof(pool->slots[0]); i++) {
        struct sd_cairo_slot *slot = &pool->slots[i];
        if (sd_cairo_slot_matches(slot, lw, lh, scale) && !slot->busy) {
            chosen = slot;
            break;
        }
    }
    if (!chosen) {
        for (size_t i = 0; i < sizeof(pool->slots)/sizeof(pool->slots[0]); i++) {
            struct sd_cairo_slot *slot = &pool->slots[i];
            if (slot->buffer && !slot->busy && !sd_cairo_slot_matches(slot, lw, lh, scale))
                sd_cairo_slot_destroy(slot);
            if (!slot->buffer) {
                if (!sd_cairo_slot_init(slot, shm, lw, lh, scale)) return NULL;
                chosen = slot;
                break;
            }
        }
    }
    if (!chosen) {
        for (size_t i = 0; i < sizeof(pool->slots)/sizeof(pool->slots[0]); i++)
            if (pool->slots[i].buffer && pool->slots[i].busy)
                pool->slots[i].retire = 1;
        return NULL;
    }

    cairo_surface_t *surf = cairo_image_surface_create_for_data(
        (unsigned char *)chosen->map, CAIRO_FORMAT_ARGB32,
        chosen->bw, chosen->bh, chosen->stride);
    cairo_t *cr = cairo_create(surf);
    cairo_scale(cr, chosen->scale, chosen->scale);
    chosen->busy = 1;
    *out_cr = cr;
    *out_surf = surf;
    return chosen;
}

static void sd_cairo_pool_destroy(struct sd_cairo_pool *pool)
{
    if (!pool) return;
    for (size_t i = 0; i < sizeof(pool->slots)/sizeof(pool->slots[0]); i++) {
        if (pool->slots[i].busy) pool->slots[i].retire = 1;
        else sd_cairo_slot_destroy(&pool->slots[i]);
    }
}

#endif /* SD_CAIRO */

/* ------------------------------------------------------- .desktop scan ---- */

#if defined(SD_APP_SCAN) || defined(SD_DESKTOP_PINNING)
struct sd_app { char name[64]; char exec[256]; char icon[128]; };
#endif

#ifdef SD_APP_SCAN
static void sd_strip_field_codes(char *exec)
{
    char *w = exec;
    for (char *r = exec; *r; r++) {
        if (r[0] == '%' && r[1]) { r++; continue; }
        *w++ = *r;
    }
    *w = 0;
    while (w > exec && w[-1] == ' ') *--w = 0;
}

/* scan a .desktop dir for Type=Application, !NoDisplay entries. */
static int sd_scan_apps_dir(const char *dir, struct sd_app *apps, int n, int max)
{
    DIR *d = opendir(dir);
    if (!d) return n;
    struct dirent *e;
    while ((e = readdir(d)) && n < max) {
        size_t len = strlen(e->d_name);
        if (len < 9 || strcmp(e->d_name + len - 8, ".desktop")) continue;
        char path[512]; snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        FILE *f = fopen(path, "r"); if (!f) continue;
        char line[512], name[64] = {0}, exec[256] = {0}, icon[128] = {0};
        int nodisplay = 0, in_entry = 0;
        while (fgets(line, sizeof line, f)) {
            if (line[0] == '[') { in_entry = !strncmp(line, "[Desktop Entry]", 15); continue; }
            if (!in_entry) continue;
            if (!strncmp(line, "Name=", 5) && !name[0]) sscanf(line + 5, "%63[^\n]", name);
            else if (!strncmp(line, "Exec=", 5) && !exec[0]) sscanf(line + 5, "%255[^\n]", exec);
            else if (!strncmp(line, "Icon=", 5) && !icon[0]) sscanf(line + 5, "%127[^\n]", icon);
            else if (!strncmp(line, "NoDisplay=true", 14)) nodisplay = 1;
        }
        fclose(f);
        if (nodisplay || !exec[0]) continue;
        sd_strip_field_codes(exec);
        if (!name[0]) snprintf(name, sizeof name, "%.*s", (int)(len-8), e->d_name);
        snprintf(apps[n].name, 64, "%s", name);
        snprintf(apps[n].exec, 256, "%s", exec);
        snprintf(apps[n].icon, 128, "%s", icon);
        n++;
    }
    closedir(d);
    return n;
}

static int sd_scan_apps(struct sd_app *apps, int max)
{
    int n = 0;
    const char *override = getenv("IOSC_APPS_DIR");
    if (override && *override) n = sd_scan_apps_dir(override, apps, n, max);

    const char *root = sd_jbroot();
    char sys_apps[256], local_apps[256];
    sd_join_path(sys_apps, sizeof sys_apps, root, "/usr/share/applications");
    sd_join_path(local_apps, sizeof local_apps, root, "/usr/local/share/applications");
    n = sd_scan_apps_dir(sys_apps, apps, n, max);
    if (strcmp(local_apps, sys_apps)) n = sd_scan_apps_dir(local_apps, apps, n, max);
    return n;
}
#endif /* SD_APP_SCAN */

#if defined(SD_DESKTOP_PINS) || defined(SD_DESKTOP_PINNING)
static void sd_desktop_pins_path(char *out, size_t n)
{
    const char *env = getenv("IOSC_DESKTOP_PINS");
    if (env && *env) { snprintf(out, n, "%s", env); return; }
    snprintf(out, n, "/var/mobile/Library/Preferences/com.max.iosc-desktop-pins.conf");
}
#endif

#ifdef SD_DESKTOP_PINNING
static int sd_desktop_pin_exists(const char *exec)
{
    if (!exec || !*exec) return 1;
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    char line[768];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        char *save = NULL;
        char *type = strtok_r(line, "\t\r\n", &save);
        char *name = strtok_r(NULL, "\t\r\n", &save);
        char *icon = strtok_r(NULL, "\t\r\n", &save);
        char *target = strtok_r(NULL, "\t\r\n", &save);
        (void)type; (void)name; (void)icon;
        if (target && !strcmp(target, exec)) { found = 1; break; }
    }
    fclose(f);
    return found;
}

static void sd_pin_app_to_desktop(const struct sd_app *app)
{
    if (!app || !app->exec[0] || sd_desktop_pin_exists(app->exec)) return;
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    FILE *f = fopen(path, "a");
    if (!f) return;
    int slot = 0;
    {
        FILE *r = fopen(path, "r");
        char line[768];
        while (r && fgets(line, sizeof line, r)) slot++;
        if (r) fclose(r);
    }
    int x = 300 + (slot % 6) * 104;
    int y = 96 + (slot / 6) * 122;
    fprintf(f, "app\t%s\t%s\t%s\t%d\t%d\n", app->name, app->icon, app->exec, x, y);
    fclose(f);
}
#endif /* SD_DESKTOP_PINNING */

/* fork+exec a .desktop Exec under the same Wayland/dbus env run-kgx.sh proved
 * good. The shell clients run outside the iOS app sandbox (started by ioscd or a
 * run-script), so this is the direct path. */
static void sd_launch(const char *exec)
{
    pid_t pid = fork();
    if (pid != 0) return;
    setsid();
    const char *root = sd_jbroot();
    char tmp[256], wayland[256], home[256], path[512], busdir[256], bus_addr[320];
    char dbus_run[256], sh_bin[256], usr_sh[256];
    sd_join_path(tmp, sizeof tmp, root, "/tmp");
    sd_join_path(wayland, sizeof wayland, root, "/tmp/wayland-0");
    sd_join_path(home, sizeof home, root, "/var/root");
    sd_join_path(busdir, sizeof busdir, root, "/tmp/iosc-shell-bus");
    sd_join_path(dbus_run, sizeof dbus_run, root, "/usr/bin/dbus-run-session");
    sd_join_path(sh_bin, sizeof sh_bin, root, "/bin/sh");
    sd_join_path(usr_sh, sizeof usr_sh, root, "/usr/bin/sh");
    if (!root || !*root || !strcmp(root, "/"))
        snprintf(path, sizeof path, "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin");
    else
        snprintf(path, sizeof path,
                 "%s/usr/local/bin:%s/usr/bin:%s/usr/sbin:%s/bin:%s/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
                 root, root, root, root, root);
    const char *env_wayland = getenv("WAYLAND_DISPLAY");
    const char *env_runtime = getenv("XDG_RUNTIME_DIR");
    setenv("WAYLAND_DISPLAY", (env_wayland && *env_wayland) ? env_wayland : wayland, 1);
    int have_bus = sd_shared_session_bus(root, busdir, bus_addr, sizeof bus_addr);
    setenv("XDG_RUNTIME_DIR", have_bus ? busdir : ((env_runtime && *env_runtime) ? env_runtime : tmp), 1);
    if (have_bus) setenv("DBUS_SESSION_BUS_ADDRESS", bus_addr, 1);
    setenv("GDK_BACKEND", "wayland", 1);
    setenv("GSK_RENDERER", "ngl", 1);
    setenv("ANGLE_REAL_LIBEGL", "/var/jb/lib/angle/libEGL.angle.dylib", 1);
    setenv("GSETTINGS_BACKEND", "memory", 1);
    int enable_a11y = sd_env_truthy("XIOS_ENABLE_A11Y") || access("/var/jb/tmp/xios-a11y-force", F_OK) == 0;
    if (enable_a11y) unsetenv("GTK_A11Y");
    else setenv("GTK_A11Y", "none", 1);
    setenv("SHELL", sh_bin, 1);
    setenv("PATH", path, 1);
    if (!getenv("HOME")) setenv("HOME", home, 1);
    const char *cmd = exec;
    char a11y_cmd[4096];
    if (enable_a11y) {
        int n = snprintf(a11y_cmd, sizeof(a11y_cmd),
                         "if command -v xios-start-a11y >/dev/null 2>&1; then "
                         "xios-start-a11y; fi; exec %s", exec);
        if (n > 0 && (size_t)n < sizeof(a11y_cmd)) cmd = a11y_cmd;
    }
    if (!have_bus)
        execl(dbus_run, "dbus-run-session", "--", sh_bin, "-lc", cmd, (char*)NULL);
    execl(sh_bin, "sh", "-lc", cmd, (char*)NULL);
    execl(usr_sh, "sh", "-lc", cmd, (char*)NULL);
    _exit(127);
}

#endif /* SHELL_DRAW_H */
