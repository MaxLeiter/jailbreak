// server.h - routes the HTTP API (API.md) onto the native core: info, apps,
// screenshot, actions. All handlers run on the serial work queue.
#pragma once

#import <Foundation/Foundation.h>
#import "http.h"

#define IPC_DAEMON_VERSION "0.2"

// Build the request handler. `token` is the bearer token required on every
// request (constant-time compared).
IPCHTTPHandler ipc_server_handler(NSString *token);

// The bearer-token check the HTTP layer runs before reading a request body.
// Thread-safe (the token is immutable).
IPCHTTPAuthorizer ipc_server_authorizer(NSString *token);

// Capture self-test: did we get a non-black frame while the screen is on?
// Used at startup and by GET /v1/info. Returns the `selftest` object.
NSDictionary *ipc_selftest(void);
