/*
 * hello-gtk4.c — minimal GTK4 smoke test for the iOS X11 stack.
 *
 * GTK4 has no gtk_main(); we drive a GMainLoop. A GtkDrawingArea draw_func proves a
 * real GSK/cairo paint happened (prints HELLO_GTK4_DREW), then we self-quit after
 * ~2.5s so it can run unattended on Xvfb (DISPLAY=:3). The GSK renderer will try GL
 * (epoxy→mesa GLX) and fall back to cairo if GL is unavailable; either way it renders.
 *
 * Build: test/build-hello-gtk4.sh. Run: DISPLAY=:3 hello-gtk4
 */
#include <gtk/gtk.h>

static GMainLoop *loop;
static gboolean drew = FALSE;

static void draw_cb(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    (void)area; (void)data;
    if (!drew) {
        drew = TRUE;
        g_print("HELLO_GTK4_DREW ok: first frame painted (%dx%d)\n", w, h);
    }
    cairo_set_source_rgb(cr, 0.21, 0.52, 0.89);
    cairo_paint(cr);
}

static gboolean quit_cb(gpointer data) {
    (void)data;
    g_print("HELLO_GTK4_QUIT: exiting after render\n");
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (!gtk_init_check()) {
        g_printerr("HELLO_GTK4_FAIL: gtk_init_check failed (no display?)\n");
        return 2;
    }
    g_print("HELLO_GTK4_INIT: gtk %d.%d.%d\n",
            gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());

    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), "Hello GTK4 on iOS");
    gtk_window_set_default_size(GTK_WINDOW(win), 360, 160);

    GtkWidget *da = gtk_drawing_area_new();
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(da), draw_cb, NULL, NULL);
    gtk_window_set_child(GTK_WINDOW(win), da);

    gtk_window_present(GTK_WINDOW(win));

    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(2500, quit_cb, NULL);
    g_main_loop_run(loop);
    g_print("HELLO_GTK4_DONE\n");
    return drew ? 0 : 3;
}
