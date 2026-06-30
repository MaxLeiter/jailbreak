#ifndef PULSE_SIMPLE_H
#define PULSE_SIMPLE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <pulse/sample.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum pa_stream_direction {
    PA_STREAM_NODIRECTION,
    PA_STREAM_PLAYBACK,
    PA_STREAM_RECORD,
    PA_STREAM_UPLOAD
} pa_stream_direction_t;

typedef struct pa_simple pa_simple;
typedef struct pa_channel_map pa_channel_map;
typedef struct pa_buffer_attr pa_buffer_attr;
typedef uint64_t pa_usec_t;

pa_simple *pa_simple_new(const char *server, const char *name,
                         pa_stream_direction_t dir, const char *dev,
                         const char *stream_name,
                         const pa_sample_spec *ss,
                         const pa_channel_map *map,
                         const pa_buffer_attr *attr,
                         int *error);
void pa_simple_free(pa_simple *s);
int pa_simple_write(pa_simple *s, const void *data, size_t bytes, int *error);
int pa_simple_drain(pa_simple *s, int *error);
int pa_simple_flush(pa_simple *s, int *error);
int pa_simple_read(pa_simple *s, void *data, size_t bytes, int *error);
pa_usec_t pa_simple_get_latency(pa_simple *s, int *error);

#ifdef __cplusplus
}
#endif

#endif
