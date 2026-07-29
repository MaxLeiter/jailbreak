#ifndef XIOS_METAL_EVENT_BROKER_H
#define XIOS_METAL_EVENT_BROKER_H

#include <stddef.h>

#define XIOS_METAL_EVENT_BROKER_SERVICE "com.max.xios.metal-event-broker"
#define XIOS_METAL_EVENT_TOKEN_SIZE 32u

#ifdef __OBJC__
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
                                    unsigned char token[XIOS_METAL_EVENT_TOKEN_SIZE]);

/* Fetch the handle and recreate the event on device. The publisher keeps its
 * XPC connection alive, so the same token can be imported by reconnecting
 * consumers until that producer exits. The returned object follows Cocoa's
 * create rule (+1); ARC callers receive it as retained. */
id<MTLSharedEvent> xios_metal_event_broker_copy_event(
    id<MTLDevice> device, const void *token, size_t token_size)
    CF_RETURNS_RETAINED;
#endif

#endif
