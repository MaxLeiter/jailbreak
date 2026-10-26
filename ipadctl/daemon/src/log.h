// log.h - append-only action log. One line per executed action. For `type`
// only the text length is recorded, never the text. Screenshots are never
// written to disk.
#pragma once

#import <Foundation/Foundation.h>

void ipc_log_open(NSString *path);

// detail: coords / keys / "chars=N" etc. Any field may be nil.
void ipc_log_action(NSString *type, NSString *detail, NSString *app,
                    NSString *target, NSString *why, NSString *result);

// Free-form daemon note (startup, selftest, errors).
void ipc_log_note(NSString *message);
