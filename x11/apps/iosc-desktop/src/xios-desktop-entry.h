#ifndef XIOS_DESKTOP_ENTRY_H
#define XIOS_DESKTOP_ENTRY_H

#include <limits.h>
#include <stddef.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define XIOS_DESKTOP_ARG_MAX 128
#define XIOS_DESKTOP_ARG_STORAGE 8192

struct xios_desktop_entry {
    char desktop_path[PATH_MAX];
    char desktop_base[256];
    char name[256];
    char exec[2048];
    char icon[512];
    char app_id[256];
};

/*
 * Parse one visible, non-terminal Application entry. When require_trusted is
 * true, the resolved file must remain beneath trusted_root, be root-owned, and
 * not be writable by group or other.
 */
int xios_desktop_entry_parse(const char *path, const char *trusted_root,
                             int require_trusted,
                             struct xios_desktop_entry *entry,
                             char *error, size_t error_len);

/*
 * Resolve an app id from the installed XDG application directories beneath
 * jbroot. A direct <app_id>.desktop match wins; StartupWMClass fallbacks must be
 * unique. No path or command supplied by the socket client is used.
 */
int xios_desktop_entry_resolve(const char *app_id, const char *jbroot,
                               int require_trusted,
                               struct xios_desktop_entry *entry,
                               char *error, size_t error_len);

/*
 * Convert the Desktop Entry Exec value to argv without invoking a shell.
 * Supported field codes follow the Desktop Entry specification; file/URL
 * placeholders are omitted because a Home Screen tap supplies no files.
 */
int xios_desktop_entry_argv(const struct xios_desktop_entry *entry,
                            char **argv, size_t argv_len,
                            char *storage, size_t storage_len,
                            char *error, size_t error_len);

int xios_desktop_app_id_valid(const char *app_id);

#endif
