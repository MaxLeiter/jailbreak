/*
 * iosc_input.h — xkb "us" keymap + X-keysym→evdev-keycode reverse map for iosc's
 * wl_keyboard. Built once from libxkbcommon (the xkb data lives on-device at
 * /var/jb/usr/share/X11/xkb). iosc sends the keymap string to clients via
 * wl_keyboard.keymap, and turns the app's X keysyms into (evdev keycode + Shift)
 * so wl_keyboard.key carries codes that fit the keymap the client was handed.
 */
#ifndef IOSC_INPUT_H
#define IOSC_INPUT_H

#include <stdint.h>

/* Load the "us" keymap (rules=evdev, model=pc105). 0 on success; nonzero => no
 * keyboard (caller should advertise pointer-only). */
int iosc_input_init(void);

/* The keymap as an XKB_V1 text string (NUL-terminated) + the size to pass to
 * wl_keyboard.keymap (strlen + 1, the client mmaps including the NUL). */
const char *iosc_input_keymap_string(void);
uint32_t    iosc_input_keymap_size(void);

/* Map an X keysym (e.g. 'a'=0x61, XK_Return=0xff0d) to the Linux evdev keycode to
 * put in wl_keyboard.key (= xkb keycode − 8) and whether Shift is needed to reach
 * that symbol's level. Returns 0 on success, −1 if the keysym isn't in the keymap. */
int iosc_input_lookup(uint32_t keysym, uint32_t *evdev_keycode, int *needs_shift);

/* xkb modifier MASKS (1<<index) for the loaded keymap, for wl_keyboard.modifiers. */
uint32_t iosc_input_mod_shift(void);
uint32_t iosc_input_mod_ctrl(void);
uint32_t iosc_input_mod_alt(void);

#endif /* IOSC_INPUT_H */
