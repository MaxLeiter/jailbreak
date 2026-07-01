/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-keymap-ios.c — the MetaSeatIOS keymap (text direction only). GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-keymap-ios.h"

struct _MetaKeymapIOS
{
  ClutterKeymap parent;
};

G_DEFINE_TYPE (MetaKeymapIOS, meta_keymap_ios, CLUTTER_TYPE_KEYMAP)

static ClutterTextDirection
meta_keymap_ios_get_direction (ClutterKeymap *keymap)
{
  return CLUTTER_TEXT_DIRECTION_LTR;
}

static void
meta_keymap_ios_init (MetaKeymapIOS *self)
{
}

static void
meta_keymap_ios_class_init (MetaKeymapIOSClass *klass)
{
  ClutterKeymapClass *keymap_class = CLUTTER_KEYMAP_CLASS (klass);

  keymap_class->get_direction = meta_keymap_ios_get_direction;
}
