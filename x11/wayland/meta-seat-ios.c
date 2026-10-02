/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-seat-ios.c — the MetaBackendIOS ClutterSeat (synthetic input only).
 *
 * Two synthetic core devices (pointer + keyboard), a MetaKeymapIOS, and the 13 ClutterSeat
 * vfuncs implemented minimally: there is no hardware input to enumerate, so query_state
 * returns the last synthesized pointer position and create_virtual_device yields a
 * MetaVirtualInputDeviceIOS (the thing the Xios input pump pushes events into). Modeled on
 * MetaSeatX11 with the X server / XInput device enumeration removed. GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-seat-ios.h"

#include "backends/ios/meta-keymap-ios.h"
#include "backends/ios/meta-virtual-input-device-ios.h"
#include "clutter/clutter.h"
#include "clutter/clutter-mutter.h"

enum
{
  PROP_0,

  /* ClutterSeat property overridden by the always-touch-first iOS seat. */
  PROP_TOUCH_MODE,
};

struct _MetaSeatIOS
{
  ClutterSeat parent;

  ClutterInputDevice *core_pointer;
  ClutterInputDevice *core_keyboard;
  ClutterInputDevice *core_touch;   /* TOUCH capability, so wl_seat advertises touch */
  ClutterKeymap      *keymap;
  GList              *devices;      /* all three core devices, for peek_devices */

  graphene_point_t    pointer_pos;
  ClutterModifierType modifiers;     /* xkb_state's effective modifiers */

  /* The keyboard state key events are built from, as MetaSeatImpl keeps one for the native
   * seat. xkb_keymap holds a reference so a replacement map can never reuse its address. */
  struct xkb_keymap  *xkb_keymap;
  struct xkb_state   *xkb_state;
  xkb_layout_index_t  xkb_layout;
};

G_DEFINE_TYPE (MetaSeatIOS, meta_seat_ios, CLUTTER_TYPE_SEAT)

static void
meta_seat_ios_get_property (GObject    *object,
                            guint       prop_id,
                            GValue     *value,
                            GParamSpec *pspec)
{
  switch (prop_id)
    {
    case PROP_TOUCH_MODE:
      /* The iPad's built-in touchscreen remains available when a hardware
       * pointer or keyboard is attached, so pointer presence must not make
       * GNOME treat this seat as a non-touch desktop. */
      g_value_set_boolean (value, TRUE);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static ClutterInputDevice *
create_core_device (MetaSeatIOS              *self,
                    ClutterInputDeviceType    device_type,
                    const char               *name,
                    ClutterInputCapabilities  capabilities)
{
  return g_object_new (CLUTTER_TYPE_INPUT_DEVICE,
                       "name", name,
                       "device-type", device_type,
                       "capabilities", capabilities,
                       /* Mutter's Wayland seat deliberately ignores LOGICAL devices when
                        * advertising wl_seat capabilities and routing events to clients.
                        * These are synthetic, but they are the only user-facing devices the
                        * iOS backend has, so expose them as PHYSICAL to the Wayland layer. */
                       "device-mode", CLUTTER_INPUT_MODE_PHYSICAL,
                       "seat", self,
                       NULL);
}

static ClutterInputDevice *
meta_seat_ios_get_pointer (ClutterSeat *seat)
{
  return META_SEAT_IOS (seat)->core_pointer;
}

static ClutterInputDevice *
meta_seat_ios_get_keyboard (ClutterSeat *seat)
{
  return META_SEAT_IOS (seat)->core_keyboard;
}

static const GList *
meta_seat_ios_peek_devices (ClutterSeat *seat)
{
  return META_SEAT_IOS (seat)->devices;
}

static void
meta_seat_ios_bell_notify (ClutterSeat *seat)
{
}

static ClutterKeymap *
meta_seat_ios_get_keymap (ClutterSeat *seat)
{
  return META_SEAT_IOS (seat)->keymap;
}

static gboolean
meta_seat_ios_handle_event_post (ClutterSeat        *seat,
                                 const ClutterEvent *event)
{
  return FALSE;
}

static void
meta_seat_ios_warp_pointer (ClutterSeat *seat,
                            int          x,
                            int          y)
{
  MetaSeatIOS *self = META_SEAT_IOS (seat);

  self->pointer_pos = GRAPHENE_POINT_INIT ((float) x, (float) y);
}

static void
meta_seat_ios_init_pointer_position (ClutterSeat *seat,
                                     float        x,
                                     float        y)
{
  MetaSeatIOS *self = META_SEAT_IOS (seat);

  self->pointer_pos = GRAPHENE_POINT_INIT (x, y);
}

static gboolean
meta_seat_ios_query_state (ClutterSeat          *seat,
                           ClutterInputDevice   *device,
                           ClutterEventSequence *sequence,
                           graphene_point_t     *coords,
                           ClutterModifierType  *modifiers)
{
  MetaSeatIOS *self = META_SEAT_IOS (seat);

  if (coords)
    *coords = self->pointer_pos;
  if (modifiers)
    *modifiers = self->modifiers;

  return TRUE;
}

static ClutterGrabState
meta_seat_ios_grab (ClutterSeat *seat,
                    uint32_t     time)
{
  /* No hardware grabs on iOS — report full grab so Clutter's grab bookkeeping is happy. */
  return CLUTTER_GRAB_STATE_ALL;
}

static void
meta_seat_ios_ungrab (ClutterSeat *seat,
                      uint32_t     time)
{
}

static ClutterVirtualInputDevice *
meta_seat_ios_create_virtual_device (ClutterSeat            *seat,
                                     ClutterInputDeviceType  device_type)
{
  return g_object_new (META_TYPE_VIRTUAL_INPUT_DEVICE_IOS,
                       "seat", seat,
                       "device-type", device_type,
                       NULL);
}

static ClutterVirtualDeviceType
meta_seat_ios_get_supported_virtual_device_types (ClutterSeat *seat)
{
  return CLUTTER_VIRTUAL_DEVICE_TYPE_POINTER |
         CLUTTER_VIRTUAL_DEVICE_TYPE_KEYBOARD |
         CLUTTER_VIRTUAL_DEVICE_TYPE_TOUCHSCREEN;
}

static void
meta_seat_ios_constructed (GObject *object)
{
  MetaSeatIOS *self = META_SEAT_IOS (object);

  G_OBJECT_CLASS (meta_seat_ios_parent_class)->constructed (object);

  self->core_pointer = create_core_device (self, CLUTTER_POINTER_DEVICE,
                                           "Virtual core pointer",
                                           CLUTTER_INPUT_CAPABILITY_POINTER);
  self->core_keyboard = create_core_device (self, CLUTTER_KEYBOARD_DEVICE,
                                            "Virtual core keyboard",
                                            CLUTTER_INPUT_CAPABILITY_KEYBOARD);
  self->core_touch = create_core_device (self, CLUTTER_TOUCHSCREEN_DEVICE,
                                         "Virtual core touchscreen",
                                         CLUTTER_INPUT_CAPABILITY_TOUCH);
  self->devices = g_list_append (self->devices, self->core_pointer);
  self->devices = g_list_append (self->devices, self->core_keyboard);
  self->devices = g_list_append (self->devices, self->core_touch);

  self->keymap = g_object_new (META_TYPE_KEYMAP_IOS, NULL);

  /* Mutter's Wayland pointer path keeps focus on the seat's core pointer.
   * With no native input thread behind us, the iOS backend must make Clutter
   * repick that core pointer for every motion/button event instead of relying
   * on cached hardware state. */
  clutter_seat_inhibit_unfocus (CLUTTER_SEAT (self));
}

static void
meta_seat_ios_finalize (GObject *object)
{
  MetaSeatIOS *self = META_SEAT_IOS (object);

  g_clear_list (&self->devices, NULL);
  g_clear_object (&self->core_pointer);
  g_clear_object (&self->core_keyboard);
  g_clear_object (&self->core_touch);
  g_clear_object (&self->keymap);
  g_clear_pointer (&self->xkb_state, xkb_state_unref);
  g_clear_pointer (&self->xkb_keymap, xkb_keymap_unref);

  G_OBJECT_CLASS (meta_seat_ios_parent_class)->finalize (object);
}

static void
meta_seat_ios_init (MetaSeatIOS *self)
{
  self->pointer_pos = GRAPHENE_POINT_INIT (0.f, 0.f);
  self->modifiers = 0;
}

static void
meta_seat_ios_class_init (MetaSeatIOSClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  ClutterSeatClass *seat_class = CLUTTER_SEAT_CLASS (klass);

  object_class->get_property = meta_seat_ios_get_property;
  object_class->constructed = meta_seat_ios_constructed;
  object_class->finalize = meta_seat_ios_finalize;

  seat_class->get_pointer = meta_seat_ios_get_pointer;
  seat_class->get_keyboard = meta_seat_ios_get_keyboard;
  seat_class->peek_devices = meta_seat_ios_peek_devices;
  seat_class->bell_notify = meta_seat_ios_bell_notify;
  seat_class->get_keymap = meta_seat_ios_get_keymap;
  seat_class->handle_event_post = meta_seat_ios_handle_event_post;
  seat_class->warp_pointer = meta_seat_ios_warp_pointer;
  seat_class->init_pointer_position = meta_seat_ios_init_pointer_position;
  seat_class->query_state = meta_seat_ios_query_state;
  seat_class->grab = meta_seat_ios_grab;
  seat_class->ungrab = meta_seat_ios_ungrab;
  seat_class->create_virtual_device = meta_seat_ios_create_virtual_device;
  seat_class->get_supported_virtual_device_types =
    meta_seat_ios_get_supported_virtual_device_types;

  g_object_class_override_property (object_class, PROP_TOUCH_MODE,
                                    "touch-mode");
}

ClutterSeat *
meta_seat_ios_new (void)
{
  return g_object_new (META_TYPE_SEAT_IOS, NULL);
}

ClutterInputDevice *
meta_seat_ios_get_touch (MetaSeatIOS *seat)
{
  g_return_val_if_fail (META_IS_SEAT_IOS (seat), NULL);

  return seat->core_touch;
}

/* Follow the backend's keymap and locked layout group. A new map starts a new state that
 * keeps the latched and locked modifiers, as the native seat's set_keyboard_map does. */
static void
sync_xkb_state (MetaSeatIOS        *self,
                struct xkb_keymap  *keymap,
                xkb_layout_index_t  layout)
{
  xkb_mod_mask_t depressed = 0, latched = 0, locked = 0;

  if (keymap == self->xkb_keymap && layout == self->xkb_layout)
    return;

  if (self->xkb_state)
    {
      depressed = xkb_state_serialize_mods (self->xkb_state, XKB_STATE_MODS_DEPRESSED);
      latched = xkb_state_serialize_mods (self->xkb_state, XKB_STATE_MODS_LATCHED);
      locked = xkb_state_serialize_mods (self->xkb_state, XKB_STATE_MODS_LOCKED);
    }

  if (keymap != self->xkb_keymap)
    {
      depressed = 0;
      g_clear_pointer (&self->xkb_state, xkb_state_unref);
      g_clear_pointer (&self->xkb_keymap, xkb_keymap_unref);
      if (keymap)
        {
          self->xkb_keymap = xkb_keymap_ref (keymap);
          self->xkb_state = xkb_state_new (keymap);
        }
    }

  self->xkb_layout = layout;
  if (self->xkb_state)
    xkb_state_update_mask (self->xkb_state, depressed, latched, locked, 0, 0, layout);
  self->modifiers = self->xkb_state
    ? xkb_state_serialize_mods (self->xkb_state, XKB_STATE_MODS_EFFECTIVE) : 0;
}

ClutterEvent *
meta_seat_ios_key_event_new (MetaSeatIOS        *seat,
                             ClutterInputDevice *device,
                             int64_t             time_us,
                             struct xkb_keymap  *keymap,
                             xkb_layout_index_t  layout,
                             xkb_keycode_t       keycode,
                             uint32_t            keyval,
                             gboolean            pressed)
{
  ClutterModifierSet raw_modifiers = { 0 };
  ClutterModifierType modifiers = 0;
  gunichar unicode;
  ClutterEvent *event;

  g_return_val_if_fail (META_IS_SEAT_IOS (seat), NULL);

  /* ASCII keysyms equal their codepoint; a keysym without a key carries no unicode (it is
   * still authoritative for keybindings). */
  unicode = (keyval < 0x80) ? (gunichar) keyval : 0;

  sync_xkb_state (seat, keymap, layout);
  if (seat->xkb_state)
    {
      raw_modifiers = (ClutterModifierSet) {
        .pressed = xkb_state_serialize_mods (seat->xkb_state, XKB_STATE_MODS_DEPRESSED),
        .latched = xkb_state_serialize_mods (seat->xkb_state, XKB_STATE_MODS_LATCHED),
        .locked = xkb_state_serialize_mods (seat->xkb_state, XKB_STATE_MODS_LOCKED),
      };
      modifiers = xkb_state_serialize_mods (seat->xkb_state, XKB_STATE_MODS_EFFECTIVE);

      if (keycode)
        {
          xkb_keysym_t sym = xkb_state_key_get_one_sym (seat->xkb_state, keycode);
          char buffer[8];
          int n;

          if (sym != XKB_KEY_NoSymbol)
            keyval = sym;
          n = xkb_keysym_to_utf8 (keyval, buffer, sizeof (buffer));
          unicode = (n > 0) ? g_utf8_get_char_validated (buffer, n) : 0;
          if (unicode == (gunichar) -1 || unicode == (gunichar) -2)
            unicode = 0;
        }
    }

  event = clutter_event_key_new (pressed ? CLUTTER_KEY_PRESS : CLUTTER_KEY_RELEASE,
                                 CLUTTER_EVENT_NONE, time_us, device,
                                 raw_modifiers, modifiers, keyval,
                                 keycode ? keycode - 8 : 0 /* evcode */, keycode, unicode);

  if (seat->xkb_state && keycode)
    {
      xkb_state_update_key (seat->xkb_state, keycode, pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
      seat->modifiers = xkb_state_serialize_mods (seat->xkb_state, XKB_STATE_MODS_EFFECTIVE);
    }

  return event;
}
