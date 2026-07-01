/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-keymap-ios.h — a minimal ClutterKeymap for MetaSeatIOS.
 *
 * The concrete keymaps (MetaKeymapNative/MetaKeymapX11) are compiled out with
 * native_backend=false / need an X display, so MetaSeatIOS supplies this one. ClutterKeymap
 * has a single vfunc (get_direction); the actual key translation is done by the compositor's
 * xkb state (iosc_input's "us" layout), so this only reports text direction. GPL-2.0+.
 */
#pragma once

#include "clutter/clutter.h"

#define META_TYPE_KEYMAP_IOS (meta_keymap_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaKeymapIOS, meta_keymap_ios, META, KEYMAP_IOS, ClutterKeymap)
