#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

static int wait_for_child(pid_t child)
{
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR)
            continue;
        perror("xios-setsid: waitpid");
        return 126;
    }
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return 126;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: xios-setsid PROGRAM [ARG ...]\n");
        return 64;
    }

    if (setsid() < 0) {
        if (errno != EPERM) {
            perror("xios-setsid: setsid");
            return 126;
        }

        pid_t child = fork();
        if (child < 0) {
            perror("xios-setsid: fork");
            return 126;
        }
        if (child > 0)
            return wait_for_child(child);
        if (setsid() < 0) {
            perror("xios-setsid: child setsid");
            _exit(126);
        }
    }

    execvp(argv[1], &argv[1]);
    perror("xios-setsid: execvp");
    return errno == ENOENT ? 127 : 126;
}
