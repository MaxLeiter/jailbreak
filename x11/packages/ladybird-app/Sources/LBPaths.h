// LBPaths.h - jailbreak-scheme-neutral runtime paths for the standalone app.
#pragma once

#include <stdio.h>
#include <unistd.h>

static inline int lb_is_rootless_install(void)
{
    // Key off the app bundle rather than /var/jb itself: a rootful bootstrap may
    // carry a compatibility /var/jb directory, but only the rootless package
    // installs this bundle there.
    return access("/var/jb/Applications/Ladybird.app", F_OK) == 0;
}

static inline char const* lb_runtime_tmp(void)
{
    return lb_is_rootless_install() ? "/var/jb/tmp" : "/tmp";
}

static inline void lb_runtime_path(char* buffer, size_t size, char const* leaf)
{
    snprintf(buffer, size, "%s/%s", lb_runtime_tmp(), leaf);
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>

static inline NSString* lb_runtime_tmp_ns(void)
{
    return [NSString stringWithUTF8String:lb_runtime_tmp()];
}

static inline NSString* lb_runtime_path_ns(NSString* leaf)
{
    return [lb_runtime_tmp_ns() stringByAppendingPathComponent:leaf];
}
#endif
