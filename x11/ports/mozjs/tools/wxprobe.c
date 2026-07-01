// wxprobe.c — de-risk JIT W^X on iOS. Tests whether a signed binary can allocate
// writable memory, emit arm64 code, make it executable, and run it. Each strategy
// runs in a forked child so a codesigning SIGKILL (9) / SIGBUS / SIGILL is captured
// as the child's termination signal instead of taking down the whole probe.
//
// A trivial leaf function is emitted:  movz w0, #42 ; ret   -> returns 42.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <libkern/OSCacheControl.h>

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

typedef int (*fn_t)(void);
typedef void (*jit_wp_fn)(int);

// The SDK marks pthread_jit_write_protect_np() as __attribute__((unavailable))
// on iOS, so it can't be referenced by name — resolve it at runtime with dlsym.
static jit_wp_fn g_jit_wp = 0;

static const uint32_t CODE[] = {
    0x52800540u, // movz w0, #42
    0xd65f03c0u, // ret
};
#define CODE_BYTES sizeof(CODE)

enum { OK42 = 42, E_MMAP = 101, E_MPROTECT = 102, E_NULLFN = 103 };

// ---- strategy 1: mmap RW, mprotect -> RX, execute -------------------------
static int child_mprotect(void) {
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE,
                   MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) { fprintf(stderr, "mmap RW errno=%d\n", errno); return E_MMAP; }
    memcpy(p, CODE, CODE_BYTES);
    if (mprotect(p, pg, PROT_READ | PROT_EXEC) != 0) {
        fprintf(stderr, "mprotect RX errno=%d (%s)\n", errno, strerror(errno));
        return E_MPROTECT;
    }
    sys_icache_invalidate(p, CODE_BYTES);
    fn_t f = (fn_t)p;
    return f();
}

// ---- strategy 2: mmap RWX directly, execute -------------------------------
static int child_rwx(void) {
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) { fprintf(stderr, "mmap RWX errno=%d\n", errno); return E_MMAP; }
    memcpy(p, CODE, CODE_BYTES);
    sys_icache_invalidate(p, CODE_BYTES);
    fn_t f = (fn_t)p;
    return f();
}

// ---- strategy 3: MAP_JIT + pthread_jit_write_protect_np (Apple fast W^X) ---
static int child_mapjit(void) {
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    void *p = mmap(NULL, pg, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) { fprintf(stderr, "mmap MAP_JIT errno=%d\n", errno); return E_MMAP; }
    if (g_jit_wp) g_jit_wp(0); // make writable
    memcpy(p, CODE, CODE_BYTES);
    if (g_jit_wp) g_jit_wp(1); // make executable
    sys_icache_invalidate(p, CODE_BYTES);
    fn_t f = (fn_t)p;
    return f();
}

// ---- strategy 4: repeated RW<->RX flips, verify correctness ---------------
// SpiderMonkey re-flips the code region on every patch. Emit movz w0,#i each
// iteration and confirm the freshly-written code executes correctly.
static int child_flip_loop(void) {
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    uint32_t *p = mmap(NULL, pg, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) return E_MMAP;
    p[1] = 0xd65f03c0u; // ret
    fn_t f = (fn_t)p;
    for (int i = 0; i < 1024; i++) {
        if (mprotect(p, pg, PROT_READ | PROT_WRITE) != 0) return E_MPROTECT;
        p[0] = 0x52800000u | ((uint32_t)(i & 0xffff) << 5); // movz w0, #i
        if (mprotect(p, pg, PROT_READ | PROT_EXEC) != 0) return E_MPROTECT;
        sys_icache_invalidate(p, 8);
        int r = f();
        if (r != (i & 0xffff)) { fprintf(stderr, "flip mismatch i=%d got=%d\n", i, r); return 200; }
    }
    return OK42;
}

// ---- strategy 5: measure the mprotect W^X flip cost -----------------------
static double ticks_to_ns(uint64_t d) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)d * (double)tb.numer / (double)tb.denom;
}
static int child_bench(void) {
    size_t pg = (size_t)sysconf(_SC_PAGESIZE);
    uint32_t *p = mmap(NULL, pg, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE, -1, 0);
    if (p == MAP_FAILED) return E_MMAP;
    p[0] = 0x52800540u; p[1] = 0xd65f03c0u;
    const int N = 100000;
    uint64_t t0 = mach_absolute_time();
    for (int i = 0; i < N; i++) {
        mprotect(p, pg, PROT_READ | PROT_WRITE);
        mprotect(p, pg, PROT_READ | PROT_EXEC);
    }
    uint64_t t1 = mach_absolute_time();
    double per = ticks_to_ns(t1 - t0) / N;
    fprintf(stderr, "  mprotect RW<->RX flip-pair: %.1f ns  (%d iters)\n", per, N);

    if (mprotect(p, pg, PROT_READ | PROT_EXEC) != 0) return E_MPROTECT;
    uint64_t t2 = mach_absolute_time();
    for (int i = 0; i < N; i++) sys_icache_invalidate(p, 8);
    uint64_t t3 = mach_absolute_time();
    fprintf(stderr, "  sys_icache_invalidate(8B):  %.1f ns\n", ticks_to_ns(t3 - t2) / N);
    return OK42;
}

static void run(const char *name, int (*fn)(void)) {
    fflush(NULL);
    pid_t pid = fork();
    if (pid == 0) { _exit(fn()); }
    int st = 0;
    waitpid(pid, &st, 0);
    if (WIFEXITED(st)) {
        int rc = WEXITSTATUS(st);
        if (rc == OK42) printf("[%-9s] PASS  (executed JIT code, returned 42)\n", name);
        else            printf("[%-9s] FAIL  (child exit %d)\n", name, rc);
    } else if (WIFSIGNALED(st)) {
        int s = WTERMSIG(st);
        printf("[%-9s] KILLED by signal %d (%s)\n", name, s, strsignal(s));
    } else {
        printf("[%-9s] unknown wait status 0x%x\n", name, st);
    }
}

int main(void) {
    g_jit_wp = (jit_wp_fn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    printf("pthread_jit_write_protect_np present: %s\n", g_jit_wp ? "yes" : "no");
    printf("page size: %ld\n", sysconf(_SC_PAGESIZE));
    run("mprotect", child_mprotect);
    run("rwx",      child_rwx);
    run("mapjit",   child_mapjit);
    run("fliploop", child_flip_loop);
    run("bench",    child_bench);
    return 0;
}
