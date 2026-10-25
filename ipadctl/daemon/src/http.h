// http.h - a tiny, dependency-free HTTP/1.1 server on POSIX sockets.
//
// One dual-stack (IPv4 + IPv6) listening socket on all interfaces. Each
// connection is read on a concurrent queue; the handler runs via
// dispatch_sync on `work`, so handlers never execute concurrently (the
// contract's one-action-at-a-time rule). Connection: close per response.
//
// `authorize` runs on the connection's own thread right after the header
// block is parsed, BEFORE any body is read or the work queue is touched, so an
// unauthenticated client can neither make the daemon buffer a body nor queue
// behind (or stall) the serial work queue. It must be thread-safe.
#pragma once

#import <Foundation/Foundation.h>

@interface IPCHTTPRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;    // path only, query stripped
@property (nonatomic, copy) NSString *query;   // raw query or nil
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *headers;  // lowercased keys
@property (nonatomic, strong) NSData *body;
- (NSString *)header:(NSString *)name;  // name is lowercased by caller convention
@end

@interface IPCHTTPResponse : NSObject
@property (nonatomic) int status;
@property (nonatomic, copy) NSString *contentType;  // default application/json; charset=utf-8
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *extraHeaders;
@property (nonatomic, strong) NSData *body;
+ (instancetype)json:(id)object status:(int)status;        // NSJSONSerialization
+ (instancetype)jpeg:(NSData *)data headers:(NSDictionary *)headers;
@end

typedef IPCHTTPResponse *(^IPCHTTPHandler)(IPCHTTPRequest *req);
typedef bool (^IPCHTTPAuthorizer)(IPCHTTPRequest *req);

// Starts listening. Returns false (with *err) if the socket could not be set
// up. The accept loop runs on its own queue; this returns immediately.
bool ipc_http_serve(int port, dispatch_queue_t work, IPCHTTPAuthorizer authorize, IPCHTTPHandler handler,
                    NSString **err);
