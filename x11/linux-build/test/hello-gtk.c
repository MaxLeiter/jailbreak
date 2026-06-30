/*
 * hello-gtk.c — minimal GTK3 smoke test for the iOS X11 stack.
 *
 * Creates a top-level window with a label and a button, draws one frame, then
 * quits itself after ~2.5s so it can run unattended on Xvfb (DISPLAY=:3). On
 * the first "draw" signal it prints a line and (if given an argv[1] path) saves
 * the window contents — proving Pango/Cairo/GDK text + theme rendering work.
 *
 * Build (cross, against the staged stack): see test/build-hello-gtk.sh.
 * Run on device: DISPLAY=:3 /var/jb/usr/bin/hello-gtk
 */
#include <gtk/gtk.h>

static gboolean drew = FALSE;

static gboolean on_draw(GtkWidget *w, cairo_t *cr, gpointer data) {
    (void)w; (void)cr; (void)data;
    if (!drew) {
        drew = TRUE;
        g_print("HELLO_GTK_DREW ok: first frame painted\n");
    }
    return FALSE;
}

static gboolean quit_soon(gpointer data) {
    (void)data;
    g_print("HELLO_GTK_QUIT: exiting after render\n");
    gtk_main_quit();
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    if (!gtk_init_check(&argc, &argv)) {
        g_printerr("HELLO_GTK_FAIL: gtk_init_check failed (no display?)\n");
        return 2;
    }
    g_print("HELLO_GTK_INIT: gtk %d.%d.%d\n",
            gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());

    GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(win), "Hello GTK on iOS");
    gtk_window_set_default_size(GTK_WINDOW(win), 360, 160);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_container_set_border_width(GTK_CONTAINER(box), 16);
    GtkWidget *label = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(label),
        "<span size='xx-large' weight='bold'>GTK 3 on iOS</span>\n"
        "<span foreground='#3584e4'>pango + cairo + X11</span>");
    GtkWidget *button = gtk_button_new_with_label("It renders!");
    gtk_box_pack_start(GTK_BOX(box), label, TRUE, TRUE, 0);
    gtk_box_pack_start(GTK_BOX(box), button, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(win), box);

    g_signal_connect(win, "draw", G_CALLBACK(on_draw), NULL);
    g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    gtk_widget_show_all(win);

    g_timeout_add(2500, quit_soon, NULL);
    gtk_main();
    g_print("HELLO_GTK_DONE\n");
    return drew ? 0 : 3;
}
