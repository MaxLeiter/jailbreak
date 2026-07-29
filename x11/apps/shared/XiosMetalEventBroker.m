#import "XiosMetalEventBroker.h"

#import <objc/message.h>
#import <stdlib.h>
#import <stdio.h>

/*
 * Named NSXPC Mach-service initializers are present on the jailbroken iPadOS
 * target but annotated unavailable in the iOS SDK. Keep the one runtime call
 * isolated here, require the selector to exist, and otherwise fail cleanly so
 * production callers can refuse unfenced presentation.
 */
static NSXPCConnection *xios_broker_connection(void)
{
    Class cls = NSClassFromString(@"NSXPCConnection");
    SEL initSelector = NSSelectorFromString(@"initWithMachServiceName:options:");
    if (!cls || ![cls instancesRespondToSelector:initSelector])
        return nil;

    typedef id (*NamedConnectionInit)(id, SEL, NSString *, NSUInteger);
    NSXPCConnection *connection =
        ((NamedConnectionInit)objc_msgSend)(
            [cls alloc], initSelector,
            @XIOS_METAL_EVENT_BROKER_SERVICE,
            (NSUInteger)NSXPCConnectionPrivileged);
    if (!connection)
        return nil;

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
    connection.remoteObjectInterface = interface;
    [connection resume];
    return connection;
}

static id<XiosMetalEventBrokerProtocol>
xios_broker_proxy(NSXPCConnection *connection, BOOL *failed)
{
    return [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError *error) {
        if (failed)
            *failed = YES;
        fprintf(stderr, "xios-metal-broker: XPC request failed: %s\n",
                error.localizedDescription.UTF8String);
    }];
}

static void xios_broker_retain_publisher(NSXPCConnection *connection)
{
    static NSMutableArray *publishers;
    @synchronized([NSXPCConnection class]) {
        if (!publishers)
            publishers = [[NSMutableArray alloc] init];
        [publishers addObject:connection];
    }
}

int xios_metal_event_broker_publish(
    MTLSharedEventHandle *handle,
    unsigned char token[XIOS_METAL_EVENT_TOKEN_SIZE])
{
    if (!handle || !token)
        return 0;

    @autoreleasepool {
        for (int attempt = 0; attempt < 4; attempt++) {
            arc4random_buf(token, XIOS_METAL_EVENT_TOKEN_SIZE);
            NSData *tokenData =
                [NSData dataWithBytes:token length:XIOS_METAL_EVENT_TOKEN_SIZE];
            NSXPCConnection *connection = xios_broker_connection();
            if (!connection)
                return 0;

            __block BOOL failed = NO;
            __block BOOL stored = NO;
            @try {
                id<XiosMetalEventBrokerProtocol> proxy =
                    xios_broker_proxy(connection, &failed);
                [proxy publishHandle:handle token:tokenData
                          withReply:^(BOOL value) { stored = value; }];
            } @catch (NSException *exception) {
                failed = YES;
                fprintf(stderr, "xios-metal-broker: publish exception: %s\n",
                        exception.reason.UTF8String);
            }
            if (!failed && stored) {
                /* Keep the publisher connection alive for the event's process
                 * lifetime. The service revokes its tokens on invalidation. */
                xios_broker_retain_publisher(connection);
                [connection release];
                return 1;
            }
            [connection invalidate];
            [connection release];
            if (failed)
                return 0;
            /* A non-error rejection is only expected for an astronomically
             * unlikely token collision; generate a new capability and retry. */
        }
    }
    return 0;
}

id<MTLSharedEvent> xios_metal_event_broker_copy_event(
    id<MTLDevice> device, const void *token, size_t token_size)
{
    if (!device || !token || token_size != XIOS_METAL_EVENT_TOKEN_SIZE)
        return nil;

    @autoreleasepool {
        NSData *tokenData = [NSData dataWithBytes:token length:token_size];
        NSXPCConnection *connection = xios_broker_connection();
        if (!connection)
            return nil;

        __block BOOL failed = NO;
        __block MTLSharedEventHandle *handle = nil;
        @try {
            id<XiosMetalEventBrokerProtocol> proxy =
                xios_broker_proxy(connection, &failed);
            [proxy copyHandleForToken:tokenData
                           withReply:^(MTLSharedEventHandle *value) {
                               handle = [value retain];
                           }];
        } @catch (NSException *exception) {
            failed = YES;
            fprintf(stderr, "xios-metal-broker: take exception: %s\n",
                    exception.reason.UTF8String);
        }
        [connection invalidate];
        [connection release];
        if (failed || !handle)
            return nil;

        id<MTLSharedEvent> event = [device newSharedEventWithHandle:handle];
        [handle release];
        return event;
    }
}
