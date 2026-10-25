// ipadctl-probe - phase 0 feasibility probe for ipadctld.
//
// Standalone root CLI: capture the screen and inject touch / keyboard /
// button events with no SpringBoard tweak. Every command prints one JSON
// object on stdout; diagnostics go to stderr.
#import <Foundation/Foundation.h>

#import "capture.h"
#import "display.h"
#import "hid.h"
#import "spi.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(void) {
    fprintf(stderr,
            "usage: ipadctl-probe <command> [args]\n"
            "  info\n"
            "  shot <out.jpg> [--bench N] [--quality Q] [--no-accel]\n"
            "  tap X Y\n"
            "  swipe X1 Y1 X2 Y2 [MS=300]\n"
            "  longpress X Y [MS=1000]\n"
            "  type TEXT\n"
            "  key NAME            (return, escape, tab, backspace, left/right/up/down, cmd+a, ...)\n"
            "  button home|volup|voldown\n"
            "Coordinates are points in the current orientation, matching `shot` output.\n");
}

static NSString *json(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

static void emit(id obj) {
    printf("%s\n", json(obj).UTF8String);
    fflush(stdout);
}

static int fail(NSString *msg) {
    emit(@{@"ok" : @NO, @"error" : msg});
    return 1;
}

static NSDictionary *geometry_dict(const ipc_geometry *g) {
    return @{
        @"panel_px" : @[ @(g->panel_px_w), @(g->panel_px_h) ],
        @"scale" : @(g->scale),
        @"view_pt" : @[ @(g->view_pt_w), @(g->view_pt_h) ],
        @"view_px" : @[ @(lround(g->view_pt_w * g->scale)), @(lround(g->view_pt_h * g->scale)) ],
        @"orientation" : @(ipc_orientation_name(g->orientation)),
        @"orientation_raw" : @(g->orientation),
        @"rot_q" : @(g->rot_q),
    };
}

static int cmd_info(void) {
    ipc_geometry g;
    bool orient_ok = ipc_geometry_get(&g);
    ipc_foreground f;
    ipc_foreground_get(&f);
    NSMutableDictionary *d = [geometry_dict(&g) mutableCopy];
    d[@"ok"] = @YES;
    d[@"orientation_ok"] = orient_ok ? @YES : @NO;
    d[@"frontmost"] = f.frontmost_ok ? @(f.frontmost) : [NSNull null];
    d[@"locked"] = f.lockstate < 0 ? (id)[NSNull null] : (f.lockstate != 0 ? @YES : @NO);
    d[@"screen_on"] = f.blanked < 0 ? (id)[NSNull null] : (f.blanked == 0 ? @YES : @NO);
    emit(d);
    return 0;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static double median(double *v, int n) {
    qsort(v, (size_t)n, sizeof(double), cmp_double);
    return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

static int cmd_shot(int argc, char **argv) {
    if (argc < 1) { usage(); return 2; }
    const char *out = argv[0];
    int bench = 1;
    double quality = 0.7;
    bool accel = true;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bench") && i + 1 < argc) bench = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quality") && i + 1 < argc) quality = atof(argv[++i]);
        else if (!strcmp(argv[i], "--no-accel")) accel = false;
        else { usage(); return 2; }
    }
    if (bench < 1) bench = 1;

    ipc_geometry g;
    ipc_geometry_get(&g);
    ipc_capturer *c = ipc_capturer_create(&g, accel);
    if (!c) return fail(@"could not allocate capture surfaces");

    double *render = calloc((size_t)bench, sizeof(double)), *scale = calloc((size_t)bench, sizeof(double));
    double *rotate = calloc((size_t)bench, sizeof(double)), *encode = calloc((size_t)bench, sizeof(double));
    double *total = calloc((size_t)bench, sizeof(double));
    ipc_shot_stats st = {0};
    NSData *jpeg = nil;
    for (int i = 0; i < bench; i++) {
        @autoreleasepool {
            NSString *err = nil;
            jpeg = ipc_capture_jpeg(c, quality, &st, &err);
            if (!jpeg) {
                ipc_capturer_destroy(c);
                return fail(err ?: @"capture failed");
            }
            render[i] = st.render_ms; scale[i] = st.scale_ms; rotate[i] = st.rotate_ms;
            encode[i] = st.encode_ms; total[i] = st.total_ms;
        }
    }
    ipc_capturer_destroy(c);

    if (![jpeg writeToFile:@(out) atomically:YES]) return fail([NSString stringWithFormat:@"write %s failed", out]);

    NSMutableDictionary *d = [geometry_dict(&g) mutableCopy];
    [d addEntriesFromDictionary:@{
        @"ok" : @YES,
        @"path" : @(out),
        @"size" : @[ @(st.out_w), @(st.out_h) ],
        @"bytes" : @(st.bytes),
        @"blank" : st.blank ? @YES : @NO,
        @"accelerator" : st.used_accel ? @YES : @NO,
        @"runs" : @(bench),
        @"ms" : @{
            @"capture" : @(median(render, bench)),
            @"scale" : @(median(scale, bench)),
            @"rotate" : @(median(rotate, bench)),
            @"encode" : @(median(encode, bench)),
            @"scale_encode" : @(median(scale, bench) + median(rotate, bench) + median(encode, bench)),
            @"total" : @(median(total, bench)),
            @"total_max" : @(total[bench - 1]),  // sorted by median()
        },
    }];
    emit(d);
    free(render); free(scale); free(rotate); free(encode); free(total);
    return 0;
}

static bool parse_num(const char *s, double *out) {
    char *end;
    *out = strtod(s, &end);
    return end != s && *end == '\0';
}

static NSDictionary *point_dict(const ipc_geometry *g, CGPoint p) {
    CGPoint u = ipc_view_to_panel_unit(g, p);
    return @{@"view" : @[ @(p.x), @(p.y) ], @"panel_unit" : @[ @(u.x), @(u.y) ]};
}

static int cmd_pointer(const char *cmd, int argc, char **argv) {
    double v[5] = {0};
    int need = !strcmp(cmd, "swipe") ? 4 : 2;
    if (argc < need) { usage(); return 2; }
    for (int i = 0; i < argc && i < 5; i++)
        if (!parse_num(argv[i], &v[i])) return fail([NSString stringWithFormat:@"bad number: %s", argv[i]]);

    ipc_geometry g;
    if (!ipc_geometry_get(&g)) return fail(@"interface orientation unknown; refusing to guess the touch mapping");
    if (!ipc_hid_init()) return fail(@"IOHIDEventSystemClientCreate failed");

    NSMutableDictionary *d = [geometry_dict(&g) mutableCopy];
    d[@"ok"] = @YES;
    d[@"cmd"] = @(cmd);
    if (!strcmp(cmd, "tap")) {
        CGPoint p = CGPointMake(v[0], v[1]);
        ipc_hid_tap(&g, p);
        d[@"at"] = point_dict(&g, p);
    } else if (!strcmp(cmd, "longpress")) {
        CGPoint p = CGPointMake(v[0], v[1]);
        int ms = argc > 2 ? (int)v[2] : 1000;
        ipc_hid_longpress(&g, p, ms);
        d[@"at"] = point_dict(&g, p);
        d[@"ms"] = @(ms);
    } else {
        CGPoint a = CGPointMake(v[0], v[1]), b = CGPointMake(v[2], v[3]);
        int ms = argc > 4 ? (int)v[4] : 300;
        ipc_hid_swipe(&g, a, b, ms);
        d[@"from"] = point_dict(&g, a);
        d[@"to"] = point_dict(&g, b);
        d[@"ms"] = @(ms);
    }
    emit(d);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 2; }
        if (!spi_load()) return fail(@"private symbol resolution failed (see stderr)");
        const char *cmd = argv[1];
        int rc;
        if (!strcmp(cmd, "info")) {
            rc = cmd_info();
        } else if (!strcmp(cmd, "shot")) {
            rc = cmd_shot(argc - 2, argv + 2);
        } else if (!strcmp(cmd, "tap") || !strcmp(cmd, "swipe") || !strcmp(cmd, "longpress")) {
            rc = cmd_pointer(cmd, argc - 2, argv + 2);
        } else if (!strcmp(cmd, "type")) {
            if (argc < 3) { usage(); return 2; }
            if (!ipc_hid_init()) return fail(@"IOHIDEventSystemClientCreate failed");
            int bad = -1;
            if (!ipc_hid_type(argv[2], &bad))
                return fail([NSString stringWithFormat:@"unsupported character at index %d", bad]);
            emit(@{@"ok" : @YES, @"cmd" : @"type", @"chars" : @(strlen(argv[2]))});
            rc = 0;
        } else if (!strcmp(cmd, "key")) {
            if (argc < 3) { usage(); return 2; }
            if (!ipc_hid_init()) return fail(@"IOHIDEventSystemClientCreate failed");
            if (!ipc_hid_key(argv[2])) return fail([NSString stringWithFormat:@"unknown key: %s", argv[2]]);
            emit(@{@"ok" : @YES, @"cmd" : @"key", @"key" : @(argv[2])});
            rc = 0;
        } else if (!strcmp(cmd, "button")) {
            if (argc < 3) { usage(); return 2; }
            ipc_button b;
            if (!strcmp(argv[2], "home")) b = IPC_BUTTON_HOME;
            else if (!strcmp(argv[2], "volup")) b = IPC_BUTTON_VOLUP;
            else if (!strcmp(argv[2], "voldown")) b = IPC_BUTTON_VOLDOWN;
            else return fail(@"unsupported button (lock/power is intentionally not implemented)");
            if (!ipc_hid_init()) return fail(@"IOHIDEventSystemClientCreate failed");
            ipc_hid_button(b);
            emit(@{@"ok" : @YES, @"cmd" : @"button", @"button" : @(argv[2])});
            rc = 0;
        } else {
            usage();
            return 2;
        }
        // Let the HID system drain anything still queued before we exit.
        usleep(50 * 1000);
        return rc;
    }
}
