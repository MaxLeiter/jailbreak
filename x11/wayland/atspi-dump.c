/*
 * atspi-dump.c — tiny AT-SPI smoke test for the Xios VoiceOver bridge work.
 *
 * It intentionally avoids bridge-specific code: if this can see GTK/Qt app
 * trees on the private a11y bus, the Linux/toolkit half is alive and ready for
 * xios-a11yd to mirror.
 */
#include <atspi/atspi.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>

static int max_depth = 8;
static int max_children = 200;

static void clear_error(GError **error)
{
    if (error && *error) {
        fprintf(stderr, "atspi-dump: %s\n", (*error)->message);
        g_clear_error(error);
    }
}

static void print_indent(int depth)
{
    for (int i = 0; i < depth; i++) fputs("  ", stdout);
}

static void dump_accessible(AtspiAccessible *obj, int depth)
{
    if (!obj || depth > max_depth) return;

    GError *error = NULL;
    char *name = atspi_accessible_get_name(obj, &error);
    clear_error(&error);
    char *role = atspi_accessible_get_role_name(obj, &error);
    clear_error(&error);
    char *desc = atspi_accessible_get_description(obj, &error);
    clear_error(&error);

    print_indent(depth);
    printf("- role=%s", role && *role ? role : "?");
    if (name && *name) printf(" name=\"%s\"", name);
    if (desc && *desc) printf(" desc=\"%s\"", desc);
    putchar('\n');

    g_free(name);
    g_free(role);
    g_free(desc);

    int n = atspi_accessible_get_child_count(obj, &error);
    if (error) {
        clear_error(&error);
        return;
    }
    if (n > max_children) n = max_children;

    for (int i = 0; i < n; i++) {
        AtspiAccessible *child = atspi_accessible_get_child_at_index(obj, i, &error);
        if (error) {
            clear_error(&error);
            continue;
        }
        dump_accessible(child, depth + 1);
        if (child) g_object_unref(child);
    }
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (g_str_has_prefix(argv[i], "--depth=")) {
            max_depth = atoi(argv[i] + 8);
        } else if (g_str_has_prefix(argv[i], "--children=")) {
            max_children = atoi(argv[i] + 11);
        } else {
            fprintf(stderr, "usage: atspi-dump [--depth=N] [--children=N]\n");
            return 2;
        }
    }

    if (max_depth < 0) max_depth = 0;
    if (max_children < 1) max_children = 1;

    int rc = atspi_init();
    if (rc != 0) {
        fprintf(stderr, "atspi-dump: atspi_init failed: %d\n", rc);
        return 1;
    }

    int desktops = atspi_get_desktop_count();
    printf("desktops=%d\n", desktops);
    for (int i = 0; i < desktops; i++) {
        AtspiAccessible *desktop = atspi_get_desktop(i);
        printf("desktop[%d]\n", i);
        dump_accessible(desktop, 1);
        if (desktop) g_object_unref(desktop);
    }

    atspi_exit();
    return 0;
}
