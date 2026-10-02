// apps.h - installed-app enumeration and app/URL launching via
// LSApplicationWorkspace (a private ObjC class, resolved by name; no dlsym).
// Daemon-specific: the probe never needed this.
#pragma once

#import <Foundation/Foundation.h>

// User-visible installed apps as @[@{@"bundle_id": ..., @"name": ...}], sorted
// by name. Best effort: excludes hidden and launch-prohibited entries.
NSArray<NSDictionary *> *ipc_apps_list(void);

// Display (localized) name for a bundle id, or nil if unknown.
NSString *ipc_app_name(NSString *bundle_id);

// Launch / foreground an app. Returns NO and fills *err on failure.
bool ipc_app_open(NSString *bundle_id, NSString **err);

// Open a URL in its default handler. Returns NO and fills *err on failure.
bool ipc_url_open(NSString *url, NSString **err);
