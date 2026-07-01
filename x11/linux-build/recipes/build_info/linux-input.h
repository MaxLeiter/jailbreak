/* iOS shim for <linux/input.h>. Xwayland's xwayland-input.c includes
 * <linux/input.h> only for the evdev event codes (BTN_*, KEY_*) that the
 * Wayland input protocol uses; it does NOT use struct input_event, the ioctls,
 * or input_absinfo (verified: no struct/EVIOC usage). So this wrapper just
 * pulls in the canonical input-event-codes.h (vendored, exact kernel values —
 * they MUST match what the compositor sends over wl_pointer/wl_keyboard).
 * The kernel header is GPL-2.0 WITH Linux-syscall-note, which permits use in
 * non-GPL programs. */
#ifndef _LINUX_INPUT_H_IOS_SHIM
#define _LINUX_INPUT_H_IOS_SHIM
#include <linux/input-event-codes.h>
#endif
