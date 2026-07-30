#import "../apps/shared/XiosMetalEventBroker.h"

#import <dispatch/dispatch.h>
#import <objc/message.h>

#include <stdio.h>

static const NSUInteger kMaximumPendingHandles = 256;

@interface XiosMetalEventEntry : NSObject {
    MTLSharedEventHandle *_handle;
}
@property(nonatomic, retain) MTLSharedEventHandle *handle;
@end

@implementation XiosMetalEventEntry
@synthesize handle = _handle;
- (void)dealloc
{
    [_handle release];
    [super dealloc];
}
@end

@interface XiosMetalEventService : NSObject {
    NSMutableDictionary *_entries;
}
- (BOOL)storeHandle:(MTLSharedEventHandle *)handle token:(NSData *)token;
- (MTLSharedEventHandle *)handleForToken:(NSData *)token;
- (void)removeTokens:(NSSet *)tokens;
@end

@implementation XiosMetalEventService

- (instancetype)init
{
    if ((self = [super init]))
        _entries = [[NSMutableDictionary alloc] init];
    return self;
}

- (void)dealloc
{
    [_entries release];
    [super dealloc];
}

- (BOOL)storeHandle:(MTLSharedEventHandle *)handle token:(NSData *)token
{
    BOOL stored = NO;
    @synchronized(self) {
        if ([handle isKindOfClass:[MTLSharedEventHandle class]] &&
            [token isKindOfClass:[NSData class]] &&
            token.length == XIOS_GPU_FENCE_TOKEN_SIZE &&
            ![_entries objectForKey:token] &&
            _entries.count < kMaximumPendingHandles) {
            XiosMetalEventEntry *entry = [[XiosMetalEventEntry alloc] init];
            entry.handle = handle;
            [_entries setObject:entry forKey:token];
            [entry release];
            stored = YES;
        }
    }
    return stored;
}

- (MTLSharedEventHandle *)handleForToken:(NSData *)token
{
    MTLSharedEventHandle *handle = nil;
    @synchronized(self) {
        if ([token isKindOfClass:[NSData class]] &&
            token.length == XIOS_GPU_FENCE_TOKEN_SIZE) {
            XiosMetalEventEntry *entry = [_entries objectForKey:token];
            handle = [[entry.handle retain] autorelease];
        }
    }
    return handle;
}

- (void)removeTokens:(NSSet *)tokens
{
    @synchronized(self) {
        [_entries removeObjectsForKeys:[tokens allObjects]];
    }
}
@end

/* One exported endpoint per producer/consumer connection. Tokens published
 * through it remain fetchable across Xios reconnects, then are revoked when the
 * publishing process's retained XPC connection invalidates. */
@interface XiosMetalEventConnection : NSObject <XiosMetalEventBrokerProtocol> {
    XiosMetalEventService *_service;
    NSMutableSet *_publishedTokens;
}
@property(nonatomic, retain) XiosMetalEventService *service;
- (void)revokePublishedTokens;
@end

@implementation XiosMetalEventConnection
@synthesize service = _service;

- (instancetype)init
{
    if ((self = [super init]))
        _publishedTokens = [[NSMutableSet alloc] init];
    return self;
}

- (void)publishHandle:(MTLSharedEventHandle *)handle
                token:(NSData *)token
            withReply:(void (^)(BOOL))reply
{
    BOOL stored = [self.service storeHandle:handle token:token];
    if (stored) {
        @synchronized(self) {
            [_publishedTokens addObject:token];
        }
    }
    reply(stored);
}

- (void)copyHandleForToken:(NSData *)token
                 withReply:(void (^)(MTLSharedEventHandle *))reply
{
    reply([self.service handleForToken:token]);
}

- (void)revokePublishedTokens
{
    NSSet *tokens;
    @synchronized(self) {
        tokens = [[_publishedTokens copy] autorelease];
        [_publishedTokens removeAllObjects];
    }
    [self.service removeTokens:tokens];
}

- (void)dealloc
{
    [self revokePublishedTokens];
    [_service release];
    [_publishedTokens release];
    [super dealloc];
}
@end

@interface XiosMetalEventListenerDelegate : NSObject <NSXPCListenerDelegate> {
    XiosMetalEventService *_service;
}
@property(nonatomic, retain) XiosMetalEventService *service;
@end

@implementation XiosMetalEventListenerDelegate
@synthesize service = _service;

- (BOOL)listener:(NSXPCListener *)listener
        shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    (void)listener;
    NSXPCInterface *interface =
        [NSXPCInterface interfaceWithProtocol:@protocol(XiosMetalEventBrokerProtocol)];
    NSSet *handleClasses = [NSSet setWithObject:[MTLSharedEventHandle class]];
    [interface setClasses:handleClasses
              forSelector:@selector(publishHandle:token:withReply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:handleClasses
              forSelector:@selector(copyHandleForToken:withReply:)
            argumentIndex:0
                  ofReply:YES];
    XiosMetalEventConnection *endpoint =
        [[[XiosMetalEventConnection alloc] init] autorelease];
    endpoint.service = self.service;
    connection.exportedInterface = interface;
    connection.exportedObject = endpoint;
    connection.invalidationHandler = ^{
        [endpoint revokePublishedTokens];
    };
    [connection resume];
    return YES;
}

- (void)dealloc
{
    [_service release];
    [super dealloc];
}
@end

int main(void)
{
    @autoreleasepool {
        Class cls = NSClassFromString(@"NSXPCListener");
        SEL initSelector = NSSelectorFromString(@"initWithMachServiceName:");
        if (!cls || ![cls instancesRespondToSelector:initSelector]) {
            fprintf(stderr,
                    "xios-metal-event-broker: named NSXPC listener unavailable\n");
            return 1;
        }

        typedef id (*NamedListenerInit)(id, SEL, NSString *);
        NSXPCListener *listener =
            ((NamedListenerInit)objc_msgSend)(
                [cls alloc], initSelector, @XIOS_METAL_EVENT_BROKER_SERVICE);
        if (!listener) {
            fprintf(stderr,
                    "xios-metal-event-broker: failed to create named listener\n");
            return 1;
        }

        XiosMetalEventService *service = [[XiosMetalEventService alloc] init];
        XiosMetalEventListenerDelegate *delegate =
            [[XiosMetalEventListenerDelegate alloc] init];
        delegate.service = service;
        listener.delegate = delegate;
        [listener resume];
        fprintf(stderr, "xios-metal-event-broker: listening on %s\n",
                XIOS_METAL_EVENT_BROKER_SERVICE);
        dispatch_main();
    }
    return 0;
}
