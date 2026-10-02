// Does an RWX anonymous mapping actually EXECUTE bare-fakesigned on the A10, or
// does it only map? If it executes, JSC's stock non-fast-JIT-permissions path
// (write straight through an RWX pool) needs no patch at all.
// Forks so a kill/SIGBUS is contained and reportable.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <libkern/OSCacheControl.h>

typedef int (*fn_t)(void);

static void emit(void *p, unsigned imm)
{
    uint32_t code[2] = { 0x52800000u | ((imm & 0xffffu) << 5), 0xd65f03c0u };
    memcpy(p, code, sizeof code);
}

static int child_try(int rwx_then_write_again)
{
    size_t PS = (size_t)getpagesize();
    void *p = mmap(NULL, PS, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap RWX failed: %s\n", strerror(errno));
        return 2;
    }
    emit(p, 0x41);
    sys_icache_invalidate(p, PS);
    int got = ((fn_t)p)();
    if (got != 0x41) {
        fprintf(stderr, "executed wrong value %#x\n", got);
        return 3;
    }
    if (rwx_then_write_again) {
        // The thing JSC actually wants: overwrite live code in place, no mprotect.
        emit(p, 0x42);
        sys_icache_invalidate(p, PS);
        if (((fn_t)p)() != 0x42) {
            fprintf(stderr, "in-place repatch not observed\n");
            return 4;
        }
    }
    return 0;
}

static const char *why(int st)
{
    static char buf[64];
    if (WIFSIGNALED(st)) { snprintf(buf, sizeof buf, "killed by signal %d", WTERMSIG(st)); return buf; }
    snprintf(buf, sizeof buf, "exit %d", WEXITSTATUS(st));
    return buf;
}

int main(void)
{
    for (int variant = 0; variant < 2; variant++) {
        pid_t pid = fork();
        if (pid == 0) _exit(child_try(variant));
        int st = 0;
        waitpid(pid, &st, 0);
        printf("%-28s %s\n",
               variant ? "RWX exec + in-place repatch" : "RWX exec",
               (WIFEXITED(st) && WEXITSTATUS(st) == 0) ? "WORKS" : why(st));
    }
    return 0;
}
