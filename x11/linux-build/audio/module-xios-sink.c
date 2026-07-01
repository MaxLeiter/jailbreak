/* module-xios-sink: PulseAudio sink that forwards rendered PCM to xios-audiod
 * (the fakesigned CoreAudio RemoteIO daemon) over its XIOA Unix-socket protocol.
 *
 * Clocking: xios-audiod reads as fast as clients write and mixes through a
 * drop-oldest ring, so the socket gives NO backpressure. A module-pipe-sink
 * style POLLOUT-clocked loop would free-run and shred the ring. This module is
 * therefore timer-clocked like module-null-sink: pa_rtclock drives rendering at
 * exactly real time, and the socket is just a dumb byte pipe. Long-term drift
 * between pa_rtclock and the device HAL clock is absorbed (crudely) by the
 * daemon's 4 s per-client ring.
 *
 * The sink is fixed at the daemon's native 48 kHz stereo, streamed as f32le
 * (PA renders float natively, and the daemon ingests XIOS_AUDIO_FMT_F32LE, so
 * nothing is converted twice). PA soft volume/mute apply before the payload is
 * written, so gvc/gnome-shell volume sliders work end to end.
 *
 * MIT, clean-room against the public PA module API (modeled on the structure
 * of module-null-sink).
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include <errno.h>
#include <fcntl.h>
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
#include <pulsecore/sink.h>
#include <pulsecore/thread-mq.h>
#include <pulsecore/thread.h>

#include "xios_audio_protocol.h"

PA_MODULE_AUTHOR("xios");
PA_MODULE_DESCRIPTION("Forward audio to xios-audiod (iOS CoreAudio RemoteIO daemon)");
PA_MODULE_VERSION(PACKAGE_VERSION);
PA_MODULE_LOAD_ONCE(false);
PA_MODULE_USAGE(
        "sink_name=<name of sink> "
        "sink_properties=<properties for the sink> "
        "socket=<path of xios-audiod socket>");

#define DEFAULT_SINK_NAME "xios"
#define BLOCK_USEC (25 * PA_USEC_PER_MSEC)
#define RECONNECT_USEC (2 * PA_USEC_PER_SEC)
/* Bounded wait to finish a half-written message on EAGAIN: the XIOA stream
 * has no resync marker, so a message must complete or the connection must be
 * torn down. The daemon reads greedily, so this all but never triggers. */
#define WRITE_STALL_MSEC 100

struct userdata {
    pa_core *core;
    pa_module *module;
    pa_sink *sink;

    pa_thread *thread;
    pa_thread_mq thread_mq;
    pa_rtpoll *rtpoll;

    char *socket_path;
    int fd;                     /* connected + OPEN sent, or -1 */
    pa_usec_t next_connect;     /* rtclock time of the next connect attempt */
    bool warned;                /* "daemon not reachable" logged once per outage */

    pa_usec_t block_usec;
    pa_usec_t timestamp;
};

static const char* const valid_modargs[] = {
    "sink_name",
    "sink_properties",
    "socket",
    NULL
};

/* --- socket plumbing (IO thread only) ------------------------------------ */

static void xios_disconnect(struct userdata *u, pa_usec_t now) {
    if (u->fd >= 0) {
        pa_close(u->fd);
        u->fd = -1;
    }
    u->next_connect = now + RECONNECT_USEC;
}

static int write_full(struct userdata *u, const void *data, size_t len) {
    const uint8_t *p = data;
    int stalled = 0;

    while (len > 0) {
        ssize_t n = pa_write(u->fd, p, len, NULL);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                struct pollfd pfd;
                pfd.fd = u->fd;
                pfd.events = POLLOUT;
                pfd.revents = 0;
                if (stalled++ > 0 || pa_poll(&pfd, 1, WRITE_STALL_MSEC) <= 0)
                    return -1;
                continue;
            }
            return -1;
        }

        p += n;
        len -= (size_t) n;
    }

    return 0;
}

static int xios_send(struct userdata *u, uint32_t type, const void *payload, uint32_t size) {
    xios_audio_msg msg;

    msg.magic = XIOS_AUDIO_MAGIC;
    msg.version = XIOS_AUDIO_VERSION;
    msg.type = type;
    msg.size = size;

    if (write_full(u, &msg, sizeof(msg)) < 0)
        return -1;
    if (size > 0 && write_full(u, payload, size) < 0)
        return -1;
    return 0;
}

static void xios_try_connect(struct userdata *u, pa_usec_t now) {
    struct sockaddr_un sa;
    xios_audio_open open_msg;
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
            pa_log_warn("xios-audiod not reachable at %s (%s); sink runs silent, retrying every %llu s",
                        u->socket_path, pa_cstrerror(errno),
                        (unsigned long long) (RECONNECT_USEC / PA_USEC_PER_SEC));
            u->warned = true;
        }
        pa_close(fd);
        return;
    }

    pa_make_fd_nonblock(fd);
    u->fd = fd;

    open_msg.sample_rate = u->sink->sample_spec.rate;
    open_msg.channels = u->sink->sample_spec.channels;
    open_msg.format = XIOS_AUDIO_FMT_F32LE;
    open_msg.flags = 0;

    if (xios_send(u, XIOS_AUDIO_MSG_OPEN, &open_msg, sizeof(open_msg)) < 0) {
        pa_log_warn("failed to send OPEN to %s: %s", u->socket_path, pa_cstrerror(errno));
        xios_disconnect(u, now);
        return;
    }

    pa_log_info("connected to xios-audiod at %s (%u Hz, %u ch, f32le)",
                u->socket_path, u->sink->sample_spec.rate, u->sink->sample_spec.channels);
    u->warned = false;
}

/* --- sink callbacks ------------------------------------------------------- */

static int sink_process_msg(pa_msgobject *o, int code, void *data, int64_t offset, pa_memchunk *chunk) {
    struct userdata *u = PA_SINK(o)->userdata;

    switch (code) {
        case PA_SINK_MESSAGE_GET_LATENCY: {
            pa_usec_t now = pa_rtclock_now();
            *((int64_t*) data) = (int64_t) u->timestamp - (int64_t) now;
            return 0;
        }
    }

    return pa_sink_process_msg(o, code, data, offset, chunk);
}

/* Called from the IO thread. Reset the render clock on resume so we do not
 * try to "catch up" across a suspend gap with a burst of stale audio. */
static int sink_set_state_in_io_thread_cb(pa_sink *s, pa_sink_state_t new_state, pa_suspend_cause_t new_suspend_cause) {
    struct userdata *u;

    pa_assert(s);
    pa_assert_se(u = s->userdata);

    if (s->thread_info.state == PA_SINK_SUSPENDED || s->thread_info.state == PA_SINK_INIT) {
        if (PA_SINK_IS_OPENED(new_state))
            u->timestamp = pa_rtclock_now();
    }

    return 0;
}

static void process_render(struct userdata *u, pa_usec_t now) {
    pa_assert(u);

    xios_try_connect(u, now);

    while (u->timestamp < now + u->block_usec) {
        pa_memchunk chunk;

        pa_sink_render(u->sink, u->sink->thread_info.max_request, &chunk);

        if (u->fd >= 0) {
            void *p = pa_memblock_acquire(chunk.memblock);
            int r = xios_send(u, XIOS_AUDIO_MSG_DATA,
                              (uint8_t *) p + chunk.index, (uint32_t) chunk.length);
            pa_memblock_release(chunk.memblock);

            if (r < 0) {
                pa_log_warn("write to xios-audiod failed (%s), reconnecting", pa_cstrerror(errno));
                xios_disconnect(u, now);
            }
        }

        u->timestamp += pa_bytes_to_usec(chunk.length, &u->sink->sample_spec);
        pa_memblock_unref(chunk.memblock);
    }
}

static void thread_func(void *userdata) {
    struct userdata *u = userdata;

    pa_assert(u);

    pa_log_debug("xios-sink IO thread starting up");
    pa_thread_mq_install(&u->thread_mq);

    u->timestamp = pa_rtclock_now();

    for (;;) {
        int ret;

        if (PA_SINK_IS_OPENED(u->sink->thread_info.state)) {
            pa_usec_t now;

            if (u->sink->thread_info.rewind_requested)
                pa_sink_process_rewind(u->sink, 0);

            now = pa_rtclock_now();
            if (u->timestamp <= now)
                process_render(u, now);

            pa_rtpoll_set_timer_absolute(u->rtpoll, u->timestamp);
        } else
            pa_rtpoll_set_timer_disabled(u->rtpoll);

        if ((ret = pa_rtpoll_run(u->rtpoll)) < 0)
            goto fail;

        if (ret == 0)
            goto finish;
    }

fail:
    /* If this was ever to happen, ensure the module gets unloaded */
    pa_asyncmsgq_post(u->thread_mq.outq, PA_MSGOBJECT(u->core), PA_CORE_MESSAGE_UNLOAD_MODULE, u->module, 0, NULL, NULL);
    pa_asyncmsgq_wait_for(u->thread_mq.inq, PA_MESSAGE_SHUTDOWN);

finish:
    pa_log_debug("xios-sink IO thread shutting down");
}

/* --- module entry points -------------------------------------------------- */

int pa__init(pa_module *m) {
    struct userdata *u = NULL;
    pa_sample_spec ss;
    pa_channel_map map;
    pa_modargs *ma = NULL;
    pa_sink_new_data data;

    pa_assert(m);

    if (!(ma = pa_modargs_new(m->argument, valid_modargs))) {
        pa_log("Failed to parse module arguments.");
        goto fail;
    }

    /* The daemon's native format: it mixes everything into 48 kHz stereo, and
     * f32le payloads are forwarded without a conversion pass on either side. */
    ss.format = PA_SAMPLE_FLOAT32LE;
    ss.rate = XIOS_AUDIO_DEFAULT_RATE;
    ss.channels = XIOS_AUDIO_DEFAULT_CHANNELS;
    pa_channel_map_init_stereo(&map);

    u = pa_xnew0(struct userdata, 1);
    u->core = m->core;
    u->module = m;
    m->userdata = u;
    u->fd = -1;
    u->socket_path = pa_xstrdup(pa_modargs_get_value(ma, "socket", XIOS_AUDIO_DEFAULT_SOCKET));
    u->block_usec = BLOCK_USEC;

    u->rtpoll = pa_rtpoll_new();

    if (pa_thread_mq_init(&u->thread_mq, m->core->mainloop, u->rtpoll) < 0) {
        pa_log("pa_thread_mq_init() failed.");
        goto fail;
    }

    pa_sink_new_data_init(&data);
    data.driver = __FILE__;
    data.module = m;
    pa_sink_new_data_set_name(&data, pa_modargs_get_value(ma, "sink_name", DEFAULT_SINK_NAME));
    pa_sink_new_data_set_sample_spec(&data, &ss);
    pa_sink_new_data_set_channel_map(&data, &map);
    pa_proplist_sets(data.proplist, PA_PROP_DEVICE_STRING, u->socket_path);
    pa_proplist_sets(data.proplist, PA_PROP_DEVICE_DESCRIPTION, "iPad speakers (xios-audiod)");
    pa_proplist_sets(data.proplist, PA_PROP_DEVICE_CLASS, "sound");

    if (pa_modargs_get_proplist(ma, "sink_properties", data.proplist, PA_UPDATE_REPLACE) < 0) {
        pa_log("Invalid properties");
        pa_sink_new_data_done(&data);
        goto fail;
    }

    u->sink = pa_sink_new(m->core, &data, PA_SINK_LATENCY);
    pa_sink_new_data_done(&data);

    if (!u->sink) {
        pa_log("Failed to create sink object.");
        goto fail;
    }

    u->sink->parent.process_msg = sink_process_msg;
    u->sink->set_state_in_io_thread = sink_set_state_in_io_thread_cb;
    u->sink->userdata = u;

    pa_sink_set_asyncmsgq(u->sink, u->thread_mq.inq);
    pa_sink_set_rtpoll(u->sink, u->rtpoll);

    pa_sink_set_fixed_latency(u->sink, u->block_usec);
    pa_sink_set_max_request(u->sink, pa_usec_to_bytes(u->block_usec, &u->sink->sample_spec));

    if (!(u->thread = pa_thread_new("xios-sink", thread_func, u))) {
        pa_log("Failed to create thread.");
        goto fail;
    }

    pa_sink_put(u->sink);

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

    if (u->sink)
        pa_sink_unlink(u->sink);

    if (u->thread) {
        pa_asyncmsgq_send(u->thread_mq.inq, NULL, PA_MESSAGE_SHUTDOWN, NULL, 0, NULL);
        pa_thread_free(u->thread);
    }

    pa_thread_mq_done(&u->thread_mq);

    if (u->sink)
        pa_sink_unref(u->sink);

    if (u->rtpoll)
        pa_rtpoll_free(u->rtpoll);

    if (u->fd >= 0)
        pa_close(u->fd);

    pa_xfree(u->socket_path);
    pa_xfree(u);
}
