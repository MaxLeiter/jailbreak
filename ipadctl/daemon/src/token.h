// token.h - the daemon's bearer token: load from disk, or generate on first
// start. Stored at <dir>/token, mode 0600.
#pragma once

#import <Foundation/Foundation.h>

// Returns the token (creating and persisting one on first start), or nil with
// *err set. Ensures <dir> exists (0700).
NSString *ipc_token_load_or_create(NSString *dir, NSString **err);

// Constant-time string compare (no early-out on length or content).
bool ipc_ct_equal(NSString *a, NSString *b);
