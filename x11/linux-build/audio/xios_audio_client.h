#ifndef XIOS_AUDIO_CLIENT_H
#define XIOS_AUDIO_CLIENT_H

#include <stddef.h>
#include <stdint.h>

typedef struct xios_audio_conn xios_audio_conn;

xios_audio_conn *xios_audio_connect(const char *path, uint32_t rate,
                                    uint32_t channels, uint32_t format);
int xios_audio_write(xios_audio_conn *conn, const void *data, size_t bytes);
int xios_audio_drain(xios_audio_conn *conn);
void xios_audio_close(xios_audio_conn *conn);

#endif

