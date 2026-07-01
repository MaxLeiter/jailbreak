/*
 * iosc-input-test.c — inject input into the iosc compositor for testing, without
 * the Xios app. Speaks the same fixed 24-byte protocol the app uses over
 * /var/jb/tmp/iosc-input.sock. Lets us prove wl_keyboard/wl_pointer dispatch (e.g.
 * "type ls<Enter> into kgx") before wiring the device-side UIKit path.
 *
 *   iosc-input-test "ls -la" "echo hi"   # type each arg as a line (auto <Enter>)
 *   iosc-input-test -c 680 400           # left click at output pixel 680,400
 *
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
