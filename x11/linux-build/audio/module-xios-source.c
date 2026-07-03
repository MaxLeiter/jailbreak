/* module-xios-source: PulseAudio source that reads microphone PCM from
 * xios-mediad's Unix-socket media protocol.
 *
 * The iOS capture owner remains xios-mediad (fakesigned, TCC/RemoteIO). This
 * module only exposes that stream as a normal PulseAudio source so GNOME, gvc,
 * GStreamer pulsesrc, parec, WebKit, etc. can discover a microphone through
 * libpulse instead of learning any Xios-specific socket protocol.
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <pulse/rtclock.h>
#include <pulse/timeval.h>
#include <pulse/xmalloc.h>

#include <pulsecore/core-error.h>
#include <pulsecore/core-rtclock.h>
#include <pulsecore/core-util.h>
#include <pulsecore/log.h>
#include <pulsecore/macro.h>
#include <pulsecore/modargs.h>
#include <pulsecore/module.h>
#include <pulsecore/poll.h>
#include <pulsecore/rtpoll.h>
#include <pulsecore/source.h>
#include <pulsecore/thread-mq.h>
#include <pulsecore/thread.h>

#include "xios_media_protocol.h"

PA_MODULE_AUTHOR("xios");
PA_MODULE_DESCRIPTION("Expose xios-mediad microphone capture as a PulseAudio source");
PA_MODULE_VERSION(PACKAGE_VERSION);
PA_MODULE_LOAD_ONCE(false);
PA_MODULE_USAGE(
        "source_name=<name of source> "
        "source_properties=<properties for the source> "
        "socket=<path of xios-mediad mic socket>");

#define DEFAULT_SOURCE_NAME "xios_mic"
#define RECONNECT_USEC (2 * PA_USEC_PER_SEC)
#define POLL_TIMEOUT_MSEC 250

struct userdata {
    pa_core *core;
    pa_module *module;
    pa_source *source;

    pa_thread *thread;
    pa_thread_mq thread_mq;
    pa_rtpoll *rtpoll;

    char *socket_path;
    int fd;
    pa_usec_t next_connect;
    bool warned;
};

static const char* const valid_modargs[] = {
    "source_name",
    "source_properties",
    "socket",
    NULL
};

static void xios_disconnect(struct userdata *u, pa_usec_t now) {
    if (u->fd >= 0) {
        pa_close(u->fd);
        u->fd = -1;
    }
    u->next_connect = now + RECONNECT_USEC;
}

static int wait_readable(int fd) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
    int r;

    for (;;) {
        r = pa_poll(&pfd, 1, POLL_TIMEOUT_MSEC);
        if (r < 0 && errno == EINTR)
            continue;
        break;
    }

    if (r <= 0)
        return r;
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))
        return -1;
    return (pfd.revents & POLLIN) ? 1 : 0;
}

static int read_full(int fd, void *data, size_t len) {
    uint8_t *p = data;
    size_t done = 0;

    while (done < len) {
        ssize_t n = pa_read(fd, p + done, len - done, NULL);

        if (n > 0) {
            done += (size_t) n;
            continue;
        }
        if (n == 0)
            return -1;

        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            int r = wait_readable(fd);
            if (r <= 0)
                return r;
            continue;
        }
        return -1;
    }

    return 1;
}

static void skip_payload(int fd, uint32_t size) {
    uint8_t scratch[4096];

    while (size > 0) {
        size_t n = size < sizeof(scratch) ? size : sizeof(scratch);
        int r = read_full(fd, scratch, n);
        if (r <= 0)
            return;
        size -= (uint32_t) n;
    }
}

static void xios_try_connect(struct userdata *u, pa_usec_t now) {
    struct sockaddr_un sa;
    int fd;

    if (u->fd >= 0 || now < u->next_connect)
        return;
    u->next_connect = now + RECONNECT_USEC;

    if ((fd = pa_socket_cloexec(AF_UNIX, SOCK_STREAM, 0)) < 0)
        return;

    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    if (strlen(u->socket_path) >= sizeof(sa.sun_path)) {
        pa_close(fd);
        return;
    }
    strcpy(sa.sun_path, u->socket_path);

    if (connect(fd, (struct sockaddr *) &sa, sizeof(sa)) < 0) {
        if (!u->warned) {
            pa_log_warn("xios-mediad mic not reachable at %s (%s); source will retry every %llu s",
                        u->socket_path, pa_cstrerror(errno),
                        (unsigned long long) (RECONNECT_USEC / PA_USEC_PER_SEC));
            u->warned = true;
        }
        pa_close(fd);
        return;
    }

    pa_make_fd_nonblock(fd);
    u->fd = fd;
    u->warned = false;
    pa_log_info("connected to xios-mediad microphone at %s", u->socket_path);
}

static void post_mic_payload(struct userdata *u, const xios_media_mic_frame *frame, uint32_t payload_len) {
    pa_memchunk chunk;
    void *dst;

    if (frame->sample_rate != u->source->sample_spec.rate ||
        frame->channels != u->source->sample_spec.channels ||
        frame->format != XIOS_MEDIA_AUDIO_FMT_F32LE) {
        pa_log_warn("dropping unsupported xios mic frame: rate=%u channels=%u format=%u",
                    frame->sample_rate, frame->channels, frame->format);
        skip_payload(u->fd, payload_len);
        return;
    }

    chunk.memblock = pa_memblock_new(u->core->mempool, payload_len);
    chunk.index = 0;
    chunk.length = payload_len;
    dst = pa_memblock_acquire(chunk.memblock);

    if (read_full(u->fd, dst, payload_len) <= 0) {
        pa_memblock_release(chunk.memblock);
        pa_memblock_unref(chunk.memblock);
        xios_disconnect(u, pa_rtclock_now());
        return;
    }

    pa_memblock_release(chunk.memblock);
    pa_source_post(u->source, &chunk);
    pa_memblock_unref(chunk.memblock);
}

static void process_one_message(struct userdata *u) {
    xios_media_msg msg;
    xios_media_mic_frame frame;
    uint32_t payload_len;
    int r;

    r = read_full(u->fd, &msg, sizeof(msg));
    if (r == 0)
        return;
    if (r < 0) {
        xios_disconnect(u, pa_rtclock_now());
        return;
    }

    if (msg.magic != XIOS_MEDIA_MAGIC || msg.version != XIOS_MEDIA_VERSION) {
        pa_log_warn("bad xios media protocol header on mic socket; reconnecting");
        xios_disconnect(u, pa_rtclock_now());
        return;
    }

    if (msg.type != XIOS_MEDIA_MSG_MIC_FRAME) {
        skip_payload(u->fd, msg.size);
        return;
    }

    if (msg.size < sizeof(frame)) {
        pa_log_warn("short xios mic frame; reconnecting");
        xios_disconnect(u, pa_rtclock_now());
        return;
    }

    if (read_full(u->fd, &frame, sizeof(frame)) <= 0) {
        xios_disconnect(u, pa_rtclock_now());
        return;
    }

    payload_len = msg.size - (uint32_t) sizeof(frame);
    post_mic_payload(u, &frame, payload_len);
}

static int source_process_msg(pa_msgobject *o, int code, void *data, int64_t offset, pa_memchunk *chunk) {
    switch (code) {
        case PA_SOURCE_MESSAGE_GET_LATENCY:
            *((int64_t*) data) = 0;
            return 0;
    }

    return pa_source_process_msg(o, code, data, offset, chunk);
}

static void thread_func(void *userdata) {
    struct userdata *u = userdata;

    pa_assert(u);
    pa_log_debug("xios-source IO thread starting up");
    pa_thread_mq_install(&u->thread_mq);

    for (;;) {
        int ret;

        if (PA_SOURCE_IS_OPENED(u->source->thread_info.state)) {
            pa_usec_t now = pa_rtclock_now();
            xios_try_connect(u, now);
            if (u->fd >= 0)
                process_one_message(u);
            pa_rtpoll_set_timer_relative(u->rtpoll,
                                         u->fd >= 0 ? 0 : POLL_TIMEOUT_MSEC * PA_USEC_PER_MSEC);
        } else
            pa_rtpoll_set_timer_disabled(u->rtpoll);

        if ((ret = pa_rtpoll_run(u->rtpoll)) < 0)
            goto fail;
        if (ret == 0)
            goto finish;
    }

fail:
    pa_asyncmsgq_post(u->thread_mq.outq, PA_MSGOBJECT(u->core), PA_CORE_MESSAGE_UNLOAD_MODULE, u->module, 0, NULL, NULL);
    pa_asyncmsgq_wait_for(u->thread_mq.inq, PA_MESSAGE_SHUTDOWN);

finish:
    pa_log_debug("xios-source IO thread shutting down");
}

int pa__init(pa_module *m) {
    struct userdata *u = NULL;
    pa_sample_spec ss;
    pa_channel_map map;
    pa_modargs *ma = NULL;
    pa_source_new_data data;

    pa_assert(m);

    if (!(ma = pa_modargs_new(m->argument, valid_modargs))) {
        pa_log("Failed to parse module arguments.");
        goto fail;
    }

    ss.format = PA_SAMPLE_FLOAT32LE;
    ss.rate = XIOS_MEDIA_DEFAULT_AUDIO_RATE;
    ss.channels = XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS;
    pa_channel_map_init_mono(&map);

    u = pa_xnew0(struct userdata, 1);
    u->core = m->core;
    u->module = m;
    m->userdata = u;
    u->fd = -1;
    u->socket_path = pa_xstrdup(pa_modargs_get_value(ma, "socket", XIOS_MEDIA_DEFAULT_MIC_SOCKET));

    u->rtpoll = pa_rtpoll_new();
    if (pa_thread_mq_init(&u->thread_mq, m->core->mainloop, u->rtpoll) < 0) {
        pa_log("pa_thread_mq_init() failed.");
        goto fail;
    }

    pa_source_new_data_init(&data);
    data.driver = __FILE__;
    data.module = m;
    pa_source_new_data_set_name(&data, pa_modargs_get_value(ma, "source_name", DEFAULT_SOURCE_NAME));
    pa_source_new_data_set_sample_spec(&data, &ss);
    pa_source_new_data_set_channel_map(&data, &map);
    pa_proplist_sets(data.proplist, PA_PROP_DEVICE_STRING, u->socket_path);
    pa_proplist_sets(data.proplist, PA_PROP_DEVICE_DESCRIPTION, "iPad microphone (xios-mediad)");
    pa_proplist_sets(data.proplist, PA_PROP_DEVICE_CLASS, "sound");
    pa_proplist_sets(data.proplist, "media.class", "Audio/Source");

    if (pa_modargs_get_proplist(ma, "source_properties", data.proplist, PA_UPDATE_REPLACE) < 0) {
        pa_log("Invalid properties");
        pa_source_new_data_done(&data);
        goto fail;
    }

    u->source = pa_source_new(m->core, &data, PA_SOURCE_LATENCY);
    pa_source_new_data_done(&data);

    if (!u->source) {
        pa_log("Failed to create source object.");
        goto fail;
    }

    u->source->parent.process_msg = source_process_msg;
    u->source->userdata = u;
    pa_source_set_asyncmsgq(u->source, u->thread_mq.inq);
    pa_source_set_rtpoll(u->source, u->rtpoll);
    pa_source_set_fixed_latency(u->source, 25 * PA_USEC_PER_MSEC);

    if (!(u->thread = pa_thread_new("xios-source", thread_func, u))) {
        pa_log("Failed to create thread.");
        goto fail;
    }

    pa_source_put(u->source);
    pa_modargs_free(ma);
    return 0;

fail:
    if (ma)
        pa_modargs_free(ma);
    pa__done(m);
    return -1;
}

void pa__done(pa_module *m) {
    struct userdata *u;

    pa_assert(m);

    if (!(u = m->userdata))
        return;

    if (u->source)
        pa_source_unlink(u->source);

    if (u->thread) {
        pa_asyncmsgq_send(u->thread_mq.inq, NULL, PA_MESSAGE_SHUTDOWN, NULL, 0, NULL);
        pa_thread_free(u->thread);
    }

    pa_thread_mq_done(&u->thread_mq);

    if (u->source)
        pa_source_unref(u->source);
    if (u->rtpoll)
        pa_rtpoll_free(u->rtpoll);
    if (u->fd >= 0)
        pa_close(u->fd);

    pa_xfree(u->socket_path);
    pa_xfree(u);
}
