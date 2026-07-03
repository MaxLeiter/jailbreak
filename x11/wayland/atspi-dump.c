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

static void print_actions(AtspiAccessible *obj)
{
    AtspiAction *action = atspi_accessible_get_action(obj);
    if (!action) return;

    GError *error = NULL;
    int n = atspi_action_get_n_actions(action, &error);
    if (error) {
        clear_error(&error);
        n = 0;
    }
    if (n > 0) {
        fputs(" actions=[", stdout);
        for (int i = 0; i < n; i++) {
            char *name = atspi_action_get_localized_name(action, i, &error);
            clear_error(&error);
            if (!name || !*name) {
                g_free(name);
                name = atspi_action_get_action_name(action, i, &error);
                clear_error(&error);
            }
            if (i > 0) fputs(", ", stdout);
            printf("\"%s\"", name && *name ? name : "?");
            g_free(name);
        }
        fputc(']', stdout);
    }

    g_object_unref(action);
}

struct state_name {
    AtspiStateType state;
    const char *name;
};

static void print_states(AtspiAccessible *obj)
{
    static const struct state_name names[] = {
        { ATSPI_STATE_ACTIVE, "active" },
        { ATSPI_STATE_BUSY, "busy" },
        { ATSPI_STATE_CHECKABLE, "checkable" },
        { ATSPI_STATE_CHECKED, "checked" },
        { ATSPI_STATE_EDITABLE, "editable" },
        { ATSPI_STATE_ENABLED, "enabled" },
        { ATSPI_STATE_EXPANDED, "expanded" },
        { ATSPI_STATE_FOCUSABLE, "focusable" },
        { ATSPI_STATE_FOCUSED, "focused" },
        { ATSPI_STATE_INDETERMINATE, "indeterminate" },
        { ATSPI_STATE_INVALID_ENTRY, "invalid" },
        { ATSPI_STATE_MODAL, "modal" },
        { ATSPI_STATE_PRESSED, "pressed" },
        { ATSPI_STATE_REQUIRED, "required" },
        { ATSPI_STATE_SELECTED, "selected" },
        { ATSPI_STATE_SENSITIVE, "sensitive" },
        { ATSPI_STATE_SHOWING, "showing" },
        { ATSPI_STATE_VISIBLE, "visible" },
    };

    AtspiStateSet *states = atspi_accessible_get_state_set(obj);
    if (!states) return;

    int first = 1;
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (!atspi_state_set_contains(states, names[i].state)) continue;
        if (first) {
            fputs(" states=[", stdout);
            first = 0;
        } else {
            fputs(", ", stdout);
        }
        fputs(names[i].name, stdout);
    }
    if (!first) fputc(']', stdout);
    g_object_unref(states);
}

static void print_value(AtspiAccessible *obj)
{
    AtspiValue *value = atspi_accessible_get_value(obj);
    if (!value) return;

    GError *error = NULL;
    char *text = atspi_value_get_text(value, &error);
    clear_error(&error);
    double current = atspi_value_get_current_value(value, &error);
    clear_error(&error);
    double min = atspi_value_get_minimum_value(value, &error);
    clear_error(&error);
    double max = atspi_value_get_maximum_value(value, &error);
    clear_error(&error);
    double inc = atspi_value_get_minimum_increment(value, &error);
    clear_error(&error);

    if ((text && *text) || current != 0.0 || min != 0.0 || max != 0.0 || inc != 0.0) {
        fputs(" value={", stdout);
        if (text && *text) printf("text=\"%s\" ", text);
        printf("current=%.6g min=%.6g max=%.6g inc=%.6g}", current, min, max, inc);
    }

    g_free(text);
    g_object_unref(value);
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
    print_states(obj);
    print_actions(obj);
    print_value(obj);
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
