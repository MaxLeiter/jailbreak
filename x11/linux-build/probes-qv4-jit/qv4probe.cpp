// Device probe: replays QV4's ExecutableAllocator pattern with the iOS patch's
// canAllocateExecutableMemory() logic. Build:
//   xcrun --sdk iphoneos clang++ -arch arm64 -mios-version-min=16.0 -O1 -o qv4probe qv4probe.cpp
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static sigjmp_buf s_jump;
static volatile sig_atomic_t s_active = 0;
static pthread_t s_thread;
static struct sigaction s_old[3];
static const int s_sigs[3] = { SIGBUS, SIGSEGV, SIGILL };

static void handler(int sig, siginfo_t *, void *)
{
    if (s_active && pthread_equal(pthread_self(), s_thread))
        siglongjmp(s_jump, sig);
    for (int i = 0; i < 3; ++i)
        if (s_sigs[i] == sig)
            sigaction(sig, &s_old[i], nullptr);
}

static bool guardedCall(void *code, int expect, const char **why)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    for (int i = 0; i < 3; ++i)
        sigaction(s_sigs[i], &sa, &s_old[i]);
    s_thread = pthread_self();
    bool ok = false;
    int sig = sigsetjmp(s_jump, 1);
    if (sig == 0) {
        s_active = 1;
        int r = reinterpret_cast<int (*)()>(code)();
        s_active = 0;
        ok = r == expect;
        if (!ok)
            *why = "probe code returned the wrong value";
    } else {
        s_active = 0;
        *why = sig == SIGBUS ? "SIGBUS executing probe code" : sig == SIGSEGV ? "SIGSEGV executing probe code" : "SIGILL executing probe code";
    }
    for (int i = 0; i < 3; ++i)
        sigaction(s_sigs[i], &s_old[i], nullptr);
    return ok;
}

static void emit(uint32_t *at, int value)
{
    at[0] = 0x52800000u | (uint32_t(value & 0xffff) << 5); // movz w0, #value
    at[1] = 0xd65f03c0u;                                    // ret
}

static bool probe(int flags, const char **why)
{
    const size_t size = getpagesize();
    void *page = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | flags, -1, 0);
    if (page == MAP_FAILED) { *why = "mmap RW failed"; return false; }
    bool ok = true;
    for (int round = 0; round < 2 && ok; ++round) {
        if (round && mprotect(page, size, PROT_READ | PROT_WRITE) != 0) { *why = "mprotect RW failed"; ok = false; break; }
        emit(static_cast<uint32_t *>(page) + 4 * round, 42 + round);
        sys_cache_control(kCacheFunctionPrepareForExecution, page, size);
        if (mprotect(page, size, PROT_READ | PROT_EXEC) != 0) { *why = "mprotect RX failed"; ok = false; break; }
        ok = guardedCall(static_cast<uint32_t *>(page) + 4 * round, 42 + round, why);
    }
    munmap(page, size);
    return ok;
}

static double now() { struct timespec t; clock_gettime(CLOCK_UPTIME_RAW, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv)
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    const char *why = "ok";
    printf("pagesize %d\n", getpagesize());
    bool jitOk = probe(MAP_JIT, &why);
    printf("MAP_JIT probe: %s (%s)\n", jitOk ? "PASS" : "FAIL", why);
    why = "ok";
    double t0 = now();
    bool ok = probe(0, &why);
    printf("plain RW->RX probe: %s (%s) %.1f us\n", ok ? "PASS" : "FAIL", why, (now() - t0) * 1e6);

    // RWX must be caught by the guard, not kill us.
    if (argc > 1 && !strcmp(argv[1], "rwx")) {
        void *p = mmap(nullptr, getpagesize(), PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        printf("rwx mmap %p\n", p);
        if (p != MAP_FAILED) {
            emit(static_cast<uint32_t *>(p), 7);
            sys_cache_control(kCacheFunctionPrepareForExecution, p, 8);
            why = "ok";
            bool r = guardedCall(p, 7, &why);
            printf("rwx exec under guard: %s (%s)\n", r ? "PASS" : "FAIL", why);
        }
    }

    // Chunk replay: many small "functions" packed in shared pages, each written with
    // makeWritable(range rounded to page) -> write -> makeExecutable, then all executed.
    const size_t chunk = 4 * getpagesize();
    char *base = static_cast<char *>(mmap(nullptr, chunk, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
    const int n = int(chunk / 16);
    int bad = 0;
    t0 = now();
    for (int i = 0; i < n; ++i) {
        char *fn = base + i * 16;
        uintptr_t pg = uintptr_t(fn) & ~uintptr_t(getpagesize() - 1);
        size_t len = uintptr_t(fn) + 16 - pg;
        if (mprotect((void *)pg, len, PROT_READ | PROT_WRITE)) { printf("RW fail at %d\n", i); return 1; }
        emit(reinterpret_cast<uint32_t *>(fn), i & 0xffff);
        sys_cache_control(kCacheFunctionPrepareForExecution, fn, 16);
        if (mprotect((void *)pg, len, PROT_READ | PROT_EXEC)) { printf("RX fail at %d\n", i); return 1; }
        // call this one and an earlier one in the same page
        if (reinterpret_cast<int (*)()>(fn)() != (i & 0xffff)) ++bad;
        int j = i / 2;
        if (reinterpret_cast<int (*)()>(base + j * 16)() != (j & 0xffff)) ++bad;
    }
    double dt = now() - t0;
    printf("chunk replay: %d functions, %d bad, %.2f us per link\n", n, bad, dt * 1e6 / n);
    return bad ? 1 : 0;
}
