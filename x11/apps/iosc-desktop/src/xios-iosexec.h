#ifndef XIOS_IOSEXEC_H
#define XIOS_IOSEXEC_H

/*
 * ioscd's exec calls go through Procursus libiosexec (package libiosexec1,
 * part of every Procursus bootstrap).
 *
 * On a rootless jailbreak there is no /bin/sh; it is <prefix>/bin/sh. The
 * kernel resolves a script's "#!/bin/sh" literally, so a plain execve of a
 * shell-script Exec target (crispy-doom, openttd, imv, systemsettings, ...)
 * fails with ENOENT and the child dies with 127. libiosexec's exec entry
 * points read the shebang and run /bin and /usr/bin interpreters from the
 * prefix instead (rootless build: SHEBANG_REDIRECT_PATH=/var/jb,
 * LIBIOSEXEC_PREFIXED_ROOT=1, DEFAULT_INTERPRETER=/var/jb/bin/sh). A Mach-O
 * target goes straight to execve, exactly as before. The argv is passed
 * through untouched: no shell is inserted for the command line, only the
 * script's own interpreter is resolved, as the kernel would.
 *
 * Procursus links every package with -liosexec and prepends <libiosexec.h>
 * to the staged SDK's unistd/pwd/grp/spawn headers, which renames exec*,
 * posix_spawn*, system AND the getpw and getgr families to ie_*. ioscd is
 * built with the stock SDK, so it takes only the exec entry points,
 * explicitly. Passwd and group lookups (drop_to_mobile, socket ownership)
 * stay on the system's libinfo rather than libiosexec's <prefix>/etc
 * databases.
 *
 * Weak-linked against the ../sdk/libiosexec.tbd stub: if the dylib cannot
 * load, ioscd still starts and these fall back to the libc calls (the old
 * behavior; ioscd logs it at startup).
 */
#include <unistd.h>

extern int ie_execl(const char *path, const char *arg0, ...) __attribute__((weak_import));
extern int ie_execv(const char *path, char *const argv[]) __attribute__((weak_import));
extern int ie_execvp(const char *file, char *const argv[]) __attribute__((weak_import));

#define xios_execl(...)   (ie_execl ? ie_execl(__VA_ARGS__) : execl(__VA_ARGS__))
#define xios_execv(p, a)  (ie_execv ? ie_execv((p), (a)) : execv((p), (a)))
#define xios_execvp(f, a) (ie_execvp ? ie_execvp((f), (a)) : execvp((f), (a)))

static inline int xios_have_iosexec(void)
{
    return ie_execl != NULL && ie_execv != NULL && ie_execvp != NULL;
}

#endif
