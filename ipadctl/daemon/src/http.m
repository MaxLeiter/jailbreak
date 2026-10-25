#import "http.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>

static const NSUInteger kMaxHeaderBytes = 64 * 1024;
// The largest legitimate body is a 20-action batch with 4000-char `type` texts.
static const NSUInteger kMaxBodyBytes = 1024 * 1024;

@implementation IPCHTTPRequest
- (NSString *)header:(NSString *)name {
    return self.headers[name];
}
@end

@implementation IPCHTTPResponse
+ (instancetype)json:(id)object status:(int)status {
    IPCHTTPResponse *r = [self new];
    r.status = status;
    r.contentType = @"application/json; charset=utf-8";
    NSData *d = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    r.body = d ?: [NSData data];
    return r;
}
+ (instancetype)jpeg:(NSData *)data headers:(NSDictionary *)headers {
    IPCHTTPResponse *r = [self new];
    r.status = 200;
    r.contentType = @"image/jpeg";
    r.extraHeaders = headers;
    r.body = data;
    return r;
}
@end

static const char *reason(int status) {
    switch (status) {
    case 200: return "OK";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 500: return "Internal Server Error";
    default: return "OK";
    }
}

static bool write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += n;
        len -= (size_t)n;
    }
    return true;
}

static void send_response(int fd, IPCHTTPResponse *resp) {
    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"HTTP/1.1 %d %s\r\n", resp.status, reason(resp.status)];
    [head appendFormat:@"Content-Type: %@\r\n", resp.contentType ?: @"application/json; charset=utf-8"];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)resp.body.length];
    [head appendString:@"Connection: close\r\n"];
    [resp.extraHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [head appendFormat:@"%@: %@\r\n", k, v];
    }];
    [head appendString:@"\r\n"];
    NSData *hd = [head dataUsingEncoding:NSUTF8StringEncoding];
    if (!write_all(fd, hd.bytes, hd.length)) return;
    if (resp.body.length) write_all(fd, resp.body.bytes, resp.body.length);
}

// Parse the header block (everything before the blank line). Returns nil on
// malformed input.
static IPCHTTPRequest *parse_head(NSData *headData) {
    NSString *text = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\r\n"];
    if (lines.count < 1) return nil;
    NSArray<NSString *> *reqline = [lines[0] componentsSeparatedByString:@" "];
    if (reqline.count < 2) return nil;

    IPCHTTPRequest *req = [IPCHTTPRequest new];
    req.method = reqline[0];
    NSString *target = reqline[1];
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        req.path = [target substringToIndex:q.location];
        req.query = [target substringFromIndex:q.location + 1];
    } else {
        req.path = target;
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        if (line.length == 0) continue;
        NSRange c = [line rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:c.location] lowercaseString];
        NSString *v = [[line substringFromIndex:c.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        headers[k] = v;
    }
    req.headers = headers;
    return req;
}

// Whole-request deadline. SO_RCVTIMEO bounds each read(); this bounds the
// sum, so a client trickling one byte per timeout cannot hold a slot forever.
static const double kRequestDeadlineSec = 15;
// Concurrent connections. Excess connections are closed immediately rather
// than each pinning a GCD worker thread and up to kMaxBodyBytes of memory.
static const long kMaxConnections = 8;

static double mono_sec(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e9;
}

static void send_error(int fd, int status, NSString *code, NSString *message) {
    send_response(fd, [IPCHTTPResponse json:@{@"error" : @{@"code" : code, @"message" : message}} status:status]);
}

static void handle_conn(int fd, dispatch_queue_t work, IPCHTTPAuthorizer authorize, IPCHTTPHandler handler) {
    struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct timeval stv = {.tv_sec = 20, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, sizeof(stv));
    // A client that hangs up before the response (for example the MCP side
    // timing out during a long batch) must not SIGPIPE the daemon.
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    const double deadline = mono_sec() + kRequestDeadlineSec;
    NSMutableData *buf = [NSMutableData data];
    NSRange sep = {NSNotFound, 0};
    uint8_t chunk[16 * 1024];
    NSData *term = [NSData dataWithBytes:"\r\n\r\n" length:4];

    // Read until end of headers.
    while (true) {
        // Only rescan the tail that could contain a new terminator.
        NSUInteger from = buf.length > 3 + sizeof(chunk) ? buf.length - 3 - sizeof(chunk) : 0;
        sep = [buf rangeOfData:term options:0 range:NSMakeRange(from, buf.length - from)];
        if (sep.location != NSNotFound) break;
        if (buf.length > kMaxHeaderBytes || mono_sec() > deadline) { close(fd); return; }
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return; }
        [buf appendBytes:chunk length:(NSUInteger)n];
    }

    NSUInteger headEnd = sep.location;
    NSUInteger bodyStart = sep.location + 4;
    IPCHTTPRequest *req = parse_head([buf subdataWithRange:NSMakeRange(0, headEnd)]);
    if (!req) {
        send_error(fd, 400, @"invalid", @"malformed request");
        close(fd);
        return;
    }

    // Authenticate before reading the body or touching the work queue.
    if (!authorize(req)) {
        send_error(fd, 401, @"unauthorized", @"missing or invalid bearer token");
        close(fd);
        return;
    }

    NSUInteger contentLength = 0;
    NSString *cl = req.headers[@"content-length"];
    if (cl) {
        long long v = cl.longLongValue;
        if (v < 0 || (unsigned long long)v > kMaxBodyBytes) {
            send_error(fd, 400, @"invalid", @"body too large");
            close(fd);
            return;
        }
        contentLength = (NSUInteger)v;
    }

    NSMutableData *body = [[buf subdataWithRange:NSMakeRange(bodyStart, buf.length - bodyStart)] mutableCopy];
    while (body.length < contentLength) {
        if (mono_sec() > deadline) break;
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        [body appendBytes:chunk length:(NSUInteger)n];
    }
    if (body.length < contentLength) {
        // Never hand a truncated body to the handler.
        send_error(fd, 400, @"invalid", @"request body incomplete");
        close(fd);
        return;
    }
    if (body.length > contentLength) body.length = contentLength;
    req.body = body;

    __block IPCHTTPResponse *resp = nil;
    dispatch_sync(work, ^{
        @try {
            resp = handler(req);
        } @catch (id e) {
            resp = [IPCHTTPResponse json:@{@"error" : @{@"code" : @"internal", @"message" : [NSString stringWithFormat:@"%@", e]}} status:500];
        }
    });
    if (!resp) resp = [IPCHTTPResponse json:@{@"error" : @{@"code" : @"internal", @"message" : @"no response"}} status:500];
    send_response(fd, resp);
    close(fd);
}

bool ipc_http_serve(int port, dispatch_queue_t work, IPCHTTPAuthorizer authorize, IPCHTTPHandler handler,
                    NSString **err) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { if (err) *err = [NSString stringWithFormat:@"socket: %s", strerror(errno)]; return false; }

    int yes = 1, no = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));  // accept IPv4 and IPv6

    struct sockaddr_in6 addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons((uint16_t)port);
    addr.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (err) *err = [NSString stringWithFormat:@"bind :%d: %s", port, strerror(errno)];
        close(fd);
        return false;
    }
    if (listen(fd, 32) < 0) {
        if (err) *err = [NSString stringWithFormat:@"listen: %s", strerror(errno)];
        close(fd);
        return false;
    }

    dispatch_queue_t accept_q = dispatch_queue_create("com.max.ipadctld.accept", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t conn_q = dispatch_queue_create("com.max.ipadctld.conn", DISPATCH_QUEUE_CONCURRENT);
    dispatch_semaphore_t slots = dispatch_semaphore_create(kMaxConnections);
    IPCHTTPHandler h = [handler copy];
    IPCHTTPAuthorizer auth = [authorize copy];
    dispatch_async(accept_q, ^{
        while (true) {
            int c = accept(fd, NULL, NULL);
            if (c < 0) {
                // Never let one failed accept (ECONNABORTED, EMFILE, ...)
                // end the loop: the process would stay up but stop serving,
                // and launchd's KeepAlive would never notice.
                if (errno != EINTR && errno != ECONNABORTED) usleep(100 * 1000);
                continue;
            }
            if (dispatch_semaphore_wait(slots, DISPATCH_TIME_NOW) != 0) {
                close(c);  // at capacity
                continue;
            }
            dispatch_async(conn_q, ^{
                @autoreleasepool {
                    handle_conn(c, work, auth, h);
                }
                dispatch_semaphore_signal(slots);
            });
        }
    });
    return true;
}
