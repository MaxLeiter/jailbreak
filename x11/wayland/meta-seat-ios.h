/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-seat-ios.h — the MetaBackendIOS ClutterSeat.
 *
 * native_backend=false compiles out MetaSeatNative and MetaSeatX11 needs an X display, so
 * MetaBackendIOS supplies its own seat: synthetic pointer + keyboard devices, a minimal keymap
 * (MetaKeymapIOS), and a create_virtual_device that hands back a MetaVirtualInputDeviceIOS
 * (which the Xios input pump drives). No physical devices — all input is synthetic, injected
 * through the virtual device. GPL-2.0+, modeled on MetaSeatX11 minus the X server.
 */
#pragma once

#include <xkbcommon/xkbcommon.h>

#include "clutter/clutter.h"

#define META_TYPE_SEAT_IOS (meta_seat_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaSeatIOS, meta_seat_ios, META, SEAT_IOS, ClutterSeat)

ClutterSeat *meta_seat_ios_new (void);

/* The synthetic touchscreen core device (CLUTTER_INPUT_CAPABILITY_TOUCH, PHYSICAL mode),
 * registered on the seat's device list alongside the pointer/keyboard so
 * meta-wayland-seat.c's lookup_device_capabilities() advertises WL_SEAT_CAPABILITY_TOUCH to
 * clients. ClutterSeatClass has no get_touch vfunc (unlike get_pointer/get_keyboard), so this
 * is a MetaSeatIOS-specific accessor for meta-virtual-input-device-ios.c's touch events to use
 * as their source device. */
ClutterInputDevice *meta_seat_ios_get_touch (MetaSeatIOS *seat);

/* Build the key event for one transition of xkb `keycode` (0 = a keysym no key types, which
 * keeps `keyval`) the way the native seat's meta_key_event_new_from_evdev does: keysym,
 * unicode and modifiers come from the seat's xkb_state as it stood before this key, and the
 * key then updates that state. The state follows `keymap` and `layout` (the backend's
 * current map and locked group), and query_state reports its modifiers to pointer events. */
ClutterEvent *meta_seat_ios_key_event_new (MetaSeatIOS        *seat,
                                           ClutterInputDevice *device,
                                           int64_t             time_us,
                                           struct xkb_keymap  *keymap,
                                           xkb_layout_index_t  layout,
                                           xkb_keycode_t       keycode,
                                           uint32_t            keyval,
                                           gboolean            pressed);
