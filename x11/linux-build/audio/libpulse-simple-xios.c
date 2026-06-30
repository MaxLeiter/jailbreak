#include "xios_audio_client.h"
#include "xios_audio_protocol.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <pulse/error.h>
#include <pulse/sample.h>
#include <pulse/simple.h>

struct pa_simple {
    xios_audio_conn *conn;
    pa_sample_spec spec;
};

static void set_error(int *error, int value) {
    if (error) *error = value;
}

const char *pa_strerror(int error) {
    switch (error) {
        case PA_OK: return "OK";
        case PA_ERR_INVALID: return "Invalid argument";
        case PA_ERR_CONNECTIONREFUSED: return "Connection refused";
        case PA_ERR_NOTSUPPORTED: return "Not supported";
        case PA_ERR_IO: return "I/O error";
        default: return "PulseAudio compatibility error";
    }
}

static uint32_t xios_format_from_pa(pa_sample_format_t fmt) {
    switch (fmt) {
        case PA_SAMPLE_S16LE: return XIOS_AUDIO_FMT_S16LE;
        case PA_SAMPLE_FLOAT32LE: return XIOS_AUDIO_FMT_F32LE;
        default: return 0;
    }
}

pa_simple *pa_simple_new(const char *server, const char *name,
                         pa_stream_direction_t dir, const char *dev,
                         const char *stream_name,
                         const pa_sample_spec *ss,
                         const pa_channel_map *map,
                         const pa_buffer_attr *attr,
                         int *error) {
    (void)name;
    (void)dev;
    (void)stream_name;
    (void)map;
    (void)attr;

    if (dir != PA_STREAM_PLAYBACK || !ss || !ss->rate || !ss->channels) {
        set_error(error, PA_ERR_INVALID);
        return NULL;
    }

    uint32_t format = xios_format_from_pa(ss->format);
    if (!format) {
        set_error(error, PA_ERR_NOTSUPPORTED);
        return NULL;
    }

    const char *path = server;
    if (!path || !path[0]) path = getenv("XIOS_AUDIO_SERVER");
    if (!path || !path[0]) path = XIOS_AUDIO_DEFAULT_SOCKET;
    if (!strncmp(path, "unix:", 5)) path += 5;

    xios_audio_conn *conn = xios_audio_connect(path, ss->rate, ss->channels, format);
    if (!conn) {
        set_error(error, errno == ECONNREFUSED ? PA_ERR_CONNECTIONREFUSED : PA_ERR_IO);
        return NULL;
    }

    pa_simple *s = (pa_simple *)calloc(1, sizeof(*s));
    if (!s) {
        xios_audio_close(conn);
        set_error(error, PA_ERR_IO);
        return NULL;
    }
    s->conn = conn;
    s->spec = *ss;
    set_error(error, PA_OK);
    return s;
}

void pa_simple_free(pa_simple *s) {
    if (!s) return;
    xios_audio_close(s->conn);
    free(s);
}

int pa_simple_write(pa_simple *s, const void *data, size_t bytes, int *error) {
    if (!s || !s->conn || (!data && bytes)) {
        set_error(error, PA_ERR_INVALID);
        return -1;
    }
    if (xios_audio_write(s->conn, data, bytes) < 0) {
        set_error(error, PA_ERR_IO);
        return -1;
    }
    set_error(error, PA_OK);
    return 0;
}

int pa_simple_drain(pa_simple *s, int *error) {
    if (!s || !s->conn) {
        set_error(error, PA_ERR_INVALID);
        return -1;
    }
    if (xios_audio_drain(s->conn) < 0) {
        set_error(error, PA_ERR_IO);
        return -1;
    }
    set_error(error, PA_OK);
    return 0;
}

int pa_simple_flush(pa_simple *s, int *error) {
    if (!s) {
        set_error(error, PA_ERR_INVALID);
        return -1;
    }
    set_error(error, PA_OK);
    return 0;
}

int pa_simple_read(pa_simple *s, void *data, size_t bytes, int *error) {
    (void)s;
    (void)data;
    (void)bytes;
    set_error(error, PA_ERR_NOTSUPPORTED);
    return -1;
}

pa_usec_t pa_simple_get_latency(pa_simple *s, int *error) {
    if (!s) {
        set_error(error, PA_ERR_INVALID);
        return 0;
    }
    set_error(error, PA_OK);
    return 20000;
}

const char *pa_get_library_version(void) {
    return "xios-pulse-simple-1";
}
