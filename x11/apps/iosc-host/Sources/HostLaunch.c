#include "HostLaunch.h"
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>

#define IOSCD_SOCK "/var/jb/tmp/ioscd.sock"

int ioscd_send_launch(const char *app_id, const char *exec)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, IOSCD_SOCK, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { close(fd); return -1; }

    char line[8192];
    int n = snprintf(line, sizeof(line), "LAUNCH\t%s\t%s\n",
                     app_id ? app_id : "", exec ? exec : "");
    if (n < 0) { close(fd); return -1; }
    size_t left = (size_t)n; const char *p = line;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w > 0) { p += w; left -= (size_t)w; continue; }
        if (w < 0 && errno == EINTR) continue;
        close(fd); return -1;
    }
    char buf[64];
    (void)read(fd, buf, sizeof(buf));   /* short ack (LAUNCHED/RAISED/ERR); ignored */
    close(fd);
    return 0;
}
