// server.h - routes the HTTP API (API.md) onto the native core: info, apps,
// screenshot, actions. All handlers run on the serial work queue.
#pragma once

#import <Foundation/Foundation.h>
#import "http.h"

#define IPC_DAEMON_VERSION "0.1"

// Build the request handler. `token` is the bearer token required on every
// request (constant-time compared).
IPCHTTPHandler ipc_server_handler(NSString *token);

// Capture self-test: did we get a non-black frame while the screen is on?
// Used at startup and by GET /v1/info. Returns the `selftest` object.
NSDictionary *ipc_selftest(void);
