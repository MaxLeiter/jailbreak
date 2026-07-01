/*
 * iosc-input-test.c — inject input into the iosc compositor for testing, without
 * the Xios app. Speaks the same fixed 24-byte protocol the app uses over
 * /var/jb/tmp/iosc-input.sock. Lets us prove wl_keyboard/wl_pointer dispatch (e.g.
 * "type ls<Enter> into kgx") before wiring the device-side UIKit path.
 *
 *   iosc-input-test "ls -la" "echo hi"   # type each arg as a line (auto <Enter>)
 *   iosc-input-test -c 680 400           # left click at output pixel 680,400
 *   iosc-input-test -D 300 300 900 500   # slow press-drag-release (DnD test)
 *   iosc-input-test -t 500 400           # two-finger touch gesture (wl_touch)
 *   iosc-input-test -p 300 300 900 500   # pencil stroke w/ pressure ramp (tablet-v2)
 *
 * Coordinates are physical output pixels (iosc converts to logical itself).
 * MIT.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>

#define IOSC_IN_MOTION 1
#define IOSC_IN_BUTTON 2
#define IOSC_IN_KEY    3
#define IOSC_IN_TOUCH  6   /* code = touch id; state: 0 up, 1 down, 2 motion, 3 cancel */
#define IOSC_IN_TABLET 7   /* code = pressure 0..65535; state as touch; mods = tilt+90 packed */
#define IOSC_IN_AXIS   9   /* x,y = dx,dy 1/256 px; code = source; state bit0 = stop */

struct iosc_in_msg {
    uint32_t type;
    int32_t  x, y;
    uint32_t code;     /* button 1/2/3 ; key: X keysym */
    uint32_t state;    /* button 1=down 0=up */
    uint32_t mods;     /* bit0 shift, bit1 ctrl, bit2 alt */
};

static int connect_sock(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, "/var/jb/tmp/iosc-input.sock", sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        perror("connect (is iosc running?)"); close(fd); return -1;
    }
    return fd;
}

static void send_msg(int fd, struct iosc_in_msg *m)
{
    if (write(fd, m, sizeof(*m)) != (ssize_t)sizeof(*m)) perror("write");
}

static void key_tap(int fd, uint32_t keysym)
{
    struct iosc_in_msg m = { .type = IOSC_IN_KEY, .code = keysym, .state = 1 };
    send_msg(fd, &m);
    usleep(25000);   /* let the client process each keypress */
}

int main(int argc, char **argv)
{
    int fd = connect_sock();
    if (fd < 0) return 1;

    /* -k <keysym_hex> <mods>: one key with modifiers (bit0 shift,1 ctrl,2 alt).
     * e.g. -k 0x6e 3 => Ctrl+Shift+n (a GTK accelerator test). */
    if (argc >= 3 && !strcmp(argv[1], "-k")) {
        uint32_t ks = (uint32_t)strtoul(argv[2], NULL, 0);
        uint32_t mods = (argc >= 4) ? (uint32_t)strtoul(argv[3], NULL, 0) : 0;
        struct iosc_in_msg m = { .type = IOSC_IN_KEY, .code = ks, .state = 1, .mods = mods };
        send_msg(fd, &m);
        fprintf(stderr, "sent key 0x%x mods %u\n", ks, mods);
        usleep(150000); close(fd); return 0;
    }

    /* -D x0 y0 x1 y1: press at x0,y0, drag in steps to x1,y1, release. Slow
     * enough that a client can react mid-drag (start_drag / accept an offer). */
    if (argc >= 6 && !strcmp(argv[1], "-D")) {
        int x0 = atoi(argv[2]), y0 = atoi(argv[3]);
        int x1 = atoi(argv[4]), y1 = atoi(argv[5]);
        struct iosc_in_msg mv = { .type = IOSC_IN_MOTION, .x = x0, .y = y0 };
        send_msg(fd, &mv); usleep(50000);
        struct iosc_in_msg bd = { .type = IOSC_IN_BUTTON, .x = x0, .y = y0, .code = 1, .state = 1 };
        send_msg(fd, &bd); usleep(200000);
        for (int i = 1; i <= 10; i++) {
            struct iosc_in_msg st = { .type = IOSC_IN_MOTION,
                .x = x0 + (x1 - x0) * i / 10, .y = y0 + (y1 - y0) * i / 10 };
            send_msg(fd, &st); usleep(40000);
        }
        usleep(200000);
        struct iosc_in_msg bu = { .type = IOSC_IN_BUTTON, .x = x1, .y = y1, .code = 1, .state = 0 };
        send_msg(fd, &bu);
        fprintf(stderr, "dragged %d,%d -> %d,%d\n", x0, y0, x1, y1);
        usleep(100000); close(fd); return 0;
    }

    /* -t x y: two-finger multitouch — ids 0 and 1 (120px apart) go down, slide
     * 80px downward together, then lift. Exercises independent wl_touch ids. */
    if (argc >= 4 && !strcmp(argv[1], "-t")) {
        int x = atoi(argv[2]), y = atoi(argv[3]);
        struct iosc_in_msg d0 = { .type = IOSC_IN_TOUCH, .x = x,       .y = y, .code = 0, .state = 1 };
        struct iosc_in_msg d1 = { .type = IOSC_IN_TOUCH, .x = x + 120, .y = y, .code = 1, .state = 1 };
        send_msg(fd, &d0); send_msg(fd, &d1); usleep(80000);
        for (int i = 1; i <= 8; i++) {
            struct iosc_in_msg m0 = { .type = IOSC_IN_TOUCH, .x = x,       .y = y + i * 10, .code = 0, .state = 2 };
            struct iosc_in_msg m1 = { .type = IOSC_IN_TOUCH, .x = x + 120, .y = y + i * 10, .code = 1, .state = 2 };
            send_msg(fd, &m0); send_msg(fd, &m1); usleep(30000);
        }
        struct iosc_in_msg u0 = { .type = IOSC_IN_TOUCH, .x = x,       .y = y + 80, .code = 0, .state = 0 };
        struct iosc_in_msg u1 = { .type = IOSC_IN_TOUCH, .x = x + 120, .y = y + 80, .code = 1, .state = 0 };
        send_msg(fd, &u0); send_msg(fd, &u1);
        fprintf(stderr, "two-finger gesture at %d,%d\n", x, y);
        usleep(100000); close(fd); return 0;
    }

    /* -p x0 y0 x1 y1: a pencil stroke — down at x0,y0, 12 motion steps to x1,y1
     * with pressure ramping 20%..100% and a fixed 30/-15 degree tilt, then up. */
    if (argc >= 6 && !strcmp(argv[1], "-p")) {
        int x0 = atoi(argv[2]), y0 = atoi(argv[3]);
        int x1 = atoi(argv[4]), y1 = atoi(argv[5]);
        uint32_t tilt = (uint32_t)(30 + 90) | ((uint32_t)(-15 + 90) << 8);
        struct iosc_in_msg dn = { .type = IOSC_IN_TABLET, .x = x0, .y = y0,
                                  .code = 65535 / 5, .state = 1, .mods = tilt };
        send_msg(fd, &dn); usleep(50000);
        for (int i = 1; i <= 12; i++) {
            struct iosc_in_msg mv2 = { .type = IOSC_IN_TABLET,
                .x = x0 + (x1 - x0) * i / 12, .y = y0 + (y1 - y0) * i / 12,
                .code = (uint32_t)(65535 * (20 + 80 * i / 12) / 100),
                .state = 2, .mods = tilt };
            send_msg(fd, &mv2); usleep(30000);
        }
        struct iosc_in_msg up = { .type = IOSC_IN_TABLET, .x = x1, .y = y1,
                                  .code = 0, .state = 0, .mods = tilt };
        send_msg(fd, &up);
        fprintf(stderr, "pencil stroke %d,%d -> %d,%d\n", x0, y0, x1, y1);
        usleep(100000); close(fd); return 0;
    }

    /* -s x y dx dy: smooth scroll — park the pointer at x,y then emit 24 AXIS
     * deltas totalling dx,dy output px (1/256 fixed point) at ~120Hz, ending
     * with an axis_stop so kinetic clients fling. */
    if (argc >= 6 && !strcmp(argv[1], "-s")) {
        int x = atoi(argv[2]), y = atoi(argv[3]);
        int dx = atoi(argv[4]), dy = atoi(argv[5]);
        struct iosc_in_msg mv = { .type = IOSC_IN_MOTION, .x = x, .y = y };
        send_msg(fd, &mv); usleep(50000);
        for (int i = 0; i < 24; i++) {
            struct iosc_in_msg ax = { .type = IOSC_IN_AXIS,
                .x = dx * 256 / 24, .y = dy * 256 / 24 };
            send_msg(fd, &ax); usleep(8000);
        }
        struct iosc_in_msg stop = { .type = IOSC_IN_AXIS, .state = 1 };
        send_msg(fd, &stop);
        fprintf(stderr, "scrolled (%d,%d) at %d,%d\n", dx, dy, x, y);
        usleep(100000); close(fd); return 0;
    }

    if (argc >= 4 && !strcmp(argv[1], "-c")) {
        int x = atoi(argv[2]), y = atoi(argv[3]);
        struct iosc_in_msg mv = { .type = IOSC_IN_MOTION, .x = x, .y = y };
        send_msg(fd, &mv); usleep(30000);
        struct iosc_in_msg bd = { .type = IOSC_IN_BUTTON, .x = x, .y = y, .code = 1, .state = 1 };
        send_msg(fd, &bd); usleep(60000);
        struct iosc_in_msg bu = { .type = IOSC_IN_BUTTON, .x = x, .y = y, .code = 1, .state = 0 };
        send_msg(fd, &bu);
        fprintf(stderr, "clicked at %d,%d\n", x, y);
        usleep(100000); close(fd); return 0;
    }

    for (int i = 1; i < argc; i++) {
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
