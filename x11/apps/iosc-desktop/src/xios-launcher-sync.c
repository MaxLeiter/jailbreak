/*
 * xios-launcher-sync.c — on-device .desktop -> iPad Home Screen app sync.
 *
 * This materializes one iOS .app bundle per freedesktop application entry so
 * SpringBoard can show separate icons. It is intentionally small and boring:
 * parse .desktop files, copy a shared launcher payload, render icons with
 * xios-icon-render, write Info.plist, sign, and uicache.
 *
 * First usable modes:
 *   xios-launcher-sync --list
 *   xios-launcher-sync --sync --native [--dry-run]
 *
 * Payload defaults:
 *   /var/jb/usr/libexec/xios-launchers/IOSCHost
 *   /var/jb/usr/libexec/xios-launchers/default.metallib
 *   /var/jb/usr/libexec/xios-launchers/host-entitlements.plist
 */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "xios-desktop-entry.h"

extern char **environ;

#define JBROOT        "/var/jb"
#define APPS_DIR      JBROOT "/Applications"
#define PAYLOAD_DIR   JBROOT "/usr/libexec/xios-launchers"
#define RENDER_BIN    JBROOT "/usr/local/bin/xios-icon-render"
#define RENDER_BIN2   JBROOT "/usr/bin/xios-icon-render"
#define LDID_BIN      JBROOT "/usr/bin/ldid"
#define UICACHE_BIN   JBROOT "/usr/bin/uicache"
#define PREFS_PATH    "/var/mobile/Library/Preferences/com.max.xios-launchers.conf"

struct app {
    char desktop_path[PATH_MAX];
    char desktop_base[256];
    char name[256];
    char exec[1024];
    char icon[512];
    char app_id[256];
    char bundle_id[320];
    char bundle_name[256];
    char bundle_path[PATH_MAX];
};

static int opt_native = 1;
static int opt_dry_run = 0;
static int opt_do_uicache = 1;
static const char *opt_payload = PAYLOAD_DIR;
static const char *opt_apps_dir = APPS_DIR;
static const char *opt_only_app_id = NULL;
static const char *opt_renderer = NULL;
static const char *opt_enable_app_id = NULL;
static const char *opt_disable_app_id = NULL;

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static int path_exists(const char *p)
{
    struct stat st;
    return p && *p && stat(p, &st) == 0;
}

static int mkdir_p(const char *path, mode_t mode)
{
    char tmp[PATH_MAX];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p != '/') continue;
        *p = 0;
        if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST) return -1;
    return 0;
}

static void trim(char *s)
{
    if (!s) return;
    char *p = s;
    while (isspace((unsigned char)*p)) p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1])) s[--n] = 0;
}

static void sanitize_id(const char *in, char *out, size_t outsz)
{
    size_t j = 0;
    int last_dash = 0;
    for (size_t i = 0; in[i] && j + 1 < outsz; i++) {
        unsigned char c = (unsigned char)in[i];
        if (isalnum(c) || c == '.') {
            out[j++] = (char)tolower(c);
            last_dash = 0;
        } else if (!last_dash && j > 0) {
            out[j++] = '-';
            last_dash = 1;
        }
    }
    while (j > 0 && out[j - 1] == '-') j--;
    out[j] = 0;
    if (out[0] == 0) snprintf(out, outsz, "app");
}

static void xml_escape(FILE *f, const char *s)
{
    for (; s && *s; s++) {
        switch (*s) {
        case '&': fputs("&amp;", f); break;
        case '<': fputs("&lt;", f); break;
        case '>': fputs("&gt;", f); break;
        case '"': fputs("&quot;", f); break;
        case '\'': fputs("&apos;", f); break;
        default: fputc((unsigned char)*s, f); break;
        }
    }
}

static int app_disabled(const char *app_id)
{
    FILE *f = fopen(PREFS_PATH, "r");
    if (!f) return 0;
    char line[1024];
    int disabled = 0;
    while (fgets(line, sizeof(line), f)) {
        trim(line);
        if (!line[0] || line[0] == '#') continue;
        char *tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = 0;
        char *state = tab + 1;
        if (strcmp(line, app_id) != 0) continue;
        disabled = strcmp(state, "0") == 0 ||
                   strcasecmp(state, "disabled") == 0 ||
                   strcasecmp(state, "off") == 0;
    }
    fclose(f);
    return disabled;
}

static int append_pref(const char *app_id, int enabled)
{
    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s", PREFS_PATH);
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = 0;
        if (mkdir_p(dir, 0755) != 0) return -1;
    }
    FILE *f = fopen(PREFS_PATH, "a");
    if (!f) return -1;
    fprintf(f, "%s\t%s\n", app_id, enabled ? "enabled" : "disabled");
    fclose(f);
    chmod(PREFS_PATH, 0644);
    return 0;
}

static int parse_desktop(const char *path, struct app *a)
{
    struct xios_desktop_entry entry;
    char error[256];
    if (!xios_desktop_entry_parse(path, NULL, 0, &entry, error, sizeof(error)))
        return 0;

    memset(a, 0, sizeof(*a));
    snprintf(a->desktop_path, sizeof(a->desktop_path), "%s", entry.desktop_path);
    snprintf(a->desktop_base, sizeof(a->desktop_base), "%s", entry.desktop_base);
    snprintf(a->name, sizeof(a->name), "%s", entry.name);
    snprintf(a->exec, sizeof(a->exec), "%s", entry.exec);
    snprintf(a->icon, sizeof(a->icon), "%s", entry.icon);
    snprintf(a->app_id, sizeof(a->app_id), "%s", entry.app_id);
    char san[256];
    sanitize_id(a->app_id, san, sizeof(san));
    snprintf(a->bundle_id, sizeof(a->bundle_id), "com.max.iosc.%s", san);
    snprintf(a->bundle_name, sizeof(a->bundle_name), "%s.app", san);
    snprintf(a->bundle_path, sizeof(a->bundle_path), "%s/%s", opt_apps_dir, a->bundle_name);
    return 1;
}

static int copy_file(const char *src, const char *dst, mode_t mode)
{
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (out < 0) { close(in); return -1; }
    char buf[65536];
    for (;;) {
        ssize_t n = read(in, buf, sizeof(buf));
        if (n == 0) break;
        if (n < 0) { close(in); close(out); return -1; }
        char *p = buf;
        while (n > 0) {
            ssize_t w = write(out, p, (size_t)n);
            if (w <= 0) { close(in); close(out); return -1; }
            p += w; n -= w;
        }
    }
    close(in);
    if (fchmod(out, mode) != 0) { close(out); return -1; }
    close(out);
    return 0;
}

static int remove_tree(const char *path)
{
    struct stat st;
    if (lstat(path, &st) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    if (!S_ISDIR(st.st_mode)) {
        return unlink(path);
    }

    DIR *dir = opendir(path);
    if (!dir) return -1;
    struct dirent *de;
    int rc = 0;
    while ((de = readdir(dir))) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;
        char child[PATH_MAX];
        snprintf(child, sizeof(child), "%s/%s", path, de->d_name);
        if (remove_tree(child) != 0)
            rc = -1;
    }
    closedir(dir);
    if (rmdir(path) != 0)
        rc = -1;
    return rc;
}

static int runv(char *const argv[])
{
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    if (rc != 0) return -1;
    int st = 0;
    if (waitpid(pid, &st, 0) < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void write_info_plist(const struct app *a, const char *path)
{
    FILE *f = fopen(path, "w");
    if (!f) die("write %s: %s", path, strerror(errno));
    fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
          "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
          "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
          "<plist version=\"1.0\">\n<dict>\n", f);
    fprintf(f, "  <key>CFBundleExecutable</key><string>%s</string>\n",
            opt_native ? "IOSCHost" : "IOSCLaunch");
    fputs("  <key>CFBundleIdentifier</key><string>", f); xml_escape(f, a->bundle_id); fputs("</string>\n", f);
    fputs("  <key>CFBundleName</key><string>", f); xml_escape(f, a->name); fputs("</string>\n", f);
    fputs("  <key>CFBundleDisplayName</key><string>", f); xml_escape(f, a->name); fputs("</string>\n", f);
    fputs("  <key>CFBundlePackageType</key><string>APPL</string>\n"
          "  <key>CFBundleShortVersionString</key><string>1.0</string>\n"
          "  <key>CFBundleVersion</key><string>1</string>\n"
          "  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n"
          "  <key>LSRequiresIPhoneOS</key><true/>\n"
          "  <key>MinimumOSVersion</key><string>16.0</string>\n"
          "  <key>UIDeviceFamily</key><array><integer>2</integer></array>\n"
          "  <key>UILaunchScreen</key><dict/>\n"
          "  <key>UIStatusBarHidden</key><true/>\n", f);
    if (opt_native) {
        fputs("  <key>UIApplicationSupportsIndirectInputEvents</key><true/>\n"
              "  <key>UIApplicationSceneManifest</key>\n"
              "  <dict><key>UIApplicationSupportsMultipleScenes</key><true/>\n"
              "    <key>UISceneConfigurations</key><dict>\n"
              "      <key>UIWindowSceneSessionRoleApplication</key><array><dict>\n"
              "        <key>UISceneConfigurationName</key><string>Default</string>\n"
              "        <key>UISceneDelegateClassName</key><string>IOSCHost.HostSceneDelegate</string>\n"
              "      </dict></array>\n"
              "    </dict></dict>\n"
              "  <key>UISupportedInterfaceOrientations~ipad</key>\n"
              "  <array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string>"
              "<string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>\n", f);
    } else {
        fputs("  <key>UIRequiresFullScreen</key><true/>\n"
              "  <key>UISupportedInterfaceOrientations~ipad</key>\n"
              "  <array><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>\n", f);
    }
    fputs("  <key>IOSCAppID</key><string>", f); xml_escape(f, a->app_id); fputs("</string>\n", f);
    fputs("  <key>IOSCName</key><string>", f); xml_escape(f, a->name); fputs("</string>\n", f);
    fputs("  <key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>"
          "<array><string>AppIcon60x60</string><string>AppIcon76x76</string></array></dict></dict>\n"
          "  <key>CFBundleIcons~ipad</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>"
          "<array><string>AppIcon60x60</string><string>AppIcon76x76</string><string>AppIcon83.5x83.5</string></array></dict></dict>\n"
          "</dict>\n</plist>\n", f);
    fclose(f);
    chmod(path, 0644);
}

static int resolve_icon(const char *name, char *out, size_t outsz)
{
    if (!name || !*name) return 0;
    if (name[0] == '/' && path_exists(name)) {
        snprintf(out, outsz, "%s", name);
        return 1;
    }
    char base[512];
    snprintf(base, sizeof(base), "%s", name);
    char *dot = strrchr(base, '.');
    if (dot && (!strcasecmp(dot, ".png") || !strcasecmp(dot, ".svg") || !strcasecmp(dot, ".xpm")))
        *dot = 0;

    const char *themes[] = { "hicolor", "Adwaita", "gnome", "default", "breeze", "breeze-dark" };
    const char *sizes[] = { "scalable", "512x512", "256x256", "192x192", "128x128", "96x96", "64x64", "48x48", "32x32", "16x16", "symbolic", "512", "256", "128", "64", "48", "32", "16" };
    const char *exts[] = { "svg", "png", "xpm" };
    const char *roots[] = { JBROOT "/usr/share/icons", JBROOT "/usr/local/share/icons" };
    for (size_t r = 0; r < sizeof(roots)/sizeof(roots[0]); r++) {
        for (size_t t = 0; t < sizeof(themes)/sizeof(themes[0]); t++) {
            for (size_t s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++) {
                for (size_t e = 0; e < sizeof(exts)/sizeof(exts[0]); e++) {
                    snprintf(out, outsz, "%s/%s/%s/apps/%s.%s", roots[r], themes[t], sizes[s], base, exts[e]);
                    if (path_exists(out)) return 1;
                }
            }
        }
    }
    const char *pixroots[] = { JBROOT "/usr/share/pixmaps", JBROOT "/usr/local/share/pixmaps" };
    for (size_t r = 0; r < sizeof(pixroots)/sizeof(pixroots[0]); r++) {
        for (size_t e = 0; e < sizeof(exts)/sizeof(exts[0]); e++) {
            snprintf(out, outsz, "%s/%s.%s", pixroots[r], base, exts[e]);
            if (path_exists(out)) return 1;
        }
    }
    return 0;
}

static const char *renderer_path(void)
{
    if (opt_renderer && *opt_renderer) return opt_renderer;
    if (path_exists(RENDER_BIN)) return RENDER_BIN;
    if (path_exists(RENDER_BIN2)) return RENDER_BIN2;
    return "xios-icon-render";
}

static int sync_one(const struct app *a)
{
    char host[PATH_MAX], metal[PATH_MAX], ent[PATH_MAX];
    snprintf(host, sizeof(host), "%s/%s", opt_payload, opt_native ? "IOSCHost" : "IOSCLaunch");
    snprintf(metal, sizeof(metal), "%s/default.metallib", opt_payload);
    snprintf(ent, sizeof(ent), "%s/%s", opt_payload, opt_native ? "host-entitlements.plist" : "launcher-entitlements.plist");
    if (!path_exists(host)) die("missing payload: %s", host);
    if (opt_native && !path_exists(metal)) die("missing payload: %s", metal);

    printf("%s\t%s\t%s\n", opt_dry_run ? "would-sync" : "sync", a->app_id, a->bundle_path);
    if (opt_dry_run) return 0;

    if (remove_tree(a->bundle_path) != 0) return -1;
    if (mkdir_p(a->bundle_path, 0755) != 0) return -1;

    char dst[PATH_MAX];
    snprintf(dst, sizeof(dst), "%s/%s", a->bundle_path, opt_native ? "IOSCHost" : "IOSCLaunch");
    if (copy_file(host, dst, 0755) != 0) die("copy %s -> %s failed", host, dst);
    if (opt_native) {
        char mdst[PATH_MAX];
        snprintf(mdst, sizeof(mdst), "%s/default.metallib", a->bundle_path);
        if (copy_file(metal, mdst, 0644) != 0) die("copy %s -> %s failed", metal, mdst);
    }
    char plist[PATH_MAX];
    snprintf(plist, sizeof(plist), "%s/Info.plist", a->bundle_path);
    write_info_plist(a, plist);

    char icon_path[PATH_MAX];
    if (resolve_icon(a->icon, icon_path, sizeof(icon_path))) {
        char *argv[] = { (char *)renderer_path(), icon_path, (char *)a->bundle_path, NULL };
        if (runv(argv) != 0)
            fprintf(stderr, "xios-launcher-sync: icon render failed for %s (%s)\n", a->app_id, icon_path);
    } else {
        fprintf(stderr, "xios-launcher-sync: no icon for %s (%s)\n", a->app_id, a->icon);
    }

    if (path_exists(ent) && path_exists(LDID_BIN)) {
        char signarg[PATH_MAX + 3];
        snprintf(signarg, sizeof(signarg), "-S%s", ent);
        char *argv[] = { LDID_BIN, signarg, dst, NULL };
        if (runv(argv) != 0)
            fprintf(stderr, "xios-launcher-sync: ldid failed for %s\n", dst);
    }
    return 0;
}

static void scan_apps(void (*fn)(const struct app *))
{
    const char *dirs[] = { JBROOT "/usr/share/applications", JBROOT "/usr/local/share/applications" };
    for (size_t d = 0; d < sizeof(dirs)/sizeof(dirs[0]); d++) {
        DIR *dir = opendir(dirs[d]);
        if (!dir) continue;
        struct dirent *de;
        while ((de = readdir(dir))) {
            size_t n = strlen(de->d_name);
            if (n <= 8 || strcmp(de->d_name + n - 8, ".desktop") != 0) continue;
            char path[PATH_MAX];
            snprintf(path, sizeof(path), "%s/%s", dirs[d], de->d_name);
            struct app a;
            if (parse_desktop(path, &a)) fn(&a);
        }
        closedir(dir);
    }
}

static void list_cb(const struct app *a)
{
    printf("%s\t%s\t%s\t%s\t%s\t%s\n", a->app_id, a->name, a->exec,
           a->icon, a->bundle_path, app_disabled(a->app_id) ? "disabled" : "enabled");
}

static void sync_cb(const struct app *a)
{
    if (opt_only_app_id && strcmp(opt_only_app_id, a->app_id) != 0)
        return;
    if (app_disabled(a->app_id)) {
        printf("skip-disabled\t%s\t%s\n", a->app_id, a->bundle_path);
        return;
    }
    (void)sync_one(a);
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s --list\n"
            "       %s --sync [--native|--classic] [--payload DIR] [--apps-dir DIR]\n"
            "          [--renderer PATH] [--only APP_ID] [--dry-run] [--no-uicache]\n",
            argv0, argv0);
    fprintf(stderr, "       %s --enable APP_ID | --disable APP_ID\n", argv0);
}

int main(int argc, char **argv)
{
    int do_list = 0, do_sync = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--list") == 0) do_list = 1;
        else if (strcmp(argv[i], "--sync") == 0) do_sync = 1;
        else if (strcmp(argv[i], "--enable") == 0 && i + 1 < argc) opt_enable_app_id = argv[++i];
        else if (strcmp(argv[i], "--disable") == 0 && i + 1 < argc) opt_disable_app_id = argv[++i];
        else if (strcmp(argv[i], "--native") == 0) opt_native = 1;
        else if (strcmp(argv[i], "--classic") == 0) opt_native = 0;
        else if (strcmp(argv[i], "--dry-run") == 0) opt_dry_run = 1;
        else if (strcmp(argv[i], "--no-uicache") == 0) opt_do_uicache = 0;
        else if (strcmp(argv[i], "--payload") == 0 && i + 1 < argc) opt_payload = argv[++i];
        else if (strcmp(argv[i], "--apps-dir") == 0 && i + 1 < argc) opt_apps_dir = argv[++i];
        else if (strcmp(argv[i], "--renderer") == 0 && i + 1 < argc) opt_renderer = argv[++i];
        else if (strcmp(argv[i], "--only") == 0 && i + 1 < argc) opt_only_app_id = argv[++i];
        else { usage(argv[0]); return 2; }
    }
    if (opt_enable_app_id || opt_disable_app_id) {
        if (do_list || do_sync || (opt_enable_app_id && opt_disable_app_id)) {
            usage(argv[0]);
            return 2;
        }
        const char *id = opt_enable_app_id ? opt_enable_app_id : opt_disable_app_id;
        if (append_pref(id, opt_enable_app_id != NULL) != 0) {
            fprintf(stderr, "xios-launcher-sync: update %s failed: %s\n", PREFS_PATH, strerror(errno));
            return 1;
        }
        printf("%s\t%s\n", opt_enable_app_id ? "enabled" : "disabled", id);
        return 0;
    }
    if (do_list == do_sync) { usage(argv[0]); return 2; }
    if (do_list) scan_apps(list_cb);
    if (do_sync) {
        scan_apps(sync_cb);
        if (!opt_dry_run && opt_do_uicache && path_exists(UICACHE_BIN)) {
            char *argv2[] = { UICACHE_BIN, "-a", NULL };
            (void)runv(argv2);
        }
    }
    return 0;
}
