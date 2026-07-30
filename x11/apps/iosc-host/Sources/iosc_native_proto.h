/*
 * Native per-window host protocol.
 *
 * The wire layout, version, message registry, fence size, and flags live in the
 * shared protocol header used by both the host and compositor. Protocol v1
 * requires a BIND with window_id=XIOS_PROTOCOL_VERSION, followed by a matching
 * HELLO, before any WINDOW_* records. Every NATIVE_FRAME carries a brokered GPU
 * fence token and non-zero MTLSharedEvent value.
 */
#ifndef IOSC_NATIVE_PROTO_H
#define IOSC_NATIVE_PROTO_H

#include "../../shared/XiosProtocol.h"

#endif
