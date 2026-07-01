/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-seat-ios.h — the MetaBackendIOS ClutterSeat.
 *
 * native_backend=false compiles out MetaSeatNative and MetaSeatX11 needs an X display, so
 * MetaBackendIOS supplies its own seat: a logical core pointer + keyboard, a minimal keymap
 * (MetaKeymapIOS), and a create_virtual_device that hands back a MetaVirtualInputDeviceIOS
 * (which the Xios input pump drives). No physical devices — all input is synthetic, injected
 * through the virtual device. GPL-2.0+, modeled on MetaSeatX11 minus the X server.
 */
#pragma once

#include "clutter/clutter.h"

#define META_TYPE_SEAT_IOS (meta_seat_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaSeatIOS, meta_seat_ios, META, SEAT_IOS, ClutterSeat)

ClutterSeat *meta_seat_ios_new (void);
