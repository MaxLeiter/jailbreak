// http.h - a tiny, dependency-free HTTP/1.1 server on POSIX sockets.
//
// One dual-stack (IPv4 + IPv6) listening socket on all interfaces. Each
// connection is read on a concurrent queue; the handler runs via
// dispatch_sync on `work`, so handlers never execute concurrently (the
// contract's one-action-at-a-time rule). Connection: close per response.
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

// Starts listening. Returns false (with *err) if the socket could not be set
// up. The accept loop runs on its own queue; this returns immediately.
bool ipc_http_serve(int port, dispatch_queue_t work, IPCHTTPHandler handler, NSString **err);
