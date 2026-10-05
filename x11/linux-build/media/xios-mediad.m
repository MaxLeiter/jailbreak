#include "xios_media_protocol.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

/*
 * Capture lifecycle: the microphone (RemoteIO input plus a PlayAndRecord
 * AVAudioSession) runs only while at least one client is connected to the mic
 * socket, and the camera (--daemon-camera) only while at least one client is
 * connected to the video socket. A live capture IO keeps the device out of
 * idle sleep and, for the mic, records with nobody listening.
 *
 * Every start and stop happens on g_ctl_queue (serial), which recomputes the
 * wanted state from the client counts each time a count changes. The socket
 * and capture threads only update counts and poke the queue, so they never
 * block on a session activation, and nothing holds a server lock while a
 * capture unit is being stopped (its callback takes that lock).
 */

/* Clients polled per socket for hangup; more still work, they are just only
 * noticed leaving by the next failed write. */
#define MAX_POLLED_CLIENTS 32

typedef struct media_client {
    int fd;
    struct media_client *next;
} media_client;

typedef struct {
    const char *name;
    const char *path;
    pthread_mutex_t lock;
    media_client *clients;
    int nclients;
    int listener_fd;
} media_server;

static volatile sig_atomic_t g_running = 1;
static media_server g_video_server = {
    .name = "video",
    .path = XIOS_MEDIA_DEFAULT_VIDEO_SOCKET,
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .clients = NULL,
    .nclients = 0,
    .listener_fd = -1,
};
static media_server g_mic_server = {
    .name = "mic",
    .path = XIOS_MEDIA_DEFAULT_MIC_SOCKET,
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .clients = NULL,
    .nclients = 0,
    .listener_fd = -1,
};

static uint32_t g_video_frame_index = 0;
static AudioUnit g_mic_unit = NULL;
static bool g_daemon_camera = false;

/* Serial queue that owns every capture start/stop. */
static dispatch_queue_t g_ctl_queue;
/* Owned by g_ctl_queue. */
static bool g_mic_running = false;
static bool g_camera_running = false;

static void media_reconcile(void);

/* Recompute capture state after a client count change. Never blocks. */
static void request_reconcile(void) {
    if (g_ctl_queue) {
        dispatch_async(g_ctl_queue, ^{
            media_reconcile();
        });
    }
}

/* Self-pipe that wakes the server threads' poll() on shutdown, so they can
 * wait with no timeout (no idle wakeups). Never read: it stays readable, which
 * wakes every server thread. */
static int g_wake_pipe[2] = {-1, -1};

static void handle_signal(int sig) {
    (void)sig;
    g_running = 0;
    if (g_wake_pipe[1] >= 0) {
        char c = 1;
        (void)write(g_wake_pipe[1], &c, 1);
    }
}

static void set_sigpipe_ignored(void) {
    signal(SIGPIPE, SIG_IGN);
}

static int set_blocking_timeout(int fd) {
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 250000;
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) < 0) {
        perror("xios-mediad: SO_SNDTIMEO");
    }
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    return 0;
}

static int write_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

static int server_client_count(media_server *server) {
    pthread_mutex_lock(&server->lock);
    int n = server->nclients;
    pthread_mutex_unlock(&server->lock);
    return n;
}

static void client_list_add(media_server *server, int fd) {
    set_blocking_timeout(fd);

    media_client *client = (media_client *)calloc(1, sizeof(*client));
    if (!client) {
        close(fd);
        return;
    }
    client->fd = fd;

    pthread_mutex_lock(&server->lock);
    client->next = server->clients;
    server->clients = client;
    int n = ++server->nclients;
    pthread_mutex_unlock(&server->lock);
    fprintf(stderr, "xios-mediad: %s client connected (%d connected)\n", server->name, n);
    request_reconcile();
}

static void broadcast_media(media_server *server,
                            uint32_t type,
                            const void *header,
                            size_t header_len,
                            const void *payload,
                            size_t payload_len) {
    xios_media_msg msg = {
        .magic = XIOS_MEDIA_MAGIC,
        .version = XIOS_MEDIA_VERSION,
        .type = type,
        .size = (uint32_t)(header_len + payload_len),
    };
    bool dropped = false;

    pthread_mutex_lock(&server->lock);
    media_client **pp = &server->clients;
    while (*pp) {
        media_client *client = *pp;
        bool ok = true;
        if (write_full(client->fd, &msg, sizeof(msg)) < 0) ok = false;
        if (ok && header_len && write_full(client->fd, header, header_len) < 0) ok = false;
        if (ok && payload_len && write_full(client->fd, payload, payload_len) < 0) ok = false;

        if (!ok) {
            fprintf(stderr, "xios-mediad: dropping %s client: %s\n",
                    server->name, strerror(errno));
            *pp = client->next;
            close(client->fd);
            free(client);
            server->nclients--;
            dropped = true;
        } else {
            pp = &client->next;
        }
    }
    pthread_mutex_unlock(&server->lock);
    if (dropped) request_reconcile();
}

/* Clients never send on these sockets, so while capture is stopped no write
 * would notice one leave. The server thread polls them, and a readable socket
 * is checked here: EOF or an error means the client is gone. Matching by fd
 * under the lock keeps this safe against broadcast_media having already
 * dropped (and closed) the same client. */
static void reap_if_hung_up(media_server *server, int fd) {
    bool removed = false;
    int n = 0;

    pthread_mutex_lock(&server->lock);
    for (media_client **pp = &server->clients; *pp; pp = &(*pp)->next) {
        media_client *client = *pp;
        if (client->fd != fd) continue;
        char scratch[256];
        ssize_t r = recv(fd, scratch, sizeof(scratch), MSG_DONTWAIT);
        if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            *pp = client->next;
            close(client->fd);
            free(client);
            n = --server->nclients;
            removed = true;
        }
        /* r > 0: bytes this protocol does not define; discarded. */
        break;
    }
    pthread_mutex_unlock(&server->lock);

    if (removed) {
        fprintf(stderr, "xios-mediad: %s client disconnected (%d connected)\n", server->name, n);
        request_reconcile();
    }
}

static void *server_thread(void *arg) {
    media_server *server = (media_server *)arg;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("xios-mediad: socket");
        return NULL;
    }

    unlink(server->path);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(server->path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "xios-mediad: socket path too long: %s\n", server->path);
        close(fd);
        return NULL;
    }
    strncpy(addr.sun_path, server->path, sizeof(addr.sun_path) - 1);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "xios-mediad: bind(%s): %s\n", server->path, strerror(errno));
        close(fd);
        return NULL;
    }
    chmod(server->path, 0666);

    if (listen(fd, 16) < 0) {
        perror("xios-mediad: listen");
        close(fd);
        return NULL;
    }
    /* Non-blocking so a connection aborted between poll() and accept() cannot
     * park this thread in accept(). Accepted sockets inherit O_NONBLOCK on
     * Darwin, so each one is switched back to blocking below: broadcast_media
     * relies on blocking sends bounded by SO_SNDTIMEO. */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

    server->listener_fd = fd;
    fprintf(stderr, "xios-mediad: %s socket listening at %s\n", server->name, server->path);

    /* Slot 0 is the listener, slot 1 the shutdown pipe (poll() ignores it if
     * the pipe could not be made, and then a bounded wait stands in). */
    int timeout_ms = g_wake_pipe[0] >= 0 ? -1 : 500;
    while (g_running) {
        struct pollfd pfds[2 + MAX_POLLED_CLIENTS];
        nfds_t nfds = 0;
        pfds[nfds].fd = fd;
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        nfds++;
        pfds[nfds].fd = g_wake_pipe[0];
        pfds[nfds].events = POLLIN;
        pfds[nfds].revents = 0;
        nfds++;
        pthread_mutex_lock(&server->lock);
        for (media_client *c = server->clients; c && nfds < 2 + MAX_POLLED_CLIENTS; c = c->next) {
            pfds[nfds].fd = c->fd;
            pfds[nfds].events = POLLIN;
            pfds[nfds].revents = 0;
            nfds++;
        }
        pthread_mutex_unlock(&server->lock);

        int r = poll(pfds, nfds, timeout_ms);
        if (!g_running) break;
        if (r < 0) {
            if (errno != EINTR) {
                perror("xios-mediad: poll");
                usleep(100000);
            }
            continue;
        }

        for (nfds_t i = 2; i < nfds; i++) {
            if (pfds[i].revents) reap_if_hung_up(server, pfds[i].fd);
        }

        if (pfds[0].revents & POLLNVAL) break;
        if (pfds[0].revents & POLLIN) {
            int client_fd = accept(fd, NULL, NULL);
            if (client_fd < 0) {
                if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK ||
                    errno == ECONNABORTED) {
                    continue;
                }
                if (!g_running || errno == EBADF) break;
                perror("xios-mediad: accept");
                continue;
            }
            fcntl(client_fd, F_SETFL, fcntl(client_fd, F_GETFL) & ~O_NONBLOCK);
            client_list_add(server, client_fd);
        }
    }

    close(fd);
    unlink(server->path);
    server->listener_fd = -1;
    return NULL;
}

@interface XiosVideoDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation XiosVideoDelegate
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;

    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!image) return;

    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    void *base = CVPixelBufferGetBaseAddress(image);
    size_t width = CVPixelBufferGetWidth(image);
    size_t height = CVPixelBufferGetHeight(image);
    size_t stride = CVPixelBufferGetBytesPerRow(image);
    size_t size = stride * height;

    if (base && size > 0 && width <= UINT32_MAX && height <= UINT32_MAX &&
        stride <= UINT32_MAX && size <= UINT32_MAX) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        uint64_t timestamp_ns = 0;
        if (pts.timescale > 0 && pts.value >= 0) {
            timestamp_ns = (uint64_t)((pts.value * 1000000000LL) / pts.timescale);
        }

        xios_media_video_frame frame = {
            .timestamp_ns = timestamp_ns,
            .width = (uint32_t)width,
            .height = (uint32_t)height,
            .stride = (uint32_t)stride,
            .format = XIOS_MEDIA_VIDEO_FMT_BGRA32,
            .frame_index = __sync_add_and_fetch(&g_video_frame_index, 1),
            .flags = 0,
        };
        broadcast_media(&g_video_server, XIOS_MEDIA_MSG_VIDEO_FRAME,
                        &frame, sizeof(frame), base, size);
    }

    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}
@end

/* Camera objects, owned by g_ctl_queue. The capture session is built on the
 * first video client and then kept: stopRunning releases the camera, and the
 * next client only needs startRunning. */
static AVCaptureSession *g_camera_session = nil;
static XiosVideoDelegate *g_video_delegate = nil;
static char g_camera_name[128];

static NSArray *available_video_devices(void) {
    NSArray *types = @[
        AVCaptureDeviceTypeBuiltInWideAngleCamera
    ];
    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    return discovery.devices;
}

static AVCaptureDeviceInput *make_camera_input(AVCaptureDevice **out_device) {
    NSArray *devices = available_video_devices();
    NSMutableArray *ordered = [NSMutableArray array];
    for (AVCaptureDevice *device in devices) {
        if (device.position == AVCaptureDevicePositionFront) [ordered addObject:device];
    }
    for (AVCaptureDevice *device in devices) {
        if (device.position != AVCaptureDevicePositionFront) [ordered addObject:device];
    }
    if (ordered.count == 0) {
        AVCaptureDevice *fallback = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (fallback) [ordered addObject:fallback];
    }

    for (AVCaptureDevice *device in ordered) {
        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
        if (input) {
            *out_device = device;
            return input;
        }
        fprintf(stderr, "xios-mediad: camera input failed for %s: %s\n",
                device.localizedName.UTF8String,
                err ? err.localizedDescription.UTF8String : "unknown");
    }
    return nil;
}

/* Build (but do not start) the capture session. Same configuration as the
 * original start-at-launch path. */
static int build_camera(void) {
    @autoreleasepool {
        AVCaptureDevice *device = nil;
        AVCaptureDeviceInput *input = make_camera_input(&device);
        if (!input) {
            fprintf(stderr, "xios-mediad: no usable AVCapture video device\n");
            return -1;
        }

        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
            session.sessionPreset = AVCaptureSessionPreset640x480;
        }

        if (![session canAddInput:input]) {
            fprintf(stderr, "xios-mediad: cannot add camera input\n");
            return -1;
        }
        [session addInput:input];

        if (![session canAddOutput:output]) {
            fprintf(stderr, "xios-mediad: cannot add camera output\n");
            return -1;
        }
        [session addOutput:output];

        XiosVideoDelegate *delegate = [[XiosVideoDelegate alloc] init];
        dispatch_queue_t queue = dispatch_queue_create("xios.media.video", DISPATCH_QUEUE_SERIAL);
        [output setSampleBufferDelegate:delegate queue:queue];

        snprintf(g_camera_name, sizeof(g_camera_name), "%s",
                 device.localizedName.UTF8String ? device.localizedName.UTF8String : "camera");
        g_camera_session = session;
        g_video_delegate = delegate;
        return 0;
    }
}

static int start_camera(void) {
    if (!g_camera_session && build_camera() < 0) return -1;
    [g_camera_session startRunning];
    if (!g_camera_session.isRunning) {
        fprintf(stderr, "xios-mediad: camera session did not start running\n");
        return -1;
    }
    return 0;
}

static void stop_camera(void) {
    if (g_camera_session) [g_camera_session stopRunning];
}

static OSStatus mic_input_cb(void *refcon,
                             AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *ts,
                             UInt32 bus,
                             UInt32 frames,
                             AudioBufferList *io_data) {
    (void)refcon;
    (void)bus;
    (void)io_data;

    AudioUnit unit = g_mic_unit;
    if (!unit) return noErr;

    size_t bytes = (size_t)frames * sizeof(float);
    float *buffer = (float *)malloc(bytes);
    if (!buffer) return noErr;

    AudioBufferList abl;
    abl.mNumberBuffers = 1;
    abl.mBuffers[0].mNumberChannels = XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS;
    abl.mBuffers[0].mDataByteSize = (UInt32)bytes;
    abl.mBuffers[0].mData = buffer;

    OSStatus st = AudioUnitRender(unit, flags, ts, 1, frames, &abl);
    if (st == noErr && abl.mBuffers[0].mDataByteSize > 0) {
        xios_media_mic_frame frame = {
            .host_time = ts ? ts->mHostTime : 0,
            .sample_rate = XIOS_MEDIA_DEFAULT_AUDIO_RATE,
            .channels = XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS,
            .format = XIOS_MEDIA_AUDIO_FMT_F32LE,
            .frames = frames,
            .flags = 0,
        };
        broadcast_media(&g_mic_server, XIOS_MEDIA_MSG_MIC_FRAME,
                        &frame, sizeof(frame), buffer, abl.mBuffers[0].mDataByteSize);
    }

    free(buffer);
    return noErr;
}

static int activate_media_session(void) {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;
        AVAudioSessionCategoryOptions options =
            AVAudioSessionCategoryOptionMixWithOthers |
            AVAudioSessionCategoryOptionAllowBluetooth |
            AVAudioSessionCategoryOptionDefaultToSpeaker;

        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                      withOptions:options
                            error:&err]) {
            fprintf(stderr, "xios-mediad: setCategory(PlayAndRecord) failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
            return -1;
        }
        [session setPreferredSampleRate:XIOS_MEDIA_DEFAULT_AUDIO_RATE error:nil];
        [session setPreferredInputNumberOfChannels:XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS error:nil];
        if (![session setActive:YES error:&err]) {
            fprintf(stderr, "xios-mediad: AVAudioSession setActive failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
            return -1;
        }
        return 0;
    }
}

/* After the mic unit is stopped: setActive:NO fails as busy while IO runs. */
static void deactivate_media_session(void) {
    @autoreleasepool {
        NSError *err = nil;
        if (![[AVAudioSession sharedInstance]
                    setActive:NO
                  withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                        error:&err]) {
            fprintf(stderr, "xios-mediad: AVAudioSession deactivate failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
        }
    }
}

static void dispose_mic_unit(void) {
    AudioUnit unit = g_mic_unit;
    if (!unit) return;
    AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    g_mic_unit = NULL;
    AudioComponentInstanceDispose(unit);
}

static int open_mic_unit(void) {
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        fprintf(stderr, "xios-mediad: RemoteIO component not found\n");
        return -1;
    }

    OSStatus st = AudioComponentInstanceNew(comp, &g_mic_unit);
    if (st != noErr) {
        fprintf(stderr, "xios-mediad: AudioComponentInstanceNew failed: %d\n", (int)st);
        return -1;
    }

    UInt32 one = 1;
    st = AudioUnitSetProperty(g_mic_unit, kAudioOutputUnitProperty_EnableIO,
                              kAudioUnitScope_Input, 1, &one, sizeof(one));
    if (st != noErr) {
        fprintf(stderr, "xios-mediad: enable input failed: %d\n", (int)st);
        return -1;
    }

    UInt32 zero = 0;
    AudioUnitSetProperty(g_mic_unit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Output, 0, &zero, sizeof(zero));

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = XIOS_MEDIA_DEFAULT_AUDIO_RATE;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS;
    fmt.mFramesPerPacket = 1;
    fmt.mBitsPerChannel = 32;
    fmt.mBytesPerFrame = sizeof(float) * fmt.mChannelsPerFrame;
    fmt.mBytesPerPacket = fmt.mBytesPerFrame;

    st = AudioUnitSetProperty(g_mic_unit, kAudioUnitProperty_StreamFormat,
                              kAudioUnitScope_Output, 1, &fmt, sizeof(fmt));
    if (st != noErr) {
        fprintf(stderr, "xios-mediad: set input stream format failed: %d\n", (int)st);
        return -1;
    }

    AURenderCallbackStruct cb;
    cb.inputProc = mic_input_cb;
    cb.inputProcRefCon = NULL;
    st = AudioUnitSetProperty(g_mic_unit, kAudioOutputUnitProperty_SetInputCallback,
                              kAudioUnitScope_Global, 1, &cb, sizeof(cb));
    if (st != noErr) {
        fprintf(stderr, "xios-mediad: set input callback failed: %d\n", (int)st);
        return -1;
    }

    st = AudioUnitInitialize(g_mic_unit);
    if (st != noErr) {
        fprintf(stderr, "xios-mediad: AudioUnitInitialize failed: %d\n", (int)st);
        return -1;
    }
    st = AudioOutputUnitStart(g_mic_unit);
    if (st != noErr) {
        fprintf(stderr, "xios-mediad: AudioOutputUnitStart failed: %d\n", (int)st);
        return -1;
    }
    return 0;
}

static int start_mic(void) {
    if (activate_media_session() < 0) return -1;
    if (open_mic_unit() < 0) {
        dispose_mic_unit();
        deactivate_media_session();
        return -1;
    }
    return 0;
}

static void stop_mic(void) {
    dispose_mic_unit();
    deactivate_media_session();
}

/* On g_ctl_queue only. Brings mic and camera in line with the client counts
 * (or stops both once g_running is cleared). A failed start is retried on
 * the next count change while clients remain, not on a timer. */
static void media_reconcile(void) {
    @autoreleasepool {
        int mic_clients = g_running ? server_client_count(&g_mic_server) : 0;
        if (mic_clients > 0 && !g_mic_running) {
            if (start_mic() == 0) {
                g_mic_running = true;
                fprintf(stderr, "xios-mediad: microphone started (%d mic client(s), session=PlayAndRecord)\n",
                        mic_clients);
            } else {
                fprintf(stderr, "xios-mediad: microphone start failed; will retry when mic clients come or go\n");
            }
        } else if (mic_clients == 0 && g_mic_running) {
            stop_mic();
            g_mic_running = false;
            fprintf(stderr, "xios-mediad: microphone stopped (no mic clients), session deactivated\n");
        }

        if (g_daemon_camera) {
            int video_clients = g_running ? server_client_count(&g_video_server) : 0;
            if (video_clients > 0 && !g_camera_running) {
                if (start_camera() == 0) {
                    g_camera_running = true;
                    fprintf(stderr, "xios-mediad: camera started: %s (%d video client(s))\n",
                            g_camera_name, video_clients);
                } else {
                    fprintf(stderr, "xios-mediad: camera start failed; will retry when video clients come or go\n");
                }
            } else if (video_clients == 0 && g_camera_running) {
                stop_camera();
                g_camera_running = false;
                fprintf(stderr, "xios-mediad: camera stopped (no video clients)\n");
            }
        }
    }
}

static void daemonize_if_requested(bool foreground) {
    if (foreground) return;
    pid_t pid = fork();
    if (pid < 0) {
        perror("xios-mediad: fork");
        exit(1);
    }
    if (pid > 0) exit(0);
    setsid();
    chdir("/");
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        if (devnull > STDERR_FILENO) close(devnull);
    }
}

static void usage(void) {
    fprintf(stderr,
            "usage: xios-mediad [--foreground] [--daemon-camera] [--video-socket PATH] [--mic-socket PATH]\n");
}

int main(int argc, char **argv) {
    bool foreground = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--foreground")) {
            foreground = true;
        } else if (!strcmp(argv[i], "--daemon-camera")) {
            g_daemon_camera = true;
        } else if (!strcmp(argv[i], "--video-socket") && i + 1 < argc) {
            g_video_server.path = argv[++i];
        } else if (!strcmp(argv[i], "--mic-socket") && i + 1 < argc) {
            g_mic_server.path = argv[++i];
        } else {
            usage();
            return 2;
        }
    }

    daemonize_if_requested(foreground);
    set_sigpipe_ignored();
    if (pipe(g_wake_pipe) == 0) {
        for (int i = 0; i < 2; i++) {
            fcntl(g_wake_pipe[i], F_SETFL, fcntl(g_wake_pipe[i], F_GETFL) | O_NONBLOCK);
            fcntl(g_wake_pipe[i], F_SETFD, FD_CLOEXEC);
        }
    } else {
        perror("xios-mediad: pipe");
        g_wake_pipe[0] = g_wake_pipe[1] = -1;
    }
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    g_ctl_queue = dispatch_queue_create("xios.media.control", DISPATCH_QUEUE_SERIAL);

    @autoreleasepool {
        pthread_t mic_thread;
        pthread_t video_thread;
        bool have_video_thread = false;
        if (g_daemon_camera) {
            have_video_thread = pthread_create(&video_thread, NULL, server_thread, &g_video_server) == 0;
        }
        bool have_mic_thread = pthread_create(&mic_thread, NULL, server_thread, &g_mic_server) == 0;
        fprintf(stderr, "xios-mediad: capture idle until a client connects%s\n",
                g_daemon_camera ? " (mic and camera)" : " (mic)");

        while (g_running) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }

        /* g_running is clear, so this stops whatever is still running. */
        dispatch_sync(g_ctl_queue, ^{
            media_reconcile();
        });
        /* The wake pipe has them on their way out; joining lets them unlink
         * their sockets before the process exits. */
        if (have_mic_thread) pthread_join(mic_thread, NULL);
        if (have_video_thread) pthread_join(video_thread, NULL);
    }

    return 0;
}
