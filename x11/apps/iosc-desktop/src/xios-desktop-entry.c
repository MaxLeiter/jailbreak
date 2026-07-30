#include "xios-desktop-entry.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

static void set_error(char *dst, size_t dst_len, const char *fmt, ...)
{
    if (!dst || dst_len == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(dst, dst_len, fmt, ap);
    va_end(ap);
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

static const char *path_base(const char *path)
{
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static int denied_desktop(const char *base)
{
    return strcmp(base, "org.freedesktop.Xwayland.desktop") == 0 ||
           strcmp(base, "org.gnome.Shell.desktop") == 0 ||
           strcmp(base, "org.gnome.Shell.Extensions.desktop") == 0;
}

static FILE *open_desktop(const char *path, const char *root, int require_trusted,
                          char *error, size_t error_len)
{
    char resolved[PATH_MAX], resolved_root[PATH_MAX];
    struct stat root_st, path_st;

    if (!require_trusted) {
        FILE *f = fopen(path, "r");
        if (!f) set_error(error, error_len, "open failed: %s", strerror(errno));
        return f;
    }

    if (!root || !*root || !realpath(root, resolved_root)) {
        set_error(error, error_len, "trusted application root unavailable");
        return NULL;
    }
    if (stat(resolved_root, &root_st) != 0 || !S_ISDIR(root_st.st_mode) ||
        root_st.st_uid != 0 || (root_st.st_mode & 022) != 0) {
        set_error(error, error_len, "application root is not trusted");
        return NULL;
    }
    if (!realpath(path, resolved)) {
        set_error(error, error_len, "cannot resolve desktop entry: %s", strerror(errno));
        return NULL;
    }
    size_t root_len = strlen(resolved_root);
    if (strncmp(resolved, resolved_root, root_len) != 0 ||
        (resolved[root_len] != '/' && resolved[root_len] != 0)) {
        set_error(error, error_len, "desktop entry escapes trusted application root");
        return NULL;
    }

    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        set_error(error, error_len, "cannot securely open desktop entry: %s",
                  strerror(errno));
        return NULL;
    }
    if (fstat(fd, &path_st) != 0 || !S_ISREG(path_st.st_mode)) {
        close(fd);
        set_error(error, error_len, "desktop entry is not a regular file");
        return NULL;
    }
    if (path_st.st_uid != 0) {
        close(fd);
        set_error(error, error_len, "desktop entry is not root-owned");
        return NULL;
    }
    if ((path_st.st_mode & 022) != 0) {
        close(fd);
        set_error(error, error_len, "desktop entry is group/other-writable");
        return NULL;
    }
    FILE *f = fdopen(fd, "r");
    if (!f) {
        close(fd);
        set_error(error, error_len, "fdopen failed: %s", strerror(errno));
    }
    return f;
}

int xios_desktop_app_id_valid(const char *app_id)
{
    if (!app_id || !*app_id || strlen(app_id) >= 256) return 0;
    for (const unsigned char *p = (const unsigned char *)app_id; *p; p++) {
        if (*p < 0x21 || *p == 0x7f || *p == '/' || *p == '\\' || *p == '\t')
            return 0;
    }
    return 1;
}

int xios_desktop_entry_parse(const char *path, const char *trusted_root,
                             int require_trusted,
                             struct xios_desktop_entry *entry,
                             char *error, size_t error_len)
{
    if (!path || !entry) {
        set_error(error, error_len, "invalid parser arguments");
        return 0;
    }
    FILE *f = open_desktop(path, trusted_root, require_trusted, error, error_len);
    if (!f) return 0;

    memset(entry, 0, sizeof(*entry));
    snprintf(entry->desktop_path, sizeof(entry->desktop_path), "%s", path);
    snprintf(entry->desktop_base, sizeof(entry->desktop_base), "%s", path_base(path));
    if (denied_desktop(entry->desktop_base)) {
        fclose(f);
        set_error(error, error_len, "desktop entry is denied");
        return 0;
    }

    char type[64] = "";
    char nodisplay[16] = "";
    char hidden[16] = "";
    char terminal[16] = "";
    char startup[256] = "";
    int in_entry = 0, saw_entry = 0;
    char line[4096];

    while (fgets(line, sizeof(line), f)) {
        trim(line);
        if (!line[0] || line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = strcmp(line, "[Desktop Entry]") == 0;
            if (!in_entry && saw_entry) break;
            if (in_entry) saw_entry = 1;
            continue;
        }
        if (!in_entry) continue;

        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *key = line;
        char *val = eq + 1;
        if (strcmp(key, "Type") == 0)
            snprintf(type, sizeof(type), "%s", val);
        else if (strcmp(key, "NoDisplay") == 0)
            snprintf(nodisplay, sizeof(nodisplay), "%s", val);
        else if (strcmp(key, "Hidden") == 0)
            snprintf(hidden, sizeof(hidden), "%s", val);
        else if (strcmp(key, "Terminal") == 0)
            snprintf(terminal, sizeof(terminal), "%s", val);
        else if (strcmp(key, "Name") == 0 && !entry->name[0])
            snprintf(entry->name, sizeof(entry->name), "%s", val);
        else if (strcmp(key, "Exec") == 0 && !entry->exec[0])
            snprintf(entry->exec, sizeof(entry->exec), "%s", val);
        else if (strcmp(key, "Icon") == 0 && !entry->icon[0])
            snprintf(entry->icon, sizeof(entry->icon), "%s", val);
        else if (strcmp(key, "StartupWMClass") == 0 && !startup[0])
            snprintf(startup, sizeof(startup), "%s", val);
    }
    fclose(f);

    if (strcmp(type, "Application") != 0 ||
        strcasecmp(nodisplay, "true") == 0 ||
        strcasecmp(hidden, "true") == 0 ||
        strcasecmp(terminal, "true") == 0 ||
        !entry->exec[0]) {
        set_error(error, error_len, "desktop entry is not launchable");
        return 0;
    }
    if (!entry->name[0])
        snprintf(entry->name, sizeof(entry->name), "%s", entry->desktop_base);
    if (startup[0]) {
        snprintf(entry->app_id, sizeof(entry->app_id), "%s", startup);
    } else {
        snprintf(entry->app_id, sizeof(entry->app_id), "%s", entry->desktop_base);
        size_t n = strlen(entry->app_id);
        if (n > 8 && strcmp(entry->app_id + n - 8, ".desktop") == 0)
            entry->app_id[n - 8] = 0;
    }
    if (!xios_desktop_app_id_valid(entry->app_id)) {
        set_error(error, error_len, "desktop entry has invalid app id");
        return 0;
    }
    if (error && error_len) error[0] = 0;
    return 1;
}

static void application_root(char *dst, size_t dst_len, const char *jbroot,
                             const char *suffix)
{
    if (jbroot && *jbroot && strcmp(jbroot, "/") != 0)
        snprintf(dst, dst_len, "%s%s", jbroot, suffix);
    else
        snprintf(dst, dst_len, "%s", suffix);
}

static int direct_match(const char *app_id, const char *root, int require_trusted,
                        struct xios_desktop_entry *entry,
                        char *error, size_t error_len)
{
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s.desktop", root, app_id) >= (int)sizeof(path))
        return 0;
    struct xios_desktop_entry candidate;
    char ignored[256];
    if (!xios_desktop_entry_parse(path, root, require_trusted, &candidate,
                                  ignored, sizeof(ignored)))
        return 0;
    if (strcmp(candidate.app_id, app_id) != 0) return 0;
    *entry = candidate;
    if (error && error_len) error[0] = 0;
    return 1;
}

int xios_desktop_entry_resolve(const char *app_id, const char *jbroot,
                               int require_trusted,
                               struct xios_desktop_entry *entry,
                               char *error, size_t error_len)
{
    if (!xios_desktop_app_id_valid(app_id)) {
        set_error(error, error_len, "invalid app id");
        return 0;
    }

    char roots[2][PATH_MAX];
    application_root(roots[0], sizeof(roots[0]), jbroot,
                     "/usr/local/share/applications");
    application_root(roots[1], sizeof(roots[1]), jbroot,
                     "/usr/share/applications");

    for (size_t i = 0; i < 2; i++)
        if (direct_match(app_id, roots[i], require_trusted, entry, error, error_len))
            return 1;

    int found = 0;
    struct xios_desktop_entry match;
    for (size_t i = 0; i < 2; i++) {
        DIR *dir = opendir(roots[i]);
        if (!dir) continue;
        struct dirent *de;
        while ((de = readdir(dir))) {
            size_t n = strlen(de->d_name);
            if (n <= 8 || strcmp(de->d_name + n - 8, ".desktop") != 0) continue;
            char path[PATH_MAX];
            if (snprintf(path, sizeof(path), "%s/%s", roots[i], de->d_name) >=
                (int)sizeof(path))
                continue;
            struct xios_desktop_entry candidate;
            char ignored[256];
            if (!xios_desktop_entry_parse(path, roots[i], require_trusted,
                                          &candidate, ignored, sizeof(ignored)))
                continue;
            if (strcmp(candidate.app_id, app_id) != 0) continue;
            if (found) {
                closedir(dir);
                set_error(error, error_len, "app id is ambiguous");
                return 0;
            }
            match = candidate;
            found = 1;
        }
        closedir(dir);
    }
    if (!found) {
        set_error(error, error_len, "no trusted desktop entry for app id");
        return 0;
    }
    *entry = match;
    if (error && error_len) error[0] = 0;
    return 1;
}

static int append_char(char *dst, size_t dst_len, size_t *used, char c)
{
    if (*used + 1 >= dst_len) return 0;
    dst[(*used)++] = c;
    dst[*used] = 0;
    return 1;
}

static int append_text(char *dst, size_t dst_len, size_t *used, const char *text)
{
    size_t n = strlen(text);
    if (*used + n >= dst_len) return 0;
    memcpy(dst + *used, text, n);
    *used += n;
    dst[*used] = 0;
    return 1;
}

int xios_desktop_entry_argv(const struct xios_desktop_entry *entry,
                            char **argv, size_t argv_len,
                            char *storage, size_t storage_len,
                            char *error, size_t error_len)
{
    if (!entry || !argv || argv_len < 2 || !storage || storage_len < 2) {
        set_error(error, error_len, "invalid argv arguments");
        return 0;
    }

    char lexical[XIOS_DESKTOP_ARG_STORAGE];
    char *tokens[XIOS_DESKTOP_ARG_MAX];
    size_t lex_used = 0, token_count = 0;
    const char *p = entry->exec;

    while (*p) {
        while (isspace((unsigned char)*p)) p++;
        if (!*p) break;
        if (token_count + 1 >= XIOS_DESKTOP_ARG_MAX) {
            set_error(error, error_len, "too many Exec arguments");
            return 0;
        }
        tokens[token_count++] = lexical + lex_used;
        int quote = 0, saw = 0;
        while (*p && (quote || !isspace((unsigned char)*p))) {
            char c = *p++;
            if (!quote && (c == '\'' || c == '"')) {
                quote = c;
                saw = 1;
                continue;
            }
            if (quote && c == quote) {
                quote = 0;
                saw = 1;
                continue;
            }
            if (c == '\\' && *p) c = *p++;
            if (!append_char(lexical, sizeof(lexical), &lex_used, c)) {
                set_error(error, error_len, "Exec value is too long");
                return 0;
            }
            saw = 1;
        }
        if (quote) {
            set_error(error, error_len, "unterminated quote in Exec");
            return 0;
        }
        if (!saw || !append_char(lexical, sizeof(lexical), &lex_used, 0)) {
            set_error(error, error_len, "invalid Exec token");
            return 0;
        }
    }

    size_t argc = 0, used = 0;
    for (size_t i = 0; i < token_count; i++) {
        const char *token = tokens[i];
        if (strcmp(token, "%i") == 0) {
            if (!entry->icon[0]) continue;
            if (argc + 2 >= argv_len) {
                set_error(error, error_len, "too many expanded arguments");
                return 0;
            }
            argv[argc++] = storage + used;
            if (!append_text(storage, storage_len, &used, "--icon") ||
                !append_char(storage, storage_len, &used, 0)) goto too_long;
            argv[argc++] = storage + used;
            if (!append_text(storage, storage_len, &used, entry->icon) ||
                !append_char(storage, storage_len, &used, 0)) goto too_long;
            continue;
        }

        if (argc + 1 >= argv_len) {
            set_error(error, error_len, "too many expanded arguments");
            return 0;
        }
        char *start = storage + used;
        int had_literal = 0;
        for (size_t j = 0; token[j]; j++) {
            if (token[j] != '%') {
                if (!append_char(storage, storage_len, &used, token[j])) goto too_long;
                had_literal = 1;
                continue;
            }
            char code = token[++j];
            if (!code) {
                set_error(error, error_len, "trailing field code marker in Exec");
                return 0;
            }
            if (code == '%') {
                if (!append_char(storage, storage_len, &used, '%')) goto too_long;
                had_literal = 1;
            } else if (strchr("fFuUdDnNvm", code)) {
                continue;
            } else if (code == 'c') {
                if (!append_text(storage, storage_len, &used, entry->name)) goto too_long;
                had_literal = 1;
            } else if (code == 'k') {
                if (!append_text(storage, storage_len, &used, entry->desktop_path)) goto too_long;
                had_literal = 1;
            } else if (code == 'i') {
                set_error(error, error_len, "%%i must be a standalone Exec argument");
                return 0;
            } else {
                set_error(error, error_len, "unsupported Exec field code %%%c", code);
                return 0;
            }
        }
        if (!had_literal && used == (size_t)(start - storage)) continue;
        if (!append_char(storage, storage_len, &used, 0)) goto too_long;
        argv[argc++] = start;
    }
    if (argc == 0 || !argv[0][0]) {
        set_error(error, error_len, "Exec expands to an empty command");
        return 0;
    }
    argv[argc] = NULL;
    if (error && error_len) error[0] = 0;
    return (int)argc;

too_long:
    set_error(error, error_len, "expanded Exec value is too long");
    return 0;
}
