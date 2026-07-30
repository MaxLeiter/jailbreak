#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

static void
on_load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer user_data)
{
    (void)user_data;
    if (event == WEBKIT_LOAD_FINISHED) {
        const char *title = webkit_web_view_get_title(view);
        g_print("load-finished title=%s\n", title ? title : "(null)");
        fflush(stdout);
    }
}

int
main(int argc, char **argv)
{
    gtk_init(&argc, &argv);

    GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    GtkWidget *view = webkit_web_view_new();
    gtk_window_set_default_size(GTK_WINDOW(window), 900, 600);
    gtk_container_add(GTK_CONTAINER(window), view);
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    g_signal_connect(view, "load-changed", G_CALLBACK(on_load_changed), NULL);

    webkit_web_view_load_html(
        WEBKIT_WEB_VIEW(view),
        "<!doctype html><meta charset=utf-8>"
        "<title>loading</title><h1>WebKitGTK iOS smoke</h1>"
        "<script>document.title = 'jsc-ok-' + (6 * 7)</script>",
        "https://xios.invalid/"
    );
    gtk_widget_show_all(window);
    gtk_main();
    return 0;
}
