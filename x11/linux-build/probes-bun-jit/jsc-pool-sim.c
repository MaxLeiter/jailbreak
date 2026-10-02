// Replays JSC initializeJITPageReservation() + initializeSeparatedWXHeaps()
// against the real device, at the real pool size, before we spend hours
// building it for real.
//
//   1. mmap the whole executable pool RWX (what PageReservation does on Darwin)
//   2. mach_vm_remap a second view of it
//   3. vm_protect the original view down to RX, maximum included
//   4. vm_protect the alias to RW, maximum included
//   5. write code through the alias, execute it through the RX view
#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>

typedef uint64_t mvm_addr_t;
typedef uint64_t mvm_size_t;
extern kern_return_t mach_vm_remap(vm_map_t, mvm_addr_t *, mvm_size_t, mvm_addr_t,
                                   int, vm_map_t, mvm_addr_t, boolean_t,
                                   vm_prot_t *, vm_prot_t *, vm_inherit_t);

#define VM_FLAGS_ANYWHERE_ 0x0001

typedef int (*fn_t)(void);

static void emit(void *p, unsigned imm)
{
    uint32_t code[2] = { 0x52800000u | ((imm & 0xffffu) << 5), 0xd65f03c0u };
    memcpy(p, code, sizeof code);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0); // a SIGBUS must not eat the step log

    // JSC's fixedExecutableMemoryPoolSize for ARM64.
    const size_t POOL = 128u * 1024u * 1024u;
    const size_t PS = (size_t)getpagesize();

    void *jit = mmap(NULL, POOL, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANON, -1, 0);
    if (jit == MAP_FAILED) {
        printf("FAIL  step 1: mmap %zu MB RWX: %s\n", POOL >> 20, strerror(errno));
        return 1;
    }
    printf("PASS  step 1: reserved %zu MB RWX at %p\n", POOL >> 20, jit);

    mvm_addr_t writable = 0;
    vm_prot_t cur = 0, max = 0;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &writable, POOL, 0,
                                     VM_FLAGS_ANYWHERE_, mach_task_self(),
                                     (mvm_addr_t)(uintptr_t)jit, FALSE,
                                     &cur, &max, VM_INHERIT_DEFAULT);
    if (kr != KERN_SUCCESS) {
        printf("FAIL  step 2: mach_vm_remap %zu MB: kr=%d (%s)\n", POOL >> 20, kr, mach_error_string(kr));
        return 1;
    }
    printf("PASS  step 2: writable alias of the whole pool at %#llx (cur=%#x max=%#x)\n",
           (unsigned long long)writable, cur, max);

    kern_return_t r1 = vm_protect(mach_task_self(), (vm_address_t)(uintptr_t)jit, POOL,
                                  /*set_maximum=*/true, VM_PROT_READ | VM_PROT_EXECUTE);
    if (r1 != KERN_SUCCESS) {
        printf("FAIL  step 3: vm_protect exec view -> RX (max too): kr=%d (%s)\n", r1, mach_error_string(r1));
        return 1;
    }
    printf("PASS  step 3: exec view locked to RX\n");

    kern_return_t r2 = vm_protect(mach_task_self(), (vm_address_t)writable, POOL,
                                  /*set_maximum=*/true, VM_PROT_READ | VM_PROT_WRITE);
    if (r2 != KERN_SUCCESS) {
        printf("FAIL  step 4: vm_protect alias -> RW (max too): kr=%d (%s)\n", r2, mach_error_string(r2));
        return 1;
    }
    printf("PASS  step 4: alias locked to RW (no execute)\n");

    // Write at a few offsets the way JSC scatters code across the pool.
    int bad = 0;
    size_t offsets[] = { 0, PS, 4u * 1024 * 1024, 64u * 1024 * 1024, POOL - PS };
    for (unsigned i = 0; i < sizeof offsets / sizeof offsets[0]; i++) {
        void *w = (char *)(uintptr_t)writable + offsets[i];
        void *x = (char *)jit + offsets[i];
        emit(w, 0x300 + i);
        sys_icache_invalidate(x, PS);
        int got = ((fn_t)x)();
        if (got != (int)(0x300 + i)) {
            printf("FAIL  step 5: offset %#zx executed %#x, wanted %#x\n", offsets[i], got, 0x300 + i);
            bad++;
        }
    }
    if (!bad)
        printf("PASS  step 5: wrote via alias and executed via RX view at 5 offsets\n");

    // JSC repatches the same code over and over; make sure the alias stays live.
    for (unsigned i = 0; i < 1000; i++) {
        emit((void *)(uintptr_t)writable, 0x500 + (i & 0xff));
        sys_icache_invalidate(jit, PS);
        if (((fn_t)jit)() != (int)(0x500 + (i & 0xff))) {
            printf("FAIL  step 6: repatch %u not observed through the RX view\n", i);
            bad++;
            break;
        }
    }
    if (!bad)
        printf("PASS  step 6: 1000 alias repatches all observed by the RX view\n");

    printf("== %s\n", bad ? "PROBLEMS" : "JSC separated-W^X model works on this device");
    return bad ? 1 : 0;
}
