#import "xios_metal_sync.h"
#import "XiosMetalEventBroker.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#ifndef EGL_ANGLE_metal_shared_event_sync
#define EGL_ANGLE_metal_shared_event_sync 1
#define EGL_SYNC_METAL_SHARED_EVENT_ANGLE 0x34D8
#define EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE 0x34D9
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE 0x34DA
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE 0x34DB
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_ANGLE 0x34DC
typedef void *(EGLAPIENTRYP PFNEGLCOPYMETALSHAREDEVENTANGLEPROC)(EGLDisplay,
                                                                 EGLSync);
#endif

struct metal_sync_state {
    EGLDisplay display;
    id<MTLSharedEvent> event;
    NSData *token;
    uint64_t value;
    int unavailable;
};

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static struct metal_sync_state s_state = {
    .display = EGL_NO_DISPLAY,
};

static void reset_state_locked(void)
{
    [s_state.event release];
    [s_state.token release];
    memset(&s_state, 0, sizeof(s_state));
    s_state.display = EGL_NO_DISPLAY;
}

static int initialize_event_locked(EGLDisplay display)
{
    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    if (!extensions ||
        !strstr(extensions, "EGL_ANGLE_metal_shared_event_sync")) {
        fprintf(stderr,
                "xios_metal_sync: EGL_ANGLE_metal_shared_event_sync unavailable; "
                "cross-process GPU fencing unavailable\n");
        return 0;
    }

    PFNEGLCOPYMETALSHAREDEVENTANGLEPROC copy_event =
        (PFNEGLCOPYMETALSHAREDEVENTANGLEPROC)
            eglGetProcAddress("eglCopyMetalSharedEventANGLE");
    if (!copy_event)
        return 0;

    /* Bootstrap ANGLE's persistent MTLSharedEvent. This initial value-0 sync is
     * only used to obtain the event object; every real frame gets a subsequent
     * explicitly numbered signal, following ANGLE/Chromium's integration. */
    const EGLAttrib bootstrap_attributes[] = {
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, 0,
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, 0,
        EGL_NONE,
    };
    EGLSync sync = eglCreateSync(display,
                                 EGL_SYNC_METAL_SHARED_EVENT_ANGLE,
                                 bootstrap_attributes);
    if (sync == EGL_NO_SYNC)
        return 0;

    id<MTLSharedEvent> event =
        (id<MTLSharedEvent>)copy_event(display, sync); /* returned retained */
    eglDestroySync(display, sync);
    if (!event)
        return 0;

    MTLSharedEventHandle *handle = [event newSharedEventHandle];
    unsigned char token[XIOS_GPU_FENCE_TOKEN_SIZE];
    int published = xios_metal_event_broker_publish(handle, token);
    [handle release];
    if (!published) {
        fprintf(stderr,
                "xios_metal_sync: shared-event broker publish failed; "
                "cross-process GPU fencing unavailable\n");
        [event release];
        return 0;
    }

    s_state.display = display;
    s_state.event = event;
    s_state.token =
        [[NSData alloc] initWithBytes:token length:XIOS_GPU_FENCE_TOKEN_SIZE];
    s_state.value = 0;
    fprintf(stderr,
            "xios_metal_sync: cross-process GPU fence enabled "
            "(broker token, %u bytes)\n",
            XIOS_GPU_FENCE_TOKEN_SIZE);
    return 1;
}

int xios_metal_sync_signal(EGLDisplay display,
                           const void **token,
                           size_t *token_size,
                           uint64_t *value)
{
    if (token)
        *token = NULL;
    if (token_size)
        *token_size = 0;
    if (value)
        *value = 0;
    if (display == EGL_NO_DISPLAY)
        return 0;

    pthread_mutex_lock(&s_lock);
    if (s_state.display != EGL_NO_DISPLAY && s_state.display != display)
        reset_state_locked();
    if (s_state.unavailable) {
        pthread_mutex_unlock(&s_lock);
        return 0;
    }
    if (!s_state.event && !initialize_event_locked(display)) {
        s_state.unavailable = 1;
        pthread_mutex_unlock(&s_lock);
        return 0;
    }

    uint64_t signal_value = ++s_state.value;
    const EGLAttrib attributes[] = {
        EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE,
        (EGLAttrib)(uintptr_t)s_state.event,
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE,
        (EGLAttrib)(uint32_t)(signal_value & 0xffffffffu),
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE,
        (EGLAttrib)(uint32_t)(signal_value >> 32),
        EGL_NONE,
    };
    EGLSync sync = eglCreateSync(display,
                                 EGL_SYNC_METAL_SHARED_EVENT_ANGLE,
                                 attributes);
    if (sync == EGL_NO_SYNC) {
        fprintf(stderr,
                "xios_metal_sync: frame fence creation failed 0x%x; "
                "cross-process GPU fencing unavailable\n",
                eglGetError());
        pthread_mutex_unlock(&s_lock);
        return 0;
    }

    /* Creating the sync enqueues a signal after all prior ANGLE commands.
     * Submission is sufficient: the Xios Metal command buffer waits on the
     * same shared event before sampling, so the producer CPU need not wait. */
    glFlush();
    eglDestroySync(display, sync);
    if (token)
        *token = s_state.token.bytes;
    if (token_size)
        *token_size = s_state.token.length;
    if (value)
        *value = signal_value;
    pthread_mutex_unlock(&s_lock);
    return 1;
}

void *xios_metal_sync_create_event(void *token_out, size_t token_size)
{
    if (!token_out || token_size != XIOS_GPU_FENCE_TOKEN_SIZE)
        return NULL;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device)
        return NULL;
    id<MTLSharedEvent> event = [device newSharedEvent];
    [device release];
    if (!event)
        return NULL;
    MTLSharedEventHandle *handle = [event newSharedEventHandle];
    int published = xios_metal_event_broker_publish(handle, token_out);
    [handle release];
    if (!published) {
        [event release];
        return NULL;
    }
    return event;
}

void *xios_metal_sync_import_event(const void *token, size_t token_size)
{
    if (!token || token_size != XIOS_GPU_FENCE_TOKEN_SIZE)
        return NULL;

    /* One producer token is reused by all of its swapchain buffers. Fetch the
     * XPC handle once, then retain the recreated event in this consumer. */
    static NSMutableDictionary *events;
    NSData *key = [NSData dataWithBytes:token length:token_size];
    pthread_mutex_lock(&s_lock);
    id<MTLSharedEvent> event = [events objectForKey:key];
    if (event) {
        [event retain];
        pthread_mutex_unlock(&s_lock);
        return event;
    }
    if (events.count >= 256) {
        fprintf(stderr,
                "xios_metal_sync: imported-event cache full; refusing token\n");
        pthread_mutex_unlock(&s_lock);
        return NULL;
    }

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        pthread_mutex_unlock(&s_lock);
        return NULL;
    }
    event = xios_metal_event_broker_copy_event(device, token, token_size);
    [device release];
    if (!event) {
        fprintf(stderr, "xios_metal_sync: broker token fetch/import failed\n");
        pthread_mutex_unlock(&s_lock);
        return NULL;
    }
    if (!events)
        events = [[NSMutableDictionary alloc] init];
    [events setObject:event forKey:key];
    pthread_mutex_unlock(&s_lock);
    return event; /* +1; caller balances via xios_metal_sync_release_event */
}

void xios_metal_sync_release_event(void *event)
{
    [(id<MTLSharedEvent>)event release];
}

int xios_metal_sync_wait(EGLDisplay display, void *event_ptr, uint64_t value)
{
    if (display == EGL_NO_DISPLAY || !event_ptr || value == 0)
        return 0;
    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    if (!extensions ||
        !strstr(extensions, "EGL_ANGLE_metal_shared_event_sync"))
        return 0;

    const EGLAttrib attributes[] = {
        EGL_SYNC_METAL_SHARED_EVENT_OBJECT_ANGLE,
        (EGLAttrib)(uintptr_t)event_ptr,
        EGL_SYNC_CONDITION,
        EGL_SYNC_METAL_SHARED_EVENT_SIGNALED_ANGLE,
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE,
        (EGLAttrib)(uint32_t)(value & 0xffffffffu),
        EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE,
        (EGLAttrib)(uint32_t)(value >> 32),
        EGL_NONE,
    };
    EGLSync sync = eglCreateSync(display,
                                 EGL_SYNC_METAL_SHARED_EVENT_ANGLE,
                                 attributes);
    if (sync == EGL_NO_SYNC) {
        fprintf(stderr,
                "xios_metal_sync: release wait sync creation failed 0x%x "
                "(value=%llu)\n",
                eglGetError(), (unsigned long long)value);
        return 0;
    }

    /* The Xios libEGL shim explicitly publishes the EGL 1.5 core entry point
     * through eglGetProcAddress. Calling through it keeps this helper usable in
     * the shim itself (which dlopens ANGLE rather than linking libEGL) while
     * still queuing a GPU wait in ANGLE's Metal stream. */
    PFNEGLWAITSYNCPROC wait_sync =
        (PFNEGLWAITSYNCPROC)eglGetProcAddress("eglWaitSync");
    if (!wait_sync) {
        fprintf(stderr,
                "xios_metal_sync: eglWaitSync unavailable from libEGL shim "
                "(value=%llu)\n",
                (unsigned long long)value);
        eglDestroySync(display, sync);
        return 0;
    }
    EGLBoolean waited = wait_sync(display, sync, 0);
    EGLint wait_error = waited == EGL_TRUE ? EGL_SUCCESS : eglGetError();
    eglDestroySync(display, sync);
    if (waited != EGL_TRUE)
        fprintf(stderr,
                "xios_metal_sync: release wait enqueue failed 0x%x "
                "(value=%llu)\n",
                wait_error, (unsigned long long)value);
    return waited == EGL_TRUE;
}
