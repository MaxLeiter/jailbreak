/*
 * sbinject — confine real Ladybird helpers, without rebuilding the engine.
 *
 * sbprobe5 showed that `container` permits everything a renderer needs and denies every
 * write outside the process's container. That was measured on a probe, not on a helper,
 * and "the primitives exist" is not the same claim as "WebContent still renders a page".
 * Closing that gap normally means patching each service's main.cpp and rebuilding Ladybird.
 *
 * This gets the same answer for the cost of one dylib. DYLD_INSERT_LIBRARIES is inherited
 * across the posix_spawn that starts the helpers, so a constructor here runs inside each
 * one. It confines only the processes named in LADYBIRD_SANDBOX_PROCS (default WebContent
 * and ImageDecoder) and leaves the UI process and RequestServer alone -- which is exactly
 * the scope the real patch would have.
 *
 * ORDERING (measured 2026-08-02, the hard way). Confining in a constructor does NOT work:
 *
 *   [status] sandbox=applied process=ImageDecoder profile=container pid=14196
 *   ImageDecoder(14196): Unable to look up service org.ladybird.Ladybird.helper.14189
 *   Runtime error: Permission denied
 *
 * sbprobe5 reported bootstrap_look_up as permitted under `container`, but it looked up
 * com.apple.system.notification_center -- an Apple *system* service. Ladybird looks up
 * org.ladybird.Ladybird.helper.<pid>, a custom service its parent registered. `container`
 * permits the former and denies the latter, so that probe row was a false pass and the
 * confine-after-the-handshake ordering applies here exactly as it does to
 * com.apple.WebKit.WebContent. Rights already held keep working; new lookups do not.
 *
 * So the default is WHEN=after-bootstrap: interpose bootstrap_look_up, let the real one
 * run, and confine immediately after it first succeeds. That is the same place a source
 * patch would confine. WHEN=constructor is kept only to reproduce the failure above.
 *
 * This is a VALIDATION HARNESS, not a shipping mechanism. Shipping it would mean putting
 * DYLD_INSERT_LIBRARIES on a launcher, which is both fragile and a worse security posture
 * than the thing it is testing. The real change is a patch in each helper's own startup.
 *
 * build:  xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.2 \
 *             -dynamiclib -o sbinject.dylib sbinject.c && ldid -S sbinject.dylib
 * use:    DYLD_INSERT_LIBRARIES=/var/jb/tmp/sbinject.dylib ladybird --headless ...
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>

/* servers/bootstrap.h is not in the iOS SDK; declare what we interpose. */
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name,
                                       mach_port_t *sp);

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);
#define SANDBOX_NAMED 0x1ULL

/* getprogname() is unreliable for posix_spawn'd helpers (argv[0] is a full path and the
 * value can be reset); _NSGetExecutablePath is the dependable one on iOS. */
static const char *self_name(char *buf, size_t len)
{
    uint32_t sz = (uint32_t)len;
    if (_NSGetExecutablePath(buf, &sz) != 0)
        return "";
    const char *slash = strrchr(buf, '/');
    return slash ? slash + 1 : buf;
}

static int name_listed(const char *name, const char *list)
{
    size_t n = strlen(name);
    for (const char *p = list; *p; ) {
        const char *comma = strchr(p, ',');
        size_t seg = comma ? (size_t)(comma - p) : strlen(p);
        if (seg == n && strncmp(p, name, n) == 0)
            return 1;
        if (!comma)
            break;
        p = comma + 1;
    }
    return 0;
}

/* Is this process one we were asked to confine? */
static int should_confine(void)
{
    char path[4096];
    const char *name = self_name(path, sizeof(path));
    const char *procs = getenv("LADYBIRD_SANDBOX_PROCS");
    if (!procs || !*procs)
        procs = "WebContent,ImageDecoder";
    return name_listed(name, procs);
}

static void apply_sandbox(const char *when)
{
    static int done = 0;
    if (done)
        return;
    done = 1;

    char path[4096];
    const char *name = self_name(path, sizeof(path));
    const char *profile = getenv("LADYBIRD_SANDBOX_PROFILE");
    if (!profile || !*profile)
        profile = "container";

    char *err = NULL;
    int rc = sandbox_init_with_parameters(profile, SANDBOX_NAMED, NULL, &err);
    /* stderr, not a sidecar file: a confined process cannot write the sidecar, and fd 2 is
     * inherited and always works. Tagged with process= because the helpers share stderr. */
    fprintf(stderr, "[status] sandbox=%s process=%s profile=%s when=%s pid=%d%s%s\n",
            rc == 0 ? "applied" : "FAILED", name, profile, when, getpid(),
            err ? " err=" : "", err ? err : "");
    fflush(stderr);
}

/* Interposed bootstrap_look_up: run the real one, then confine once it has succeeded.
 * Calls to bootstrap_look_up from inside this library are not themselves interposed, so
 * this recurses no further than the real implementation. */
static kern_return_t sbinject_bootstrap_look_up(mach_port_t bp, const char *name,
                                                mach_port_t *sp)
{
    kern_return_t kr = bootstrap_look_up(bp, name, sp);
    if (kr == KERN_SUCCESS && should_confine())
        apply_sandbox("after-bootstrap");
    return kr;
}

__attribute__((used)) static const struct {
    const void *replacement;
    const void *original;
} sbinject_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)sbinject_bootstrap_look_up, (const void *)bootstrap_look_up },
};

__attribute__((constructor))
static void sbinject_init(void)
{
    const char *when = getenv("LADYBIRD_SANDBOX_WHEN");
    if (!when || !*when)
        when = "after-bootstrap";
    /* after-bootstrap is handled by the interposer above; nothing to do here. */
    if (strcmp(when, "constructor") == 0 && should_confine())
        apply_sandbox("constructor");
}
