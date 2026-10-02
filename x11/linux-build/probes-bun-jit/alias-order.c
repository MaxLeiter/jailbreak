// Why did the single-page alias test pass and the full-pool one SIGBUS?
// Hypothesis: a page has to be faulted in and validated through its OWN
// mapping (RW -> write -> RX) before the RX view will execute it; after that,
// writes through the RW alias are honoured. Each variant runs in a child so a
// SIGBUS is a result rather than the end of the run.
#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>

typedef uint64_t mvm_addr_t;
extern kern_return_t mach_vm_remap(vm_map_t, mvm_addr_t *, uint64_t, mvm_addr_t,
                                   int, vm_map_t, mvm_addr_t, boolean_t,
                                   vm_prot_t *, vm_prot_t *, vm_inherit_t);
#define VM_FLAGS_ANYWHERE_ 0x0001

typedef int (*fn_t)(void);
static size_t PS;

static void emit(void *p, unsigned imm)
{
    uint32_t code[2] = { 0x52800000u | ((imm & 0xffffu) << 5), 0xd65f03c0u };
    memcpy(p, code, sizeof code);
}

// Builds the pool exactly as JSC would, returns exec base and writable alias.
static int build_pool(size_t pool, void **execOut, void **aliasOut, int lockProt)
{
    void *jit = mmap(NULL, pool, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANON, -1, 0);
    if (jit == MAP_FAILED) return -1;
    mvm_addr_t w = 0;
    vm_prot_t cur = 0, max = 0;
    if (mach_vm_remap(mach_task_self(), &w, pool, 0, VM_FLAGS_ANYWHERE_,
                      mach_task_self(), (mvm_addr_t)(uintptr_t)jit, FALSE,
                      &cur, &max, VM_INHERIT_DEFAULT) != KERN_SUCCESS)
        return -1;
    if (lockProt) {
        if (vm_protect(mach_task_self(), (vm_address_t)(uintptr_t)jit, pool, true,
                       VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS)
            return -1;
        if (vm_protect(mach_task_self(), (vm_address_t)w, pool, true,
                       VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
            return -1;
    }
    *execOut = jit;
    *aliasOut = (void *)(uintptr_t)w;
    return 0;
}

// v1: JSC's stock order — lock protections, then write via alias, then execute.
static int v1(void)
{
    void *x, *a;
    if (build_pool(8u << 20, &x, &a, 1)) return 2;
    emit(a, 0x11);
    sys_icache_invalidate(x, PS);
    return ((fn_t)x)() == 0x11 ? 0 : 3;
}

// v2: pre-fault each page through the exec mapping (RW, touch, RX) BEFORE the
// protections are locked down, then write through the alias.
static int v2(void)
{
    void *x, *a;
    if (build_pool(8u << 20, &x, &a, 0)) return 2;
    if (mprotect(x, PS, PROT_READ | PROT_WRITE)) return 4;
    memset(x, 0, PS);
    if (mprotect(x, PS, PROT_READ | PROT_EXEC)) return 5;
    emit(a, 0x22);
    sys_icache_invalidate(x, PS);
    return ((fn_t)x)() == 0x22 ? 0 : 3;
}

// v3: like v2 but the page is also EXECUTED once through its own mapping
// before any alias write, which is what the earlier passing test did.
static int v3(void)
{
    void *x, *a;
    if (build_pool(8u << 20, &x, &a, 0)) return 2;
    if (mprotect(x, PS, PROT_READ | PROT_WRITE)) return 4;
    emit(x, 0x33);
    if (mprotect(x, PS, PROT_READ | PROT_EXEC)) return 5;
    sys_icache_invalidate(x, PS);
    if (((fn_t)x)() != 0x33) return 6;
    emit(a, 0x44);
    sys_icache_invalidate(x, PS);
    return ((fn_t)x)() == 0x44 ? 0 : 3;
}

// v4: v2, but with the protections locked (set_maximum) after the pre-fault,
// which is what JSC would end up doing if commit() pre-faults.
static int v4(void)
{
    void *x, *a;
    if (build_pool(8u << 20, &x, &a, 0)) return 2;
    if (mprotect(x, PS, PROT_READ | PROT_WRITE)) return 4;
    memset(x, 0, PS);
    if (mprotect(x, PS, PROT_READ | PROT_EXEC)) return 5;
    if (vm_protect(mach_task_self(), (vm_address_t)(uintptr_t)a, 8u << 20, true,
                   VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) return 7;
    emit(a, 0x55);
    sys_icache_invalidate(x, PS);
    return ((fn_t)x)() == 0x55 ? 0 : 3;
}

// v5: no alias at all — plain mprotect flip per write, at pool scale.
static int v5(void)
{
    void *x, *a;
    if (build_pool(8u << 20, &x, &a, 0)) return 2;
    for (int i = 0; i < 3; i++) {
        if (mprotect(x, PS, PROT_READ | PROT_WRITE)) return 4;
        emit(x, 0x60 + i);
        if (mprotect(x, PS, PROT_READ | PROT_EXEC)) return 5;
        sys_icache_invalidate(x, PS);
        if (((fn_t)x)() != 0x60 + i) return 3;
    }
    return 0;
}

struct { const char *name; int (*fn)(void); const char *what; } variants[] = {
    { "v1 alias-write only",      v1, "JSC's stock separated-W^X order" },
    { "v2 prefault then alias",   v2, "commit() touches the page through the exec view first" },
    { "v3 execute then alias",    v3, "page executed once through its own mapping first" },
    { "v4 prefault + locked max", v4, "v2 plus vm_protect set_maximum on the alias" },
    { "v5 mprotect flip only",    v5, "no alias; flip RW/RX per write at pool scale" },
};

int main(void)
{
    PS = (size_t)getpagesize();
    setvbuf(stdout, NULL, _IONBF, 0);
    for (unsigned i = 0; i < sizeof variants / sizeof variants[0]; i++) {
        pid_t p = fork();
        if (p == 0) _exit(variants[i].fn());
        int st = 0;
        waitpid(p, &st, 0);
        const char *r;
        char buf[48];
        if (WIFSIGNALED(st)) { snprintf(buf, sizeof buf, "SIGNAL %d", WTERMSIG(st)); r = buf; }
        else if (WEXITSTATUS(st) == 0) r = "WORKS";
        else { snprintf(buf, sizeof buf, "failed at step code %d", WEXITSTATUS(st)); r = buf; }
        printf("%-26s %-14s (%s)\n", variants[i].name, r, variants[i].what);
    }
    return 0;
}
