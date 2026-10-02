/*
 * shell-draw.h — shared non-drawing helpers for the iosc shell clients
 * (ioscbar/ioscdock, ioscoverview, ioscbg). Header-only, all `static`: each binary
 * compiles its own copy (they are separate executables, so no link conflict).
 *
 * Provides: jbroot path resolution, an anonymous wl_shm-pool fd, the shared
 * wl_buffer release listener, the cairo-wrapped wl_shm buffer (SD_CAIRO), the
 * .desktop launcher scan, and the fork+exec launch (as mobile) used by all
 * clients. Actual drawing lives in panel-render.h (cairo/pango); the original
 * 5x7-bitmap renderer that gave this header its name is gone.
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
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>

/* The user's Documents. mobile's home is not under the jbroot: ioscd runs apps
 * as mobile with HOME from getpwnam("mobile"), i.e. /var/mobile, so this is
 * where they and "Open Documents" look. */
#define SD_USER_DOCUMENTS "/var/mobile/Documents"

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

static uint64_t sd_mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* A bus socket whose dbus-daemon died without its own cleanup (SIGKILL from
 * the session teardown's second pass, jetsam) still stat()s as a socket;
 * only a refused connect tells it apart from a live listener. */
static int sd_socket_dead(const char *path)
{
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    if (!path || strlen(path) >= sizeof sa.sun_path) return 0;
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    int dead = connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0 && errno == ECONNREFUSED;
    close(fd);
    return dead;
}

/* Apps launched from the shell run as mobile, the way ioscd's LAUNCH path
 * (launch_client) runs them: the shell clients themselves run as root, and the
 * desktop pins they launch from are written by the mobile Xios app. */
struct sd_mobile {
    uid_t uid;
    gid_t gid;
    char  name[64];
    char  home[256];
};

static void sd_mobile_account(struct sd_mobile *m)
{
    struct passwd *pw = getpwnam("mobile");
    m->uid = pw ? pw->pw_uid : 501;
    m->gid = pw ? pw->pw_gid : 501;
    snprintf(m->name, sizeof m->name, "%s",
             (pw && pw->pw_name) ? pw->pw_name : "mobile");
    snprintf(m->home, sizeof m->home, "%s",
             (pw && pw->pw_dir && pw->pw_dir[0]) ? pw->pw_dir : "/var/mobile");
}

/* ioscd's drop_to_mobile, in the same order. */
static int sd_drop_to_mobile(const struct sd_mobile *m)
{
    if (initgroups(m->name, (int)m->gid) != 0) return -1;
    if (setgid(m->gid) != 0) return -1;
    if (setuid(m->uid) != 0) return -1;
    return 0;
}

/* ------------------------------------------ files in mobile's own dirs ---
 * The clients run as root, but the shell's settings live in mobile's
 * Preferences and the user's files in mobile's Documents, where any mobile
 * process can plant a symlink, a hard link or a FIFO. So a file there is used
 * only if it is a regular file with one link, owned by mobile or root, and
 * never through a symlink (refused and logged); a whole file is replaced by
 * an O_EXCL temp renamed into place; and whatever the shell creates there is
 * handed to mobile, so the Xios app and mobile apps can still edit it. */

static void sd_user_give(int fd)
{
    struct sd_mobile m;
    if (geteuid() != 0) return;
    sd_mobile_account(&m);
    (void)fchown(fd, m.uid, m.gid);
}

static int sd_user_file_ok(int fd, const char *path)
{
    struct sd_mobile m;
    struct stat st;
    sd_mobile_account(&m);
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_nlink == 1 &&
        (st.st_uid == 0 || st.st_uid == m.uid))
        return 1;
    fprintf(stderr, "iosc-shell: leaving %s alone: not a singly linked file of mobile or root\n",
            path);
    return 0;
}

static FILE *sd_user_fopen_read(const char *path)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ELOOP)
            fprintf(stderr, "iosc-shell: not reading %s: it is a symlink\n", path);
        return NULL;
    }
    if (!sd_user_file_ok(fd, path)) { close(fd); return NULL; }
    FILE *f = fdopen(fd, "r");
    if (!f) close(fd);
    return f;
}

#ifdef SD_USER_REPLACE
/* Starts a whole-file replace of <path>: an O_EXCL temp beside it, mobile's.
 * Refused (and logged) when <path> exists as anything but a regular file. */
static FILE *sd_user_replace_begin(const char *path, char *tmp, size_t tmpn)
{
    struct stat st;
    if (lstat(path, &st) == 0 && !S_ISREG(st.st_mode)) {
        fprintf(stderr, "iosc-shell: not writing %s: it is %s\n", path,
                S_ISLNK(st.st_mode) ? "a symlink" : "not a regular file");
        return NULL;
    }
    if ((size_t)snprintf(tmp, tmpn, "%s.XXXXXX", path) >= tmpn) return NULL;
    int fd = mkstemp(tmp);              /* O_CREAT|O_EXCL: never through a link */
    if (fd < 0) return NULL;
    (void)fchmod(fd, 0644);
    sd_user_give(fd);
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); unlink(tmp); }
    return f;
}

/* Finishes it: renamed into place if everything was written (ok), else the
 * temp is dropped. */
static int sd_user_replace_end(FILE *f, const char *tmp, const char *path, int ok)
{
    ok = fflush(f) == 0 && ok;
    ok = fclose(f) == 0 && ok;
    if (ok && rename(tmp, path) == 0) return 1;
    unlink(tmp);
    fprintf(stderr, "iosc-shell: could not write %s\n", path);
    return 0;
}
#endif /* SD_USER_REPLACE */

/* A live listener from a dbus-daemon running as <uid>. dbus-daemon admits
 * only its own uid by default, so a bus an older shell started as root still
 * answers connect() but refuses every mobile app: replace it, don't reuse it. */
static int sd_bus_socket_usable(const char *sock, uid_t uid)
{
    struct stat st;
    return lstat(sock, &st) == 0 && S_ISSOCK(st.st_mode) && st.st_uid == uid &&
           !sd_socket_dead(sock);
}

static int sd_shared_session_bus(const char *root, const char *busdir,
                                 const struct sd_mobile *m,
                                 char *addr, size_t addr_n)
{
    char sock[256], daemon[256], address_arg[320];
    if (!busdir || !*busdir || !addr || addr_n == 0) return 0;
    snprintf(sock, sizeof sock, "%s/session-bus", busdir);
    snprintf(addr, addr_n, "unix:path=%s", sock);

    /* mobile-owned 0700 with a mobile daemon, like ioscd's ensure_session_bus.
     * The dir sits in the world-writable <jbroot>/tmp, so it is taken over
     * through an fd that refuses a planted symlink, and only from root or
     * mobile. */
    mkdir(busdir, 0700);
    int dfd = open(busdir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (dfd < 0) return 0;
    struct stat st;
    int owned = fstat(dfd, &st) == 0 && S_ISDIR(st.st_mode) &&
                (st.st_uid == 0 || st.st_uid == m->uid) &&
                fchown(dfd, m->uid, m->gid) == 0 && fchmod(dfd, 0700) == 0;
    close(dfd);
    if (!owned) return 0;
    if (sd_bus_socket_usable(sock, m->uid)) return 1;

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
        if (geteuid() == 0 && sd_drop_to_mobile(m) != 0) _exit(126);
        execl(daemon, "dbus-daemon", "--session", "--fork",
              address_arg, "--print-address", (char*)NULL);
        _exit(127);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    return sd_bus_socket_usable(sock, m->uid);
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
    /* a frame was dropped because the compositor still held every slot; the
     * client re-renders from its main loop until one comes back */
    int starved;
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
        pool->starved = 1;
        return NULL;
    }
    pool->starved = 0;

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

/* Frees every slot, attached or not. Call it after destroying the wl_surface
 * the pool drew into (or at exit): iosc never sends wl_buffer.release for a
 * destroyed surface's last buffer, so a busy slot left to wait for one would
 * stay busy forever and the next surface reusing the pool would run dry. */
static void sd_cairo_pool_destroy(struct sd_cairo_pool *pool)
{
    if (!pool) return;
    for (size_t i = 0; i < sizeof(pool->slots)/sizeof(pool->slots[0]); i++)
        sd_cairo_slot_destroy(&pool->slots[i]);
    pool->starved = 0;
}

#endif /* SD_CAIRO */

/* ------------------------------------------------------- .desktop scan ---- */

#if defined(SD_APP_SCAN) || defined(SD_DESKTOP_PINNING)
/* exec is the whole Exec line (heap, kept for the life of the process): a
 * fixed buffer cut long ones and the cut command is what got launched */
struct sd_app { char name[64]; char *exec; char icon[128]; };
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
        char *line = NULL, name[64] = {0}, *exec = NULL, icon[128] = {0};
        size_t cap = 0;
        int nodisplay = 0, in_entry = 0;
        while (getline(&line, &cap, f) > 0) {
            if (line[0] == '[') { in_entry = !strncmp(line, "[Desktop Entry]", 15); continue; }
            if (!in_entry) continue;
            if (!strncmp(line, "Name=", 5) && !name[0]) sscanf(line + 5, "%63[^\n]", name);
            else if (!strncmp(line, "Exec=", 5) && !exec) exec = strndup(line + 5, strcspn(line + 5, "\r\n"));
            else if (!strncmp(line, "Icon=", 5) && !icon[0]) sscanf(line + 5, "%127[^\n]", icon);
            else if (!strncmp(line, "NoDisplay=true", 14)) nodisplay = 1;
        }
        free(line);
        fclose(f);
        if (exec) sd_strip_field_codes(exec);
        if (nodisplay || !exec || !exec[0]) { free(exec); continue; }
        if (!name[0]) snprintf(name, sizeof name, "%.*s", (int)(len-8), e->d_name);
        snprintf(apps[n].name, 64, "%s", name);
        apps[n].exec = exec;
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
/* Appends to the pins file (the Xios app appends to it too), creating it
 * mobile's if missing and handing an older root-made one back to mobile;
 * same rules as the other files in mobile's dirs. */
static FILE *sd_user_fopen_append(const char *path)
{
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                  0644);
    if (fd < 0) {
        if (errno == ELOOP)
            fprintf(stderr, "iosc-shell: not writing %s: it is a symlink\n", path);
        return NULL;
    }
    if (!sd_user_file_ok(fd, path)) { close(fd); return NULL; }
    sd_user_give(fd);
    FILE *f = fdopen(fd, "a");
    if (!f) close(fd);
    return f;
}

static int sd_desktop_pin_exists(const char *exec)
{
    if (!exec || !*exec) return 1;
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    FILE *f = sd_user_fopen_read(path);
    if (!f) return 0;
    char *line = NULL;
    size_t cap = 0;
    int found = 0;
    while (getline(&line, &cap, f) > 0) {
        /* positional tab fields; Icon may be empty, so no strtok (it would
         * merge the empty field and shift Exec into the icon slot) */
        line[strcspn(line, "\r\n")] = 0;
        char *rest = line;
        char *type = strsep(&rest, "\t");
        char *name = strsep(&rest, "\t");
        char *icon = strsep(&rest, "\t");
        char *target = strsep(&rest, "\t");
        (void)type; (void)name; (void)icon;
        if (target && !strcmp(target, exec)) { found = 1; break; }
    }
    free(line);
    fclose(f);
    return found;
}

static void sd_pin_app_to_desktop(const struct sd_app *app)
{
    if (!app || !app->exec || !app->exec[0] || sd_desktop_pin_exists(app->exec)) return;
    char path[256]; sd_desktop_pins_path(path, sizeof path);
    FILE *f = sd_user_fopen_append(path);
    if (!f) return;
    int slot = 0;
    {
        FILE *r = sd_user_fopen_read(path);
        char *line = NULL;
        size_t cap = 0;
        while (r && getline(&line, &cap, r) > 0) slot++;
        free(line);
        if (r) fclose(r);
    }
    int x = 300 + (slot % 6) * 104;
    int y = 96 + (slot / 6) * 122;
    fprintf(f, "app\t%s\t%s\t%s\t%d\t%d\n", app->name, app->icon, app->exec, x, y);
    fclose(f);
}
#endif /* SD_DESKTOP_PINNING */

/* The compositor socket this client is connected to, as an absolute path, the
 * way libwayland resolved it: WAYLAND_DISPLAY if absolute, else under
 * XDG_RUNTIME_DIR. A launched app gets the bus dir as XDG_RUNTIME_DIR, so the
 * bare name run-shell.sh exports ("wayland-0") would point inside that. */
static void sd_wayland_socket_path(char *dst, size_t n, const char *root)
{
    const char *name = getenv("WAYLAND_DISPLAY");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!name || !*name) name = "wayland-0";
    if (name[0] == '/') snprintf(dst, n, "%s", name);
    else if (runtime && runtime[0] == '/') snprintf(dst, n, "%s/%s", runtime, name);
    else {
        char tmp[256];
        sd_join_path(tmp, sizeof tmp, root, "/tmp");
        snprintf(dst, n, "%s/%s", tmp, name);
    }
}

/* ioscd hands the compositor socket to mobile before it launches anything
 * (fix_ddx_perms): libwayland binds it under the compositor's umask, so a root
 * compositor's socket is not writable, i.e. not connectable, for mobile. Same
 * here, for this one socket only: a root socket under this one name (not a
 * hard link planted to another), and without following a symlink. */
static void sd_mobile_socket(const char *path, const struct sd_mobile *m)
{
    struct stat st;
    if (lstat(path, &st) != 0 || !S_ISSOCK(st.st_mode) || st.st_uid != 0 ||
        st.st_nlink != 1)
        return;
    if (lchown(path, m->uid, m->gid) == 0)
        (void)fchmodat(AT_FDCWD, path, 0660, AT_SYMLINK_NOFOLLOW);
}

/* None of the launching client's own fds (its compositor connection, shm
 * pools, keymap) may reach the app. */
static void sd_close_fds_from(int lowfd)
{
    int max = getdtablesize();
    if (max <= 0 || max > 65536) max = 65536;
    for (int fd = lowfd; fd < max; fd++) close(fd);
}

/* The environment ioscd's set_wayland_client_env gives every app it launches
 * on the classic desktop, so a dock launch and a Home Screen launch see the
 * same thing. Keep the two in step. */
static void sd_client_env(const char *root, const char *tmp, const char *wayland,
                          const char *runtime, int have_bus, const char *bus_addr,
                          const struct sd_mobile *m, int enable_a11y)
{
    char prefix[256], angle[256], angle_egl[300], config_dirs[300], shell[256];
    char data_dirs[600], config_home[300], cache_home[300], schemas[300];
    char compose[320], dyld[600], pulse[300], pulse_runtime[300];
    char qt_plugins[300], qt_qml[300], path[600];
    sd_join_path(prefix, sizeof prefix, root, "/usr");
    sd_join_path(angle, sizeof angle, root, "/lib/angle");
    sd_join_path(angle_egl, sizeof angle_egl, root, "/lib/angle/libEGL.angle.dylib");
    sd_join_path(config_dirs, sizeof config_dirs, root, "/etc/xdg");
    sd_join_path(shell, sizeof shell, root, "/bin/sh");
    snprintf(data_dirs, sizeof data_dirs, "%s/share:%s/local/share", prefix, prefix);
    snprintf(config_home, sizeof config_home, "%s/.config", m->home);
    snprintf(cache_home, sizeof cache_home, "%s/.cache", m->home);
    snprintf(schemas, sizeof schemas, "%s/share/glib-2.0/schemas", prefix);
    snprintf(compose, sizeof compose, "%s/share/X11/locale/en_US.UTF-8/Compose", prefix);
    snprintf(dyld, sizeof dyld, "%s/lib:%s", prefix, angle);
    snprintf(pulse, sizeof pulse, "unix:%s/pulse/native", tmp);
    snprintf(pulse_runtime, sizeof pulse_runtime, "%s/pulse-daemon", tmp);
    snprintf(qt_plugins, sizeof qt_plugins, "%s/lib/qt6/plugins", prefix);
    snprintf(qt_qml, sizeof qt_qml, "%s/lib/qt6/qml", prefix);
    if (!root || !*root || !strcmp(root, "/"))
        snprintf(path, sizeof path, "/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin");
    else
        snprintf(path, sizeof path,
                 "%s/usr/local/bin:%s/usr/bin:%s/usr/sbin:%s/bin:%s/sbin:/usr/bin:/bin",
                 root, root, root, root, root);

    setenv("XDG_RUNTIME_DIR", runtime, 1);
    setenv("XDG_DATA_DIRS", data_dirs, 1);
    setenv("XDG_CONFIG_DIRS", config_dirs, 1);
    setenv("XDG_CONFIG_HOME", config_home, 1);
    setenv("XDG_CACHE_HOME", cache_home, 1);
    setenv("GSETTINGS_SCHEMA_DIR", schemas, 1);
    setenv("WAYLAND_DISPLAY", wayland, 1);
    setenv("XIOS_CAPABILITY_PROFILE", "iosc-client-gpu", 1);
    setenv("GDK_BACKEND", "wayland", 1);
    setenv("GSK_RENDERER", "ngl", 1);
    setenv("QT_QPA_PLATFORM", "wayland", 1);
    setenv("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1", 1);
    setenv("QT_PLUGIN_PATH", qt_plugins, 1);
    setenv("QML2_IMPORT_PATH", qt_qml, 1);
    setenv("QML_IMPORT_PATH", qt_qml, 1);
    setenv("ANGLE_REAL_LIBEGL", angle_egl, 1);
    setenv("DYLD_LIBRARY_PATH", dyld, 1);
    setenv("GSETTINGS_BACKEND", "memory", 1);
    setenv("PULSE_SERVER", pulse, 1);
    setenv("PULSE_RUNTIME_PATH", pulse_runtime, 1);
    if (have_bus) {
        setenv("DBUS_SESSION_BUS_ADDRESS", bus_addr, 1);
        setenv("DBUS_SYSTEM_BUS_ADDRESS", bus_addr, 1);
    }
    if (enable_a11y) {
        unsetenv("GTK_A11Y");
        unsetenv("NO_AT_BRIDGE");
    } else {
        setenv("GTK_A11Y", "none", 1);
        setenv("NO_AT_BRIDGE", "1", 1);
    }
    setenv("HOME", m->home, 1);
    setenv("USER", m->name, 1);
    setenv("LOGNAME", m->name, 1);
    setenv("SHELL", shell, 1);
    setenv("TERM", "xterm-256color", 1);
    setenv("LANG", "C", 1);
    setenv("LC_CTYPE", "UTF-8", 1);
    setenv("FC_LANG", "en", 1);
    setenv("XCOMPOSEFILE", compose, 1);
    setenv("XDG_SESSION_TYPE", "wayland", 1);
    setenv("XDG_CURRENT_DESKTOP", "Xios", 1);
    setenv("TMPDIR", tmp, 1);
    setenv("PATH", path, 1);
}

/* fork+exec a .desktop Exec (or a desktop pin's command) as mobile, the way
 * ioscd's launch_client starts a Home Screen app: mobile-owned session bus,
 * ioscd's client environment, stdin from /dev/null, no inherited fds, then
 * initgroups/setgid/setuid before exec. The text still goes through
 * `sh -lc`: Exec lines and pins are command lines, and they now run with
 * mobile's rights, the same account that can write the pins file. */
static void sd_launch(const char *exec)
{
    pid_t pid = fork();
    if (pid != 0) return;
    /* the clients ignore SIGCHLD; the bus start below waits for its child,
     * and the app starts with the default disposition, as from ioscd */
    signal(SIGCHLD, SIG_DFL);
    setsid();
    const char *root = sd_jbroot();
    struct sd_mobile m;
    sd_mobile_account(&m);
    int as_root = geteuid() == 0;
    char tmp[256], wayland[512], busdir[256], bus_addr[320], runtime[512];
    char dbus_run[256], sh_bin[256], usr_sh[256];
    char a11y_enabled[256], a11y_force[256], atspi_log[300], a11yd_log[300];
    sd_join_path(tmp, sizeof tmp, root, "/tmp");
    sd_join_path(a11y_enabled, sizeof a11y_enabled, root, "/tmp/xios-a11y-enabled");
    sd_join_path(a11y_force, sizeof a11y_force, root, "/tmp/xios-a11y-force");
    sd_wayland_socket_path(wayland, sizeof wayland, root);
    sd_join_path(busdir, sizeof busdir, root, "/tmp/iosc-shell-bus");
    sd_join_path(dbus_run, sizeof dbus_run, root, "/usr/bin/dbus-run-session");
    sd_join_path(sh_bin, sizeof sh_bin, root, "/bin/sh");
    sd_join_path(usr_sh, sizeof usr_sh, root, "/usr/bin/sh");
    const char *env_runtime = getenv("XDG_RUNTIME_DIR");
    snprintf(runtime, sizeof runtime, "%s",
             (env_runtime && *env_runtime) ? env_runtime : tmp);

    if (as_root) sd_mobile_socket(wayland, &m);
    int have_bus = sd_shared_session_bus(root, busdir, &m, bus_addr, sizeof bus_addr);
    if (have_bus) snprintf(runtime, sizeof runtime, "%s", busdir);
    /* same gate as ioscd and xios-session: the VoiceOver state file ioscd
     * maintains, the smoke-test force file, or XIOS_ENABLE_A11Y */
    int enable_a11y = sd_env_truthy("XIOS_ENABLE_A11Y") ||
                      access(a11y_enabled, F_OK) == 0 ||
                      access(a11y_force, F_OK) == 0;

    int null = open("/dev/null", O_RDONLY);
    if (null >= 0) {
        dup2(null, 0);
        if (null > 0) close(null);
    }
    sd_close_fds_from(3);
    sd_client_env(root, tmp, wayland, runtime, have_bus, bus_addr, &m, enable_a11y);
    if (enable_a11y && have_bus) {
        /* the bridge starts below as mobile, to join the mobile bus (a root
         * one would be refused), so its logs go to that bus's mobile-owned
         * dir: root may already own the defaults in <jbroot>/tmp */
        snprintf(atspi_log, sizeof atspi_log, "%s/xios-atspi.log", busdir);
        snprintf(a11yd_log, sizeof a11yd_log, "%s/xios-a11yd.log", busdir);
        setenv("XIOS_ATSPI_LOG", atspi_log, 1);
        setenv("XIOS_A11YD_LOG", a11yd_log, 1);
    }
    if (as_root && sd_drop_to_mobile(&m) != 0) {
        fprintf(stderr, "iosc-shell: cannot switch to %s (%s); not launching: %.200s\n",
                m.name, strerror(errno), exec);
        _exit(126);
    }

    const char *cmd = exec;
    char *a11y_cmd = NULL;
    /* `sh -l` reads profile.d/xios.sh, which sets NO_AT_BRIDGE=1 when unset */
    if (enable_a11y &&
        asprintf(&a11y_cmd, "unset NO_AT_BRIDGE; "
                            "if command -v xios-start-a11y >/dev/null 2>&1; then "
                            "xios-start-a11y; fi; exec %s", exec) > 0)
        cmd = a11y_cmd;
    if (!have_bus)
        execl(dbus_run, "dbus-run-session", "--", sh_bin, "-lc", cmd, (char*)NULL);
    execl(sh_bin, "sh", "-lc", cmd, (char*)NULL);
    execl(usr_sh, "sh", "-lc", cmd, (char*)NULL);
    _exit(127);
}

#endif /* SHELL_DRAW_H */
