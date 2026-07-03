#ifndef TM_PROC_INFO_H
#define TM_PROC_INFO_H

// Process introspection ABI for libproc / sysctl / mach, shared by the app's
// bridging header and the standalone spike CLI. No UIKit here — this is the
// pure syscall surface, so a non-UIKit context (the spike, a macOS indexing
// pass) can import it without dragging in the app frameworks.
//
// The iOS SDK ships neither <libproc.h> nor <sys/proc_info.h> (macOS-only), so
// on iOS we declare the exact Darwin ABI ourselves. Where the real headers DO
// exist (macOS — the spike CLI or a SourceKit indexing pass), we include them
// instead so the struct/prototype declarations can't collide ("redefinition").

#import <sys/types.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <stdint.h>

#if __has_include(<sys/proc_info.h>)

// Real Darwin headers are available — use them.
#import <libproc.h>
#import <sys/proc_info.h>

#else

// iOS: the headers are absent but the symbols live in libSystem. Declare the
// exact ABI (copied from the macOS SDK; identical across Darwin platforms).
#ifndef MAXCOMLEN
#define MAXCOMLEN 16
#endif
#define PROC_PIDTASKALLINFO 2
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)

struct proc_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t  pti_policy;
    int32_t  pti_faults;
    int32_t  pti_pageins;
    int32_t  pti_cow_faults;
    int32_t  pti_messages_sent;
    int32_t  pti_messages_received;
    int32_t  pti_syscalls_mach;
    int32_t  pti_syscalls_unix;
    int32_t  pti_csw;
    int32_t  pti_threadnum;
    int32_t  pti_numrunning;
    int32_t  pti_priority;
};

struct proc_bsdinfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uid_t    pbi_uid;
    gid_t    pbi_gid;
    uid_t    pbi_ruid;
    gid_t    pbi_rgid;
    uid_t    pbi_svuid;
    gid_t    pbi_svgid;
    uint32_t rfu_1;
    char     pbi_comm[MAXCOMLEN];
    char     pbi_name[2 * MAXCOMLEN];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t e_tdev;
    uint32_t e_tpgid;
    int32_t  pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
};

struct proc_taskallinfo {
    struct proc_bsdinfo  pbsd;
    struct proc_taskinfo ptinfo;
};

// Resolved from libSystem at load.
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#endif  // __has_include(<sys/proc_info.h>)

#endif  // TM_PROC_INFO_H
