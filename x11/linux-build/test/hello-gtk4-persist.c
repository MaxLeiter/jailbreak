/*
 * hello-gtk4-persist.c — persistent GTK4 showcase window for the on-device :5 session.
 *
 * Same as hello-gtk4.c but it does NOT auto-quit: it runs the GTK main loop until the
 * window is closed. Plain GtkWindow + gtk_window_present (NO GtkApplication, so it needs
 * no D-Bus). Title + a centered Pango-markup label, with margins, so it's presentable.
 *
 * Run on device:
 *   DYLD_LIBRARY_PATH=/var/jb/usr/lib GSK_RENDERER=cairo GDK_BACKEND=x11 DISPLAY=:5 \
 *     /var/jb/tmp/gtktest/hello-gtk4-persist
 */
#include <gtk/gtk.h>

static GMainLoop *loop;

static gboolean on_close(GtkWindow *win, gpointer data) {
    (void)win; (void)data;
    g_print("HELLO_GTK4_PERSIST: window closed, exiting\n");
    g_main_loop_quit(loop);
    return FALSE;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (!gtk_init_check()) {
        g_printerr("HELLO_GTK4_PERSIST_FAIL: gtk_init_check failed (no display?)\n");
        return 2;
    }
    g_print("HELLO_GTK4_PERSIST_INIT: gtk %d.%d.%d\n",
            gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());

    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "GTK 4.14.5 — native on iOS");
    gtk_window_set_default_size(GTK_WINDOW(win), 560, 320);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_margin_top(box, 40);
    gtk_widget_set_margin_bottom(box, 40);
    gtk_widget_set_margin_start(box, 40);
    gtk_widget_set_margin_end(box, 40);

    GtkWidget *title = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(title),
        "<span size='xx-large' weight='bold'>GTK 4 running on a jailbroken A10</span>");
    gtk_label_set_justify(GTK_LABEL(title), GTK_JUSTIFY_CENTER);

    GtkWidget *sub = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(sub),
        "<span size='large' foreground='#3584e4'>GTK 4.14.5 · X11 · pango · cairo — built from source for /var/jb</span>");
    gtk_label_set_justify(GTK_LABEL(sub), GTK_JUSTIFY_CENTER);

    gtk_box_append(GTK_BOX(box), title);
    gtk_box_append(GTK_BOX(box), sub);
    gtk_window_set_child(GTK_WINDOW(win), box);

    g_signal_connect(win, "close-request", G_CALLBACK(on_close), NULL);
    gtk_window_present(GTK_WINDOW(win));

    g_print("HELLO_GTK4_PERSIST: window presented, entering main loop\n");
    loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);
    return 0;
}
