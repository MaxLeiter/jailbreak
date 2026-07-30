/*
 * iosc-input-test.c — inject input into the iosc compositor for testing, without
 * the Xios app. Speaks the same fixed 24-byte protocol the app uses over
 * /var/jb/tmp/mutter-input.sock or /var/jb/tmp/iosc-input.sock. Lets us prove
 * wl_keyboard/wl_pointer dispatch (e.g.
 * "type ls<Enter> into kgx") before wiring the device-side UIKit path.
 *
 *   iosc-input-test "ls -la" "echo hi"   # type each arg as a line (auto <Enter>)
 *   iosc-input-test -c 680 400           # left click at output pixel 680,400
 *   iosc-input-test -D 300 300 900 500   # slow press-drag-release (DnD test)
 *   iosc-input-test -s 680 400 0 -240    # smooth scroll -240px vertical (axis + stop)
 *   iosc-input-test -t 500 400           # two-finger touch gesture (wl_touch)
 *   iosc-input-test -p 300 300 900 500   # pencil stroke w/ pressure ramp (tablet-v2)
 *   iosc-input-test -k 0x6e 3            # one keysym tap w/ modifiers
 *
 *   iosc-input-test --socket /var/jb/tmp/mutter-input.sock -c 1080 810
 *
 * Coordinates are physical output pixels (the compositor maps to logical/stage space).
 * MIT.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "../apps/shared/XiosProtocol.h"

#define MUTTER_IN_SOCK "/var/jb/tmp/mutter-input.sock"
#define IOSC_IN_SOCK   "/var/jb/tmp/iosc-input.sock"

static int transfer_full(int fd, void *buf, size_t len, int writing)
{
    char *p = buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = writing ? write(fd, p + done, len - done)
                            : read(fd, p + done, len - done);
        if (n > 0) { done += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return -1;
    }
    return 0;
}

static int connect_path(const char *path, int quiet)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(a.sun_path)) {
        fprintf(stderr, "socket path too long: %s\n", path);
        close(fd);
        return -1;
    }
    strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        if (!quiet)
            fprintf(stderr, "connect %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    xios_msg hello = xios_protocol_hello();
    xios_msg peer;
    if (transfer_full(fd, &hello, sizeof(hello), 1) != 0 ||
        transfer_full(fd, &peer, sizeof(peer), 0) != 0 ||
        !xios_protocol_is_exact_hello(&peer)) {
        if (!quiet) fprintf(stderr, "strict-v1 HELLO failed on %s\n", path);
        close(fd);
        return -1;
    }
    fprintf(stderr, "connected to %s\n", path);
    return fd;
}

static int connect_sock(const char *path)
{
    const char *env_path = getenv("XIOS_INPUT_SOCK");
    if (!env_path || !env_path[0])
        env_path = getenv("IOSC_INPUT_SOCK");

    if (path && path[0])
        return connect_path(path, 0);
    if (env_path && env_path[0])
        return connect_path(env_path, 0);

    int fd = connect_path(MUTTER_IN_SOCK, 1);
    if (fd >= 0)
        return fd;
    fd = connect_path(IOSC_IN_SOCK, 1);
    if (fd >= 0)
        return fd;

    fprintf(stderr, "connect: no input socket up (tried %s, %s)\n",
            MUTTER_IN_SOCK, IOSC_IN_SOCK);
    return -1;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [--socket PATH] [mode | text...]\n"
            "  -c x y             left click\n"
            "  -D x0 y0 x1 y1     slow press-drag-release (DnD test)\n"
            "  -s x y dx dy       smooth scroll dx,dy px at x,y (axis + stop)\n"
            "  -g x y scale [deg] trackpad pinch at x,y to scale%% (200 = 2x, 50 = half),\n"
            "                     optional rotation in degrees (pointer-gestures pinch)\n"
            "  -t x y             two-finger touch gesture (wl_touch)\n"
            "  -p x0 y0 x1 y1     pencil stroke w/ pressure ramp (tablet-v2)\n"
            "  -k keysym [mods]   one key tap; mods bits: shift,ctrl,alt,super,caps,num\n"
            "  -T utf8...         send each arg as an XIOS_IN_TEXT record (full UTF-8,\n"
            "                     the iOS-keyboard path: text-input or the IM proxy)\n"
            "  text...            type each arg as a line of KEYSYM taps, ASCII only\n"
            "                     (auto <Enter>); use -T for the real text path\n"
            "       %s --mutter -c 1080 810\n"
            "       %s --iosc \"echo hi\"\n",
            argv0, argv0, argv0);
}

static void send_msg(int fd, xios_msg *m)
{
    m->magic = XIOS_MSG_MAGIC;
    if (m->type == XIOS_IN_TEXT)
        m->length = m->code;
    if (write(fd, m, sizeof(*m)) != (ssize_t)sizeof(*m)) perror("write");
}

static void key_tap(int fd, uint32_t keysym)
{
    xios_msg m = { .type = XIOS_IN_KEY, .code = keysym, .state = 1 };
    send_msg(fd, &m);
    m.state = 0;
    send_msg(fd, &m);
    usleep(25000);   /* let the client process each keypress */
}

int main(int argc, char **argv)
{
    const char *socket_path = NULL;
    int argi = 1;

    while (argi < argc) {
        if (!strcmp(argv[argi], "--socket")) {
            if (argi + 1 >= argc) { usage(argv[0]); return 1; }
            socket_path = argv[argi + 1];
            argi += 2;
        } else if (!strcmp(argv[argi], "--mutter")) {
            socket_path = MUTTER_IN_SOCK;
            argi++;
        } else if (!strcmp(argv[argi], "--iosc")) {
            socket_path = IOSC_IN_SOCK;
            argi++;
        } else if (!strcmp(argv[argi], "-h") || !strcmp(argv[argi], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            break;
        }
    }

    int fd = connect_sock(socket_path);
    if (fd < 0) return 1;

    /* -k <keysym_hex> <mods>: one key with modifiers (bit0 shift,1 ctrl,2 alt).
     * e.g. -k 0x6e 3 => Ctrl+Shift+n (a GTK accelerator test). */
    if (argc - argi >= 2 && !strcmp(argv[argi], "-k")) {
        uint32_t ks = (uint32_t)strtoul(argv[argi + 1], NULL, 0);
        uint32_t mods = (argc - argi >= 3) ? (uint32_t)strtoul(argv[argi + 2], NULL, 0) : 0;
        xios_msg m = { .type = XIOS_IN_KEY, .code = ks, .state = 1, .mods = mods };
        send_msg(fd, &m);
        m.state = 0; m.mods = 0;
        send_msg(fd, &m);
        fprintf(stderr, "sent key 0x%x mods %u\n", ks, mods);
        usleep(150000); close(fd); return 0;
    }

    /* -T <utf8>...: send each argument as one XIOS_IN_TEXT record, the way the
     * Xios app sends what the iOS keyboard produced. This is NOT the same path as
     * the bare `text...` mode below, which taps one keysym per byte and so can
     * only ever carry ASCII: TEXT goes to the focused text-input (or, under a
     * nested compositor, to the registered input-method proxy) and carries full
     * UTF-8, which is the only way to exercise autocorrect/emoji/dictation input.
     * Not having this mode made an OSK bridge look broken twice; see
     * x11/docs/osk-plan.md "Device run 2026-07-29". */
    if (argc - argi >= 2 && !strcmp(argv[argi], "-T")) {
        for (int i = argi + 1; i < argc; i++) {
            size_t len = strlen(argv[i]);
            if (len == 0 || len > 4096) { fprintf(stderr, "skipping %zu-byte arg\n", len); continue; }
            xios_msg m = { .type = XIOS_IN_TEXT, .code = (uint32_t)len };
            if (write(fd, &m, sizeof(m)) != (ssize_t)sizeof(m) ||
                write(fd, argv[i], len) != (ssize_t)len) {
                perror("write");
                break;
            }
            fprintf(stderr, "sent TEXT %zu bytes: %s\n", len, argv[i]);
            usleep(50000);
        }
        usleep(150000); close(fd); return 0;
    }

    /* -D x0 y0 x1 y1: press at x0,y0, drag in steps to x1,y1, release. Slow
     * enough that a client can react mid-drag (start_drag / accept an offer). */
    if (argc - argi >= 5 && !strcmp(argv[argi], "-D")) {
        int x0 = atoi(argv[argi + 1]), y0 = atoi(argv[argi + 2]);
        int x1 = atoi(argv[argi + 3]), y1 = atoi(argv[argi + 4]);
        xios_msg mv = { .type = XIOS_IN_MOTION, .x = x0, .y = y0 };
        send_msg(fd, &mv); usleep(50000);
        xios_msg bd = { .type = XIOS_IN_BUTTON, .x = x0, .y = y0, .code = 1, .state = 1 };
        send_msg(fd, &bd); usleep(200000);
        for (int i = 1; i <= 10; i++) {
            xios_msg st = { .type = XIOS_IN_MOTION,
                .x = x0 + (x1 - x0) * i / 10, .y = y0 + (y1 - y0) * i / 10 };
            send_msg(fd, &st); usleep(40000);
        }
        usleep(200000);
        xios_msg bu = { .type = XIOS_IN_BUTTON, .x = x1, .y = y1, .code = 1, .state = 0 };
        send_msg(fd, &bu);
        fprintf(stderr, "dragged %d,%d -> %d,%d\n", x0, y0, x1, y1);
        usleep(100000); close(fd); return 0;
    }

    /* -t x y: two-finger multitouch — ids 0 and 1 (120px apart) go down, slide
     * 80px downward together, then lift. Exercises independent wl_touch ids. */
    if (argc - argi >= 3 && !strcmp(argv[argi], "-t")) {
        int x = atoi(argv[argi + 1]), y = atoi(argv[argi + 2]);
        xios_msg d0 = { .type = XIOS_IN_TOUCH, .x = x,       .y = y, .code = 0, .state = 1 };
        xios_msg d1 = { .type = XIOS_IN_TOUCH, .x = x + 120, .y = y, .code = 1, .state = 1 };
        send_msg(fd, &d0); send_msg(fd, &d1); usleep(80000);
        for (int i = 1; i <= 8; i++) {
            xios_msg m0 = { .type = XIOS_IN_TOUCH, .x = x,       .y = y + i * 10, .code = 0, .state = 2 };
            xios_msg m1 = { .type = XIOS_IN_TOUCH, .x = x + 120, .y = y + i * 10, .code = 1, .state = 2 };
            send_msg(fd, &m0); send_msg(fd, &m1); usleep(30000);
        }
        xios_msg u0 = { .type = XIOS_IN_TOUCH, .x = x,       .y = y + 80, .code = 0, .state = 0 };
        xios_msg u1 = { .type = XIOS_IN_TOUCH, .x = x + 120, .y = y + 80, .code = 1, .state = 0 };
        send_msg(fd, &u0); send_msg(fd, &u1);
        fprintf(stderr, "two-finger gesture at %d,%d\n", x, y);
        usleep(100000); close(fd); return 0;
    }

    /* -p x0 y0 x1 y1: a pencil stroke — down at x0,y0, 12 motion steps to x1,y1
     * with pressure ramping 20%..100% and a fixed 30/-15 degree tilt, then up. */
    if (argc - argi >= 5 && !strcmp(argv[argi], "-p")) {
        int x0 = atoi(argv[argi + 1]), y0 = atoi(argv[argi + 2]);
        int x1 = atoi(argv[argi + 3]), y1 = atoi(argv[argi + 4]);
        uint32_t tilt = (uint32_t)(30 + 90) | ((uint32_t)(-15 + 90) << 8);
        xios_msg dn = { .type = XIOS_IN_TABLET, .x = x0, .y = y0,
                                  .code = 65535 / 5, .state = 1, .mods = tilt };
        send_msg(fd, &dn); usleep(50000);
        for (int i = 1; i <= 12; i++) {
            xios_msg mv2 = { .type = XIOS_IN_TABLET,
                .x = x0 + (x1 - x0) * i / 12, .y = y0 + (y1 - y0) * i / 12,
                .code = (uint32_t)(65535 * (20 + 80 * i / 12) / 100),
                .state = 2, .mods = tilt };
            send_msg(fd, &mv2); usleep(30000);
        }
        xios_msg up = { .type = XIOS_IN_TABLET, .x = x1, .y = y1,
                                  .code = 0, .state = 0, .mods = tilt };
        send_msg(fd, &up);
        fprintf(stderr, "pencil stroke %d,%d -> %d,%d\n", x0, y0, x1, y1);
        usleep(100000); close(fd); return 0;
    }

    /* -s x y dx dy: smooth scroll — park the pointer at x,y then emit 24 AXIS
     * deltas totalling dx,dy output px (1/256 fixed point) at ~120Hz, ending
     * with an axis_stop so kinetic clients fling. */
    if (argc - argi >= 5 && !strcmp(argv[argi], "-s")) {
        int x = atoi(argv[argi + 1]), y = atoi(argv[argi + 2]);
        int dx = atoi(argv[argi + 3]), dy = atoi(argv[argi + 4]);
        xios_msg mv = { .type = XIOS_IN_MOTION, .x = x, .y = y };
        send_msg(fd, &mv); usleep(50000);
        for (int i = 0; i < 24; i++) {
            xios_msg ax = { .type = XIOS_IN_AXIS,
                .x = dx * 256 / 24, .y = dy * 256 / 24 };
            send_msg(fd, &ax); usleep(8000);
        }
        xios_msg stop = { .type = XIOS_IN_AXIS, .state = 1 };
        send_msg(fd, &stop);
        fprintf(stderr, "scrolled (%d,%d) at %d,%d\n", dx, dy, x, y);
        usleep(100000); close(fd); return 0;
    }

    /* -g x y scale [deg]: pinch — park the pointer at x,y, then ramp an absolute
     * pinch scale (and optional rotation) from 1.0 over 24 frames and end the
     * gesture. Exists because no trackpad is needed to exercise the compositor
     * half: a physical Magic Trackpad is the only other source of a pinch. */
    if (argc - argi >= 4 && !strcmp(argv[argi], "-g")) {
        int x = atoi(argv[argi + 1]), y = atoi(argv[argi + 2]);
        int scale_pct = atoi(argv[argi + 3]);
        int deg = (argc - argi >= 5) ? atoi(argv[argi + 4]) : 0;
        xios_msg mv = { .type = XIOS_IN_MOTION, .x = x, .y = y };
        send_msg(fd, &mv); usleep(50000);
        /* kind 2 = pinch, phase 0 = begin, 2 fingers. Scale starts at 1.0 (256). */
        xios_msg begin = { .type = XIOS_IN_GESTURE,
            .code = 2u | (0u << 8) | (2u << 16), .state = 256 };
        send_msg(fd, &begin); usleep(16000);
        for (int i = 1; i <= 24; i++) {
            double t = (double)i / 24.0;
            double scale = 1.0 + ((double)scale_pct / 100.0 - 1.0) * t;
            xios_msg up = { .type = XIOS_IN_GESTURE,
                .code = 2u | (1u << 8) | (2u << 16),
                .state = (unsigned)(scale * 256.0),
                .mods = (unsigned)(int)(deg * t * 256.0) };
            send_msg(fd, &up); usleep(8000);
        }
        xios_msg end = { .type = XIOS_IN_GESTURE,
            .code = 2u | (2u << 8) | (2u << 16), .state = (unsigned)(scale_pct * 256 / 100) };
        send_msg(fd, &end);
        fprintf(stderr, "pinched to %d%% (rot %ddeg) at %d,%d\n", scale_pct, deg, x, y);
        usleep(100000); close(fd); return 0;
    }

    if (argc - argi >= 3 && !strcmp(argv[argi], "-c")) {
        int x = atoi(argv[argi + 1]), y = atoi(argv[argi + 2]);
        xios_msg mv = { .type = XIOS_IN_MOTION, .x = x, .y = y };
        send_msg(fd, &mv); usleep(30000);
        xios_msg bd = { .type = XIOS_IN_BUTTON, .x = x, .y = y, .code = 1, .state = 1 };
        send_msg(fd, &bd); usleep(60000);
        xios_msg bu = { .type = XIOS_IN_BUTTON, .x = x, .y = y, .code = 1, .state = 0 };
        send_msg(fd, &bu);
        fprintf(stderr, "clicked at %d,%d\n", x, y);
        usleep(100000); close(fd); return 0;
    }

    for (int i = argi; i < argc; i++) {
        for (const char *p = argv[i]; *p; p++) {
            unsigned char c = (unsigned char)*p;
            uint32_t ks = (c == '\n') ? 0xff0d : (uint32_t)c;   /* ASCII keysym == codepoint */
            key_tap(fd, ks);
        }
        key_tap(fd, 0xff0d);   /* Return: run the line */
        fprintf(stderr, "typed: %s<Enter>\n", argv[i]);
    }
    usleep(150000);
    close(fd);
    return 0;
}
