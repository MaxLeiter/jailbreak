#ifndef XIOS_METAL_EVENT_BROKER_H
#define XIOS_METAL_EVENT_BROKER_H

#include <stddef.h>
#include "XiosProtocol.h"

#define XIOS_METAL_EVENT_BROKER_SERVICE "com.max.xios.metal-event-broker"

#ifdef __OBJC__
/*
 * The broker uses Foundation's NSXPC API, not the C xpc API. Some Procursus
 * sysroots expose newer private xpc headers ahead of the target SDK; letting
 * Foundation's optional __has_include import those mixes incompatible SDK
 * generations. Suppress that optional include and provide only the two opaque
 * declarations referenced by NSXPCConnection.h. No C XPC API is used here.
 */
#ifndef __XPC_H__
#define __XPC_H__
typedef const struct _xpc_type_s *xpc_type_t;
typedef void *xpc_object_t;
#endif
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@protocol XiosMetalEventBrokerProtocol
- (void)publishHandle:(MTLSharedEventHandle *)handle
                token:(NSData *)token
            withReply:(void (^)(BOOL stored))reply;
- (void)copyHandleForToken:(NSData *)token
                 withReply:(void (^)(MTLSharedEventHandle *handle))reply;
@end

/* Publish a handle once under a fresh 256-bit capability token. The broker is
 * the only place the Objective-C Metal handle crosses processes; token bytes
 * are safe to carry on the existing Wayland/app sockets. */
int xios_metal_event_broker_publish(MTLSharedEventHandle *handle,
                                    unsigned char token[XIOS_GPU_FENCE_TOKEN_SIZE]);

/* Fetch the handle and recreate the event on device. The publisher keeps its
 * XPC connection alive, so the same token can be imported by reconnecting
 * consumers until that producer exits. The returned object follows Cocoa's
 * create rule (+1); ARC and Swift callers receive it as retained. That needs
 * NS_RETURNS_RETAINED: on an Objective-C object return, CF_RETURNS_RETAINED is
 * ignored by Swift, which then treats the result as +0 and leaks every event. */
id<MTLSharedEvent> xios_metal_event_broker_copy_event(
    id<MTLDevice> device, const void *token, size_t token_size)
    NS_RETURNS_RETAINED;

/* Same import, but gives up when the broker has not replied within
 * `timeout_seconds` (the synchronous NSXPC proxy above has no timeout, so a
 * wedged broker blocks its caller forever) and returns nil. Still blocking:
 * the app callers run it off the main thread. A reply that arrives after the
 * deadline is released, not leaked. */
#define XIOS_METAL_EVENT_BROKER_TIMEOUT_SEC 2.0
id<MTLSharedEvent> xios_metal_event_broker_copy_event_timeout(
    id<MTLDevice> device, const void *token, size_t token_size,
    double timeout_seconds)
    NS_RETURNS_RETAINED;
#endif

#endif
