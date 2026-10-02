#import "http.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static const NSUInteger kMaxHeaderBytes = 64 * 1024;
static const NSUInteger kMaxBodyBytes = 8 * 1024 * 1024;

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

static void handle_conn(int fd, dispatch_queue_t work, IPCHTTPHandler handler) {
    struct timeval tv = {.tv_sec = 20, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    NSMutableData *buf = [NSMutableData data];
    NSRange sep = {NSNotFound, 0};
    uint8_t chunk[16 * 1024];
    const char term[] = "\r\n\r\n";

    // Read until end of headers.
    while (true) {
        sep = [buf rangeOfData:[NSData dataWithBytes:term length:4] options:0 range:NSMakeRange(0, buf.length)];
        if (sep.location != NSNotFound) break;
        if (buf.length > kMaxHeaderBytes) { close(fd); return; }
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) { close(fd); return; }
        [buf appendBytes:chunk length:(NSUInteger)n];
    }

    NSUInteger headEnd = sep.location;
    NSUInteger bodyStart = sep.location + 4;
    IPCHTTPRequest *req = parse_head([buf subdataWithRange:NSMakeRange(0, headEnd)]);
    if (!req) {
        send_response(fd, [IPCHTTPResponse json:@{@"error" : @{@"code" : @"invalid", @"message" : @"malformed request"}} status:400]);
        close(fd);
        return;
    }

    NSUInteger contentLength = 0;
    NSString *cl = req.headers[@"content-length"];
    if (cl) {
        long long v = cl.longLongValue;
        if (v < 0 || (unsigned long long)v > kMaxBodyBytes) {
            send_response(fd, [IPCHTTPResponse json:@{@"error" : @{@"code" : @"invalid", @"message" : @"body too large"}} status:400]);
            close(fd);
            return;
        }
        contentLength = (NSUInteger)v;
    }

    NSMutableData *body = [[buf subdataWithRange:NSMakeRange(bodyStart, buf.length - bodyStart)] mutableCopy];
    while (body.length < contentLength) {
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n <= 0) break;
        [body appendBytes:chunk length:(NSUInteger)n];
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

bool ipc_http_serve(int port, dispatch_queue_t work, IPCHTTPHandler handler, NSString **err) {
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
    IPCHTTPHandler h = [handler copy];
    dispatch_async(accept_q, ^{
        while (true) {
            int c = accept(fd, NULL, NULL);
            if (c < 0) {
                if (errno == EINTR) continue;
                break;
            }
            dispatch_async(conn_q, ^{
                @autoreleasepool {
                    handle_conn(c, work, h);
                }
            });
        }
    });
    return true;
}
