#ifndef IOSC_OPTIONS_H
#define IOSC_OPTIONS_H

struct iosc_options {
    const char *sock_name;
    const char *ddx_sock;
    const char *json_path;
    const char *input_sock;
    const char *clipboard_sock;
    const char *wm_sock;
    int width;
    int height;
    int dpi;
    int scale;
    int logical_w;
    int logical_h;
    int native_arg;
};

void iosc_options_init(struct iosc_options *o);
void iosc_parse_args(int argc, char **argv, struct iosc_options *o);

#endif
