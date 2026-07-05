#include "iosc_options.h"
#include "iosc_util.h"

#include <stdlib.h>
#include <string.h>

void iosc_options_init(struct iosc_options *o)
{
    *o = (struct iosc_options){
        .sock_name = "wayland-0",
        .ddx_sock = "/var/jb/tmp/iosc-ddx.sock",
        .json_path = "/var/jb/tmp/xios.json",
        .input_sock = "/var/jb/tmp/iosc-input.sock",
        .clipboard_sock = "/var/jb/tmp/iosc-clipboard.sock",
        .wm_sock = "/var/jb/tmp/iosc-wm.sock",
        .width = 2880,
        .height = 2160,
        .dpi = 96,
        .scale = 2,
        .native_arg = -1,
    };
}

void iosc_parse_args(int argc, char **argv, struct iosc_options *o)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-g") && i + 1 < argc) {
            iosc_parse_size(argv[++i], &o->width, &o->height);
        } else if (!strcmp(argv[i], "-logical") && i + 1 < argc) {
            /* Express the desktop by its LOGICAL size; the output IOSurface is
             * derived as logical * scale after parsing so -scale may appear in
             * any order. */
            iosc_parse_size(argv[++i], &o->logical_w, &o->logical_h);
        } else if (!strcmp(argv[i], "-dpi") && i + 1 < argc) {
            int dpi = atoi(argv[++i]);
            if (dpi > 0) o->dpi = dpi;
        } else if (!strcmp(argv[i], "-scale") && i + 1 < argc) {
            int scale = atoi(argv[++i]);
            if (scale > 0) o->scale = scale;
        } else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            o->sock_name = argv[++i];
        } else if (!strcmp(argv[i], "-ddx-sock") && i + 1 < argc) {
            o->ddx_sock = argv[++i];
        } else if (!strcmp(argv[i], "-json") && i + 1 < argc) {
            o->json_path = argv[++i];
        } else if (!strcmp(argv[i], "-input-sock") && i + 1 < argc) {
            o->input_sock = argv[++i];
        } else if (!strcmp(argv[i], "-clipboard-sock") && i + 1 < argc) {
            o->clipboard_sock = argv[++i];
        } else if (!strcmp(argv[i], "-wm-sock") && i + 1 < argc) {
            o->wm_sock = argv[++i];
        } else if (!strcmp(argv[i], "-native")) {
            o->native_arg = 1;
        } else if (!strcmp(argv[i], "-classic")) {
            o->native_arg = 0;
        }
    }
}
