/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-virtual-input-device-ios.c — inject the input pump's events into Clutter.
 *
 * The native virtual device (meta-virtual-input-device-native.c) dispatches onto the
 * libinput input-thread + evdev button tables; with native_backend=false that machinery is
 * gone. Instead this builds ClutterEvents with the clutter-mutter constructors and pushes
 * them straight onto the event queue with _clutter_event_push() — enough for a synthetic
 * pointer+keyboard fed by the Xios input socket (meta-input-ios.c). The source device and
 * current pointer state come from the base ClutterSeat API, so this is independent of the
 * concrete MetaSeatIOS. GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-virtual-input-device-ios.h"

#include "clutter/clutter.h"
#include "clutter/clutter-mutter.h"

/* evdev button codes the pump forwards, mapped to Clutter logical buttons. */
#define IOS_BTN_LEFT   0x110
#define IOS_BTN_RIGHT  0x111
#define IOS_BTN_MIDDLE 0x112

struct _MetaVirtualInputDeviceIOS
{
  ClutterVirtualInputDevice parent;
};

G_DEFINE_TYPE (MetaVirtualInputDeviceIOS, meta_virtual_input_device_ios,
               CLUTTER_TYPE_VIRTUAL_INPUT_DEVICE)

static int64_t
resolve_time (uint64_t time_us)
{
  if (time_us == CLUTTER_CURRENT_TIME)
    return g_get_monotonic_time ();
  return (int64_t) time_us;
}

static void
meta_virtual_input_device_ios_notify_absolute_motion (ClutterVirtualInputDevice *virtual_device,
                                                      uint64_t                   time_us,
                                                      double                     x,
                                                      double                     y)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = GRAPHENE_POINT_INIT ((float) x, (float) y);
  graphene_point_t zero = GRAPHENE_POINT_INIT (0.f, 0.f);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, NULL, &modifiers);

  event = clutter_event_motion_new (CLUTTER_EVENT_NONE, resolve_time (time_us),
                                    pointer, NULL, modifiers, coords,
                                    zero, zero, zero, NULL);
  _clutter_event_push (event, FALSE);
}

static void
meta_virtual_input_device_ios_notify_relative_motion (ClutterVirtualInputDevice *virtual_device,
                                                      uint64_t                   time_us,
                                                      double                     dx,
                                                      double                     dy)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = GRAPHENE_POINT_INIT (0.f, 0.f);
  graphene_point_t delta = GRAPHENE_POINT_INIT ((float) dx, (float) dy);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, &coords, &modifiers);
  coords.x += (float) dx;
  coords.y += (float) dy;

  event = clutter_event_motion_new (CLUTTER_EVENT_NONE, resolve_time (time_us),
                                    pointer, NULL, modifiers, coords,
                                    delta, delta, delta, NULL);
  _clutter_event_push (event, FALSE);
}

static void
meta_virtual_input_device_ios_notify_button (ClutterVirtualInputDevice *virtual_device,
                                             uint64_t                   time_us,
                                             uint32_t                   button,
                                             ClutterButtonState         button_state)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = GRAPHENE_POINT_INIT (0.f, 0.f);
  ClutterModifierType modifiers = 0;
  ClutterEventType type;
  uint32_t clutter_button;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, &coords, &modifiers);

  switch (button)
    {
    case IOS_BTN_LEFT:   clutter_button = CLUTTER_BUTTON_PRIMARY;   break;
    case IOS_BTN_MIDDLE: clutter_button = CLUTTER_BUTTON_MIDDLE;    break;
    case IOS_BTN_RIGHT:  clutter_button = CLUTTER_BUTTON_SECONDARY; break;
    default:             clutter_button = button;                  break;
    }

  type = (button_state == CLUTTER_BUTTON_STATE_PRESSED)
    ? CLUTTER_BUTTON_PRESS : CLUTTER_BUTTON_RELEASE;

  event = clutter_event_button_new (type, CLUTTER_EVENT_NONE, resolve_time (time_us),
                                    pointer, NULL, modifiers, coords,
                                    clutter_button, button, NULL);
  _clutter_event_push (event, FALSE);
}

static void
meta_virtual_input_device_ios_notify_key (ClutterVirtualInputDevice *virtual_device,
                                          uint64_t                   time_us,
                                          uint32_t                   key,
                                          ClutterKeyState            key_state)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *keyboard = clutter_seat_get_keyboard (seat);
  ClutterModifierSet raw_modifiers = { 0 };
  ClutterEventType type;
  ClutterEvent *event;

  /* `key` is an evdev keycode (xkb keycode - 8). The keyval is resolved downstream from
   * the seat keymap; the pump's text path uses notify_keyval instead, which is exact. */
  type = (key_state == CLUTTER_KEY_STATE_PRESSED)
    ? CLUTTER_KEY_PRESS : CLUTTER_KEY_RELEASE;

  event = clutter_event_key_new (type, CLUTTER_EVENT_NONE, resolve_time (time_us),
                                 keyboard, raw_modifiers, 0,
                                 0 /* keyval (resolved downstream) */,
                                 key /* evcode */, key + 8 /* keycode */, 0);
  _clutter_event_push (event, FALSE);
}

static void
meta_virtual_input_device_ios_notify_keyval (ClutterVirtualInputDevice *virtual_device,
                                             uint64_t                   time_us,
                                             uint32_t                   keyval,
                                             ClutterKeyState            key_state)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *keyboard = clutter_seat_get_keyboard (seat);
  ClutterModifierSet raw_modifiers = { 0 };
  gunichar unicode;
  ClutterEventType type;
  ClutterEvent *event;

  /* ASCII keysyms equal their codepoint; others carry no unicode here (the keysym is
   * still authoritative for keybindings). */
  unicode = (keyval < 0x80) ? (gunichar) keyval : 0;

  type = (key_state == CLUTTER_KEY_STATE_PRESSED)
    ? CLUTTER_KEY_PRESS : CLUTTER_KEY_RELEASE;

  event = clutter_event_key_new (type, CLUTTER_EVENT_NONE, resolve_time (time_us),
                                 keyboard, raw_modifiers, 0,
                                 keyval, 0 /* evcode */, 0 /* keycode */, unicode);
  _clutter_event_push (event, FALSE);
}

static void
meta_virtual_input_device_ios_init (MetaVirtualInputDeviceIOS *self)
{
}

static void
meta_virtual_input_device_ios_class_init (MetaVirtualInputDeviceIOSClass *klass)
{
  ClutterVirtualInputDeviceClass *virtual_input_device_class =
    CLUTTER_VIRTUAL_INPUT_DEVICE_CLASS (klass);

  virtual_input_device_class->notify_absolute_motion =
    meta_virtual_input_device_ios_notify_absolute_motion;
  virtual_input_device_class->notify_relative_motion =
    meta_virtual_input_device_ios_notify_relative_motion;
  virtual_input_device_class->notify_button =
    meta_virtual_input_device_ios_notify_button;
  virtual_input_device_class->notify_key =
    meta_virtual_input_device_ios_notify_key;
  virtual_input_device_class->notify_keyval =
    meta_virtual_input_device_ios_notify_keyval;
  /* scroll + touch notify_* are left unset: the Xios input pump drives only pointer
   * motion/buttons and keys. */
}
