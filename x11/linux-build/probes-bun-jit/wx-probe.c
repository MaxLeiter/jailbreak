// A10 / iOS 17.6.1 fakesigned W^X probe, aimed at what JSC's ExecutableAllocator
// needs if we turn ENABLE_JIT back on for the iOS Bun build.
//
// JSC needs more than TinyCC does: TinyCC writes once and flips to RX forever,
// JSC repatches inline caches for the life of the process. So the questions are
// (a) can a page cycle RX -> RW -> RX repeatedly, and (b) is there a cheaper
// write path (an RW alias of the RX pages, i.e. WebKit's old separated W^X heap).
#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>
#include <libkern/OSCacheControl.h>

#ifndef MAP_JIT
#define MAP_JIT 0x0800
#endif

typedef uint64_t mvm_addr_t;
typedef uint64_t mvm_size_t;
extern kern_return_t mach_vm_remap(vm_map_t, mvm_addr_t *, mvm_size_t, mvm_addr_t,
                                   int, vm_map_t, mvm_addr_t, boolean_t,
                                   vm_prot_t *, vm_prot_t *, vm_inherit_t);
extern kern_return_t mach_vm_protect(vm_map_t, mvm_addr_t, mvm_size_t, boolean_t, vm_prot_t);

#define VM_FLAGS_ANYWHERE_ 0x0001

typedef int (*fn_t)(void);

// mov w0, #imm ; ret
static void emit(void *p, unsigned imm)
{
    uint32_t code[2] = { 0x52800000u | ((imm & 0xffffu) << 5), 0xd65f03c0u };
    memcpy(p, code, sizeof code);
}

static size_t pgsz(void) { return (size_t)getpagesize(); }

#define OK(fmt, ...)   printf("PASS  " fmt "\n", ##__VA_ARGS__)
#define BAD(fmt, ...)  printf("FAIL  " fmt "\n", ##__VA_ARGS__)
#define INFO(fmt, ...) printf("      " fmt "\n", ##__VA_ARGS__)

static int fails = 0;

int main(void)
{
    const size_t PS = pgsz();
    const size_t POOL = 128u * 1024u * 1024u; // JSC reserves a pool this size on arm64

    printf("== A10 JIT-memory probe (pid %d, page %zu)\n", getpid(), PS);

    // T1: can we even reserve a JSC-sized pool PROT_NONE and commit into it?
    void *pool = mmap(NULL, POOL, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (pool == MAP_FAILED) {
        BAD("T1 reserve %zu MB PROT_NONE: %s", POOL >> 20, strerror(errno));
        fails++;
    } else {
        OK("T1 reserve %zu MB PROT_NONE at %p", POOL >> 20, pool);
    }

    // T2: straight RWX mapping (what JSC does when it thinks it may have RWX).
    void *rwx = mmap(NULL, PS, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANON, -1, 0);
    if (rwx == MAP_FAILED)
        INFO("T2 mmap RWX refused: %s  (expected on iOS)", strerror(errno));
    else {
        // mapping may succeed while the page faults on execute; test carefully.
        emit(rwx, 0x11);
        sys_icache_invalidate(rwx, PS);
        INFO("T2 mmap RWX succeeded at %p (executing it is NOT tested here)", rwx);
    }

    // T3: MAP_JIT (needs the dynamic-codesigning entitlement).
    void *mj = mmap(NULL, PS, PROT_READ | PROT_WRITE | PROT_EXEC,
                    MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (mj == MAP_FAILED)
        INFO("T3 mmap MAP_JIT refused: %s  (expected bare-fakesigned)", strerror(errno));
    else
        INFO("T3 mmap MAP_JIT succeeded at %p", mj);

    if (pool == MAP_FAILED)
        return 1;

    // T4: commit one page of the pool and cycle RW -> RX -> RW -> RX, executing
    // a different constant each round. This is the JSC repatch pattern.
    void *page = (char *)pool + 64 * 1024 * 1024;
    int cycles_ok = 0;
    for (unsigned i = 1; i <= 5; i++) {
        if (mprotect(page, PS, PROT_READ | PROT_WRITE) != 0) {
            BAD("T4 cycle %u: mprotect RW: %s", i, strerror(errno));
            fails++;
            break;
        }
        emit(page, 0x100 + i);
        if (mprotect(page, PS, PROT_READ | PROT_EXEC) != 0) {
            BAD("T4 cycle %u: mprotect RX: %s", i, strerror(errno));
            fails++;
            break;
        }
        sys_icache_invalidate(page, PS);
        int got = ((fn_t)page)();
        if (got != (int)(0x100 + i)) {
            BAD("T4 cycle %u: executed stale/wrong code (got %#x want %#x)", i, got, 0x100 + i);
            fails++;
            break;
        }
        cycles_ok++;
    }
    if (cycles_ok == 5)
        OK("T4 RW<->RX repatch cycles: 5/5 executed the freshly written constant");

    // T5: RW alias of the RX page via mach_vm_remap (separated W^X heap model).
    // If this works, JSC can write through the alias with no mprotect at all.
    mvm_addr_t alias = 0;
    vm_prot_t cur = VM_PROT_READ | VM_PROT_WRITE, max = VM_PROT_READ | VM_PROT_WRITE;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &alias, PS, 0,
                                     VM_FLAGS_ANYWHERE_, mach_task_self(),
                                     (mvm_addr_t)(uintptr_t)page, /*copy=*/FALSE,
                                     &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        INFO("T5 mach_vm_remap alias: kr=%d (%s)", kr, mach_error_string(kr));
    } else {
        INFO("T5 alias mapped at %#llx cur=%#x max=%#x", (unsigned long long)alias, cur, max);
        kern_return_t kp = mach_vm_protect(mach_task_self(), alias, PS, FALSE,
                                           VM_PROT_READ | VM_PROT_WRITE);
        if (kp != KERN_SUCCESS)
            INFO("T5 alias mach_vm_protect RW: kr=%d (%s)", kp, mach_error_string(kp));
        emit((void *)(uintptr_t)alias, 0x2ee);
        sys_icache_invalidate(page, PS);
        int got = ((fn_t)page)();
        if (got == 0x2ee)
            OK("T5 separated W^X alias works: wrote via RW alias, RX view executed it");
        else {
            BAD("T5 alias write did not reach the RX view (got %#x want 0x2ee)", got);
            fails++;
        }
    }

    // T6: how expensive is the flip? JSC does this constantly if there is no alias.
    {
        const int N = 2000;
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        for (int i = 0; i < N; i++) {
            mprotect(page, PS, PROT_READ | PROT_WRITE);
            emit(page, 0x30);
            mprotect(page, PS, PROT_READ | PROT_EXEC);
        }
        clock_gettime(CLOCK_MONOTONIC, &b);
        double us = ((b.tv_sec - a.tv_sec) * 1e6 + (b.tv_nsec - a.tv_nsec) / 1e3) / N;
        INFO("T6 mprotect RW+RX round trip: %.2f us/flip over %d flips", us, N);
    }

    printf("== %s (%d failures)\n", fails ? "PROBLEMS" : "ALL KEY TESTS PASSED", fails);
    return fails ? 1 : 0;
}
