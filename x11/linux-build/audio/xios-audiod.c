#include "xios_audio_protocol.h"
#include "xios_audio_session.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define RING_FRAMES (XIOS_AUDIO_DEFAULT_RATE * 4)
#define MAX_PAYLOAD (1024u * 1024u)

typedef struct client {
    int fd;
    uint32_t rate;
    uint32_t channels;
    uint32_t format;
    double out_credit;
    float *ring;
    size_t read_frame;
    size_t write_frame;
    size_t frames;
    int closing;
    struct client *next;
} client;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static client *g_clients;
static volatile sig_atomic_t g_stop;
static volatile sig_atomic_t g_dump_stats;
static AudioComponentInstance g_unit;

/* Render diagnostics, updated inside the (locked) render callback. A nonzero,
 * growing render_calls count is the definitive proof that the HAL is actually
 * pulling audio from us, independent of whether anyone is listening. */
static uint64_t g_render_calls;
static uint64_t g_render_frames;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void on_usr1(int sig) {
    (void)sig;
    g_dump_stats = 1;
}

static void dump_stats(void) {
    pthread_mutex_lock(&g_lock);
    uint64_t calls = g_render_calls;
    uint64_t frames = g_render_frames;
    int clients = 0;
    for (client *c = g_clients; c; c = c->next) clients++;
    pthread_mutex_unlock(&g_lock);
    fprintf(stderr,
            "xios-audiod: stats render_calls=%llu render_frames=%llu (~%.2fs) clients=%d\n",
            (unsigned long long)calls, (unsigned long long)frames,
            (double)frames / (double)XIOS_AUDIO_DEFAULT_RATE, clients);
}

static int read_all(int fd, void *buf, size_t len) {
    char *p = (char *)buf;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return 0;
        p += n;
        len -= (size_t)n;
    }
    return 1;
}

static void client_add(client *c) {
    pthread_mutex_lock(&g_lock);
    c->next = g_clients;
    g_clients = c;
    pthread_mutex_unlock(&g_lock);
}

static void client_remove(client *c) {
    pthread_mutex_lock(&g_lock);
    client **pp = &g_clients;
    while (*pp) {
        if (*pp == c) {
            *pp = c->next;
            break;
        }
        pp = &(*pp)->next;
    }
    pthread_mutex_unlock(&g_lock);
}

static void client_free(client *c) {
    if (!c) return;
    if (c->fd >= 0) close(c->fd);
    free(c->ring);
    free(c);
}

static void ring_push_stereo(client *c, float left, float right) {
    if (c->frames >= RING_FRAMES) {
        c->read_frame = (c->read_frame + 1) % RING_FRAMES;
        c->frames--;
    }
    size_t i = c->write_frame * 2;
    c->ring[i] = left;
    c->ring[i + 1] = right;
    c->write_frame = (c->write_frame + 1) % RING_FRAMES;
    c->frames++;
}

static int ring_pop_stereo(client *c, float *left, float *right) {
    if (!c->frames) return 0;
    size_t i = c->read_frame * 2;
    *left = c->ring[i];
    *right = c->ring[i + 1];
    c->read_frame = (c->read_frame + 1) % RING_FRAMES;
    c->frames--;
    return 1;
}

static float clamp1(float v) {
    if (v > 1.0f) return 1.0f;
    if (v < -1.0f) return -1.0f;
    return v;
}

static void ingest_s16(client *c, const int16_t *samples, size_t frames) {
    double ratio = (double)XIOS_AUDIO_DEFAULT_RATE / (double)c->rate;
    for (size_t f = 0; f < frames; f++) {
        float left;
        float right;
        if (c->channels == 1) {
            left = right = (float)samples[f] / 32768.0f;
        } else {
            left = (float)samples[f * c->channels] / 32768.0f;
            right = (float)samples[f * c->channels + 1] / 32768.0f;
        }
        c->out_credit += ratio;
        while (c->out_credit >= 1.0) {
            ring_push_stereo(c, left, right);
            c->out_credit -= 1.0;
        }
    }
}

static void ingest_f32(client *c, const float *samples, size_t frames) {
    double ratio = (double)XIOS_AUDIO_DEFAULT_RATE / (double)c->rate;
    for (size_t f = 0; f < frames; f++) {
        float left;
        float right;
        if (c->channels == 1) {
            left = right = samples[f];
        } else {
            left = samples[f * c->channels];
            right = samples[f * c->channels + 1];
        }
        c->out_credit += ratio;
        while (c->out_credit >= 1.0) {
            ring_push_stereo(c, clamp1(left), clamp1(right));
            c->out_credit -= 1.0;
        }
    }
}

static int ingest_payload(client *c, const void *payload, size_t size) {
    if (!c->rate || !c->channels || c->channels > 8) return -1;
    pthread_mutex_lock(&g_lock);
    if (c->format == XIOS_AUDIO_FMT_S16LE) {
        size_t frame_bytes = sizeof(int16_t) * c->channels;
        ingest_s16(c, (const int16_t *)payload, size / frame_bytes);
    } else if (c->format == XIOS_AUDIO_FMT_F32LE) {
        size_t frame_bytes = sizeof(float) * c->channels;
        ingest_f32(c, (const float *)payload, size / frame_bytes);
    } else {
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    pthread_mutex_unlock(&g_lock);
    return 0;
}

static void *client_thread(void *arg) {
    /* Keep lifecycle/diagnostic signals on the main thread only, so they
     * reliably interrupt accept() instead of being absorbed here. */
    sigset_t block;
    sigemptyset(&block);
    sigaddset(&block, SIGINT);
    sigaddset(&block, SIGTERM);
    sigaddset(&block, SIGUSR1);
    pthread_sigmask(SIG_BLOCK, &block, NULL);

    client *c = (client *)arg;
    xios_audio_msg msg;
    int r = read_all(c->fd, &msg, sizeof(msg));
    if (r != 1 || msg.magic != XIOS_AUDIO_MAGIC || msg.version != XIOS_AUDIO_VERSION ||
        msg.type != XIOS_AUDIO_MSG_OPEN || msg.size != sizeof(xios_audio_open)) {
        client_free(c);
        return NULL;
    }

    xios_audio_open open_msg;
    if (read_all(c->fd, &open_msg, sizeof(open_msg)) != 1) {
        client_free(c);
        return NULL;
    }
    c->rate = open_msg.sample_rate ? open_msg.sample_rate : XIOS_AUDIO_DEFAULT_RATE;
    c->channels = open_msg.channels ? open_msg.channels : XIOS_AUDIO_DEFAULT_CHANNELS;
    c->format = open_msg.format ? open_msg.format : XIOS_AUDIO_FMT_S16LE;
    c->ring = (float *)calloc(RING_FRAMES * 2, sizeof(float));
    if (!c->ring || c->channels > 8 ||
        (c->format != XIOS_AUDIO_FMT_S16LE && c->format != XIOS_AUDIO_FMT_F32LE)) {
        client_free(c);
        return NULL;
    }
    client_add(c);

    for (;;) {
        r = read_all(c->fd, &msg, sizeof(msg));
        if (r != 1) break;
        if (msg.magic != XIOS_AUDIO_MAGIC || msg.version != XIOS_AUDIO_VERSION ||
            msg.size > MAX_PAYLOAD) {
            break;
        }
        if (msg.type == XIOS_AUDIO_MSG_CLOSE) {
            break;
        } else if (msg.type == XIOS_AUDIO_MSG_DRAIN) {
            continue;
        } else if (msg.type == XIOS_AUDIO_MSG_DATA) {
            void *payload = malloc(msg.size ? msg.size : 1);
            if (!payload) break;
            r = read_all(c->fd, payload, msg.size);
            if (r != 1 || ingest_payload(c, payload, msg.size) < 0) {
                free(payload);
                break;
            }
            free(payload);
        } else {
            if (msg.size) {
                char discard[512];
                uint32_t left = msg.size;
                while (left) {
                    size_t n = left > sizeof(discard) ? sizeof(discard) : left;
                    r = read_all(c->fd, discard, n);
                    if (r != 1) break;
                    left -= (uint32_t)n;
                }
            }
            break;
        }
    }

    client_remove(c);
    client_free(c);
    return NULL;
}

static OSStatus render_cb(void *refcon, AudioUnitRenderActionFlags *flags,
                          const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                          AudioBufferList *io) {
    (void)refcon;
    (void)flags;
    (void)ts;
    (void)bus;
    if (!io || io->mNumberBuffers < 1) return noErr;
    int16_t *out = (int16_t *)io->mBuffers[0].mData;
    if (!out) return noErr;

    pthread_mutex_lock(&g_lock);
    for (UInt32 f = 0; f < frames; f++) {
        float l = 0.0f;
        float r = 0.0f;
        for (client *c = g_clients; c; c = c->next) {
            float cl = 0.0f;
            float cr = 0.0f;
            if (ring_pop_stereo(c, &cl, &cr)) {
                l += cl;
                r += cr;
            }
        }
        out[f * 2] = (int16_t)lrintf(clamp1(l) * 32767.0f);
        out[f * 2 + 1] = (int16_t)lrintf(clamp1(r) * 32767.0f);
    }
    g_render_calls++;
    g_render_frames += frames;
    pthread_mutex_unlock(&g_lock);
    return noErr;
}

static int start_audio_unit(void) {
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        fprintf(stderr, "xios-audiod: RemoteIO component not found\n");
        return -1;
    }
    OSStatus err = AudioComponentInstanceNew(comp, &g_unit);
    if (err != noErr) {
        fprintf(stderr, "xios-audiod: AudioComponentInstanceNew failed: %d\n", (int)err);
        return -1;
    }

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = XIOS_AUDIO_DEFAULT_RATE;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mFramesPerPacket = 1;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = 4;
    fmt.mBytesPerPacket = 4;
    err = AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (err != noErr) {
        fprintf(stderr, "xios-audiod: set stream format failed: %d\n", (int)err);
        return -1;
    }

    AURenderCallbackStruct cb;
    cb.inputProc = render_cb;
    cb.inputProcRefCon = NULL;
    err = AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (err != noErr) {
        fprintf(stderr, "xios-audiod: set render callback failed: %d\n", (int)err);
        return -1;
    }

    err = AudioUnitInitialize(g_unit);
    if (err != noErr) {
        fprintf(stderr, "xios-audiod: AudioUnitInitialize failed: %d\n", (int)err);
        return -1;
    }
    err = AudioOutputUnitStart(g_unit);
    if (err != noErr) {
        fprintf(stderr, "xios-audiod: AudioOutputUnitStart failed: %d\n", (int)err);
        return -1;
    }
    return 0;
}

static void stop_audio_unit(void) {
    if (!g_unit) return;
    AudioOutputUnitStop(g_unit);
    AudioUnitUninitialize(g_unit);
    AudioComponentInstanceDispose(g_unit);
    g_unit = NULL;
}

static int make_listener(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(sun.sun_path)) {
        errno = ENAMETOOLONG;
        close(fd);
        return -1;
    }
    strcpy(sun.sun_path, path);
    unlink(path);
    if (bind(fd, (struct sockaddr *)&sun, sizeof(sun)) < 0) {
        close(fd);
        return -1;
    }
    chmod(path, 0666);
    if (listen(fd, 32) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    const char *sock = getenv("XIOS_AUDIO_SERVER");
    int foreground = 0;
    if (!sock || !sock[0]) sock = XIOS_AUDIO_DEFAULT_SOCKET;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            sock = argv[++i];
        } else if (!strcmp(argv[i], "--foreground") || !strcmp(argv[i], "-f")) {
            foreground = 1;
        } else {
            fprintf(stderr, "usage: xios-audiod [--foreground] [--socket PATH]\n");
            return 2;
        }
    }

    /* Use sigaction without SA_RESTART so these signals interrupt the blocking
     * accept() in the main loop. BSD signal() sets SA_RESTART by default, which
     * would auto-restart accept() and defeat both clean SIGTERM shutdown and the
     * SIGUSR1 stats dump. */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_usr1;
    sigaction(SIGUSR1, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    if (!foreground) {
        pid_t pid = fork();
        if (pid < 0) return 1;
        if (pid > 0) return 0;
        setsid();
    }

    int listen_fd = make_listener(sock);
    if (listen_fd < 0) {
        perror("xios-audiod: listen");
        return 1;
    }
    /* Best effort: a failed session activation should not be fatal, since the
     * default category can still produce sound; we just lose mute-switch and
     * lock-screen robustness. Log and continue. */
    xios_audio_session_activate();
    if (start_audio_unit() < 0) {
        close(listen_fd);
        unlink(sock);
        return 1;
    }
    fprintf(stderr, "xios-audiod: listening on %s\n", sock);

    while (!g_stop) {
        int fd = accept(listen_fd, NULL, NULL);
        if (fd < 0) {
            if (g_dump_stats) {
                g_dump_stats = 0;
                dump_stats();
            }
            if (errno == EINTR) continue;
            break;
        }
        client *c = (client *)calloc(1, sizeof(*c));
        if (!c) {
            close(fd);
            continue;
        }
        c->fd = fd;
        pthread_t th;
        if (pthread_create(&th, NULL, client_thread, c) != 0) {
            client_free(c);
            continue;
        }
        pthread_detach(th);
    }

    close(listen_fd);
    unlink(sock);
    stop_audio_unit();
    return 0;
}

