// fpsample: a frame-pointer stack sampler for one process (iOS arm64, Dopamine rootless).
// spindump is SIGKILLed on this device, so this does the same job by hand:
// task_for_pid, then every INTERVAL_US suspend each thread that is running (plus the main
// thread, always), read its registers, walk the x29 chain, and resume.
//
// usage: fpsample PID SECONDS INTERVAL_US OUT [all|main]
// OUT lines:
//   B <mach_absolute_time at t=0> <numer> <denom>
//   I <load_addr_hex> <path>                     loaded images (from dyld_all_image_infos)
//   N <tidx> <thread_id> <name>                  thread names
//   S <t_us> <tidx> <run_state> <pc> <lr> <ret>...  one stack sample (hex), leaf first
//   T <t_us> <tidx> <user_us> <sys_us>           per-thread CPU at the end
// Build on device: clang -O2 -o fpsample fpsample.c, then sign with an entitlement set that
// has task_for_pid-allow + com.apple.system-task-ports (x11/wayland/iosc-gl-ent.xml works).
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld_images.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern kern_return_t mach_vm_read_overwrite(vm_map_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t,
                                            mach_vm_size_t *);
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);

struct proc_threadinfo {
    uint64_t pth_user_time, pth_system_time;
    int32_t pth_cpu_usage, pth_policy, pth_run_state, pth_flags, pth_sleep_time, pth_curpri, pth_priority,
        pth_maxpriority;
    char pth_name[64];
};
#define PROC_PIDTHREADID64INFO 15

static int rd(task_t t, uint64_t addr, void *buf, size_t n) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(t, addr, n, (mach_vm_address_t)buf, &got) == KERN_SUCCESS && got == n;
}

#define MAXT 256
static uint64_t known_tid[MAXT];
static int nknown;

static int tindex(uint64_t tid, int pid, FILE *out) {
    for (int i = 0; i < nknown; i++)
        if (known_tid[i] == tid) return i;
    if (nknown >= MAXT) return MAXT - 1;
    known_tid[nknown] = tid;
    struct proc_threadinfo pti;
    memset(&pti, 0, sizeof pti);
    proc_pidinfo(pid, PROC_PIDTHREADID64INFO, tid, &pti, sizeof pti);
    fprintf(out, "N %d %llu %s\n", nknown, (unsigned long long)tid, pti.pth_name[0] ? pti.pth_name : "-");
    return nknown++;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: fpsample PID SECONDS INTERVAL_US OUT [all|main]\n");
        return 2;
    }
    int pid = atoi(argv[1]);
    double secs = atof(argv[2]);
    useconds_t iv = (useconds_t)atoi(argv[3]);
    int mainonly = argc > 5 && !strcmp(argv[5], "main");
    FILE *out = fopen(argv[4], "w");
    if (!out) { perror("fopen"); return 1; }
    task_t task;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "task_for_pid: %d %s\n", kr, mach_error_string(kr)); return 1; }

    struct task_dyld_info di;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&di, &cnt) == KERN_SUCCESS) {
        struct dyld_all_image_infos aii;
        if (rd(task, di.all_image_info_addr, &aii, sizeof aii)) {
            size_t n = aii.infoArrayCount;
            struct dyld_image_info *arr = calloc(n, sizeof *arr);
            if (rd(task, (uint64_t)aii.infoArray, arr, n * sizeof *arr)) {
                for (size_t i = 0; i < n; i++) {
                    char path[1024] = {0};
                    for (int k = 0; k < 1023; k += 64) {  // read in small pieces: a long read can cross a page end
                        if (!rd(task, (uint64_t)arr[i].imageFilePath + k, path + k, 64)) break;
                        if (memchr(path + k, 0, 64)) break;
                    }
                    path[1023] = 0;
                    fprintf(out, "I %llx %s\n", (unsigned long long)arr[i].imageLoadAddress, path);
                }
            }
            free(arr);
        }
    }

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t t0 = mach_absolute_time();
    fprintf(out, "B %llu %u %u\n", (unsigned long long)t0, tb.numer, tb.denom);
    uint64_t end = t0 + (uint64_t)(secs * 1e9 * tb.denom / tb.numer);
    uint64_t frames[256];
    long nsamples = 0;
    thread_act_array_t th = NULL;
    mach_msg_type_number_t nth = 0;
    uint64_t lastlist = 0;
    while (mach_absolute_time() < end) {
        uint64_t now = mach_absolute_time();
        if (!th || now - lastlist > 100000000ull * tb.denom / tb.numer) {  // refresh the thread list every 100 ms
            if (th) {
                for (unsigned i = 0; i < nth; i++) mach_port_deallocate(mach_task_self(), th[i]);
                vm_deallocate(mach_task_self(), (vm_address_t)th, nth * sizeof(thread_act_t));
            }
            if (task_threads(task, &th, &nth) != KERN_SUCCESS) break;
            lastlist = now;
        }
        for (unsigned i = 0; i < nth && (!mainonly || i == 0); i++) {
            thread_basic_info_data_t bi;
            mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc) != KERN_SUCCESS) continue;
            if (i != 0 && bi.run_state != TH_STATE_RUNNING) continue;
            thread_identifier_info_data_t ii;
            mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
            if (thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ic) != KERN_SUCCESS) continue;
            int ti = tindex(ii.thread_id, pid, out);
            if (thread_suspend(th[i]) != KERN_SUCCESS) continue;
            arm_thread_state64_t st;
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            int nf = 0;
            uint64_t pc = 0, lr = 0;
            if (thread_get_state(th[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sc) == KERN_SUCCESS) {
                pc = __darwin_arm_thread_state64_get_pc(st);
                lr = __darwin_arm_thread_state64_get_lr(st);
                uint64_t fp = __darwin_arm_thread_state64_get_fp(st);
                while (fp && nf < 256 && !(fp & 7)) {
                    uint64_t fr[2];
                    if (!rd(task, fp, fr, sizeof fr)) break;
                    if (!fr[1]) break;
                    frames[nf++] = fr[1];
                    if (fr[0] <= fp) break;
                    fp = fr[0];
                }
            }
            thread_resume(th[i]);
            uint64_t tus = (mach_absolute_time() - t0) * tb.numer / tb.denom / 1000;
            fprintf(out, "S %llu %d %d %llx %llx", (unsigned long long)tus, ti, bi.run_state,
                    (unsigned long long)pc, (unsigned long long)lr);
            for (int k = 0; k < nf; k++) fprintf(out, " %llx", (unsigned long long)frames[k]);
            fputc('\n', out);
            nsamples++;
        }
        usleep(iv);
    }
    uint64_t tus = (mach_absolute_time() - t0) * tb.numer / tb.denom / 1000;
    if (th) {
        for (unsigned i = 0; i < nth; i++) {
            thread_identifier_info_data_t ii;
            mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
            thread_basic_info_data_t bi;
            mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ic) != KERN_SUCCESS) continue;
            if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &bc) != KERN_SUCCESS) continue;
            int ti = tindex(ii.thread_id, pid, out);
            fprintf(out, "T %llu %d %lld %lld\n", (unsigned long long)tus, ti,
                    (long long)bi.user_time.seconds * 1000000 + bi.user_time.microseconds,
                    (long long)bi.system_time.seconds * 1000000 + bi.system_time.microseconds);
        }
    }
    fclose(out);
    fprintf(stderr, "%ld samples in %.1f s\n", nsamples, tus / 1e6);
    return 0;
}
