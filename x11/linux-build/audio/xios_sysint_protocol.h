#ifndef XIOS_SYSINT_PROTOCOL_H
#define XIOS_SYSINT_PROTOCOL_H

#include <stdint.h>

/* Minimal twin of wayland/xios_input_socket.h for PulseAudio modules. Keep the
 * fixed 24-byte layout and volume constants in sync with the canonical header. */
#define XIOS_IN_VOLUME 12u
#define XIOS_VOLUME_STATE_TO_DEVICE 1u

struct xios_in_msg {
    uint32_t type;
    int32_t  x, y;
    uint32_t code;
    uint32_t state;
    uint32_t mods;
};

#endif /* XIOS_SYSINT_PROTOCOL_H */
