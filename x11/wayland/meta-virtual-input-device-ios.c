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

#include "backends/ios/meta-seat-ios.h"
#include "clutter/clutter.h"
#include "clutter/clutter-mutter.h"

/* evdev button codes the pump forwards, mapped to Clutter logical buttons. */
#define IOS_BTN_LEFT   0x110
#define IOS_BTN_RIGHT  0x111
#define IOS_BTN_MIDDLE 0x112

struct _MetaVirtualInputDeviceIOS
{
  ClutterVirtualInputDevice parent;

  /* The last commanded absolute pointer position. Events are pushed onto Clutter's queue and
   * processed LATER, so clutter_seat_query_state() still returns the PRE-motion position when the
   * pump synchronously sends motion-then-button in one drain — a button would then land at the
   * stale spot (where the pointer was on the previous tap). Track the position we ourselves
   * commanded and place buttons/scroll there, matching the app's synchronous send model. */
  graphene_point_t last_coords;

  /* Per-slot last-known touch position. clutter_virtual_input_device_notify_touch_up()
   * (and our own notify_touch_cancel, below) do not carry x/y — but CLUTTER_TOUCH_END still
   * needs coords in its ClutterEvent — so remember where each slot's last down/motion put it.
   * Sized to CLUTTER_VIRTUAL_INPUT_DEVICE_MAX_TOUCH_SLOTS, the same range the base class
   * asserts `slot` against. */
  graphene_point_t touch_coords[CLUTTER_VIRTUAL_INPUT_DEVICE_MAX_TOUCH_SLOTS];
};

G_DEFINE_TYPE (MetaVirtualInputDeviceIOS, meta_virtual_input_device_ios,
               CLUTTER_TYPE_VIRTUAL_INPUT_DEVICE)

/* Events are built with the seat's core pointer as the source device. In
 * clutter_stage_pick_and_update_device() that makes `device == core pointer`, so the repick
 * (and the crossings/implicit-grab that drive hover + clicks) depends on
 * clutter_seat_is_unfocus_inhibited() — which MetaSeatIOS pins > 0 for the process lifetime
 * (meta_seat_ios_constructed calls clutter_seat_inhibit_unfocus and never releases it), so the
 * repick always runs. (An earlier revision routed events through a dedicated FLOATING device to
 * force the repick unconditionally; that was working around a stalled frame clock — the real
 * delivery bug, since fixed in meta-stage-ios.c — not a pick problem, so it was dropped.) */

static int64_t
resolve_time (uint64_t time_us)
{
  if (time_us == CLUTTER_CURRENT_TIME)
    return g_get_monotonic_time ();
  return (int64_t) time_us;
}

static ClutterInputDevice *
get_core_device (ClutterVirtualInputDevice *virtual_device,
                      ClutterInputDeviceType     device_type)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);

  if (device_type == CLUTTER_KEYBOARD_DEVICE)
    return clutter_seat_get_keyboard (seat);
  else
    return clutter_seat_get_pointer (seat);
}

/* The seat's synthetic touchscreen core device (meta-seat-ios.c), used as the source device
 * for touch ClutterEvents so meta-wayland-seat.c's capability lookup (which requires a
 * PHYSICAL-mode device carrying CLUTTER_INPUT_CAPABILITY_TOUCH) advertises wl_touch to
 * clients — the core pointer used for mouse events lacks that capability bit. */
static ClutterInputDevice *
get_touch_device (ClutterVirtualInputDevice *virtual_device)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);

  return meta_seat_ios_get_touch (META_SEAT_IOS (seat));
}

static ClutterModifierType
button_mask (uint32_t button)
{
  switch (button)
    {
    case CLUTTER_BUTTON_PRIMARY:
      return CLUTTER_BUTTON1_MASK;
    case CLUTTER_BUTTON_MIDDLE:
      return CLUTTER_BUTTON2_MASK;
    case CLUTTER_BUTTON_SECONDARY:
      return CLUTTER_BUTTON3_MASK;
    default:
      return 0;
    }
}

static void
push_synthetic_event (ClutterEvent *event)
{
  _clutter_event_push (event, FALSE);
}

static void
meta_virtual_input_device_ios_notify_absolute_motion (ClutterVirtualInputDevice *virtual_device,
                                                      uint64_t                   time_us,
                                                      double                     x,
                                                      double                     y)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = GRAPHENE_POINT_INIT ((float) x, (float) y);
  graphene_point_t zero = GRAPHENE_POINT_INIT (0.f, 0.f);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, NULL, &modifiers);
  clutter_seat_warp_pointer (seat, (int) x, (int) y);
  self->last_coords = coords;

  event = clutter_event_motion_new (CLUTTER_EVENT_NONE,
                                    resolve_time (time_us),
                                    pointer, NULL, modifiers, coords,
                                    zero, zero, zero, NULL);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_relative_motion (ClutterVirtualInputDevice *virtual_device,
                                                      uint64_t                   time_us,
                                                      double                     dx,
                                                      double                     dy)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = self->last_coords;
  graphene_point_t delta = GRAPHENE_POINT_INIT ((float) dx, (float) dy);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, NULL, &modifiers);
  coords.x += (float) dx;
  coords.y += (float) dy;
  clutter_seat_warp_pointer (seat, (int) coords.x, (int) coords.y);
  self->last_coords = coords;

  event = clutter_event_motion_new (CLUTTER_EVENT_FLAG_RELATIVE_MOTION,
                                    resolve_time (time_us),
                                    pointer, NULL, modifiers, coords,
                                    delta, delta, delta, NULL);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_button (ClutterVirtualInputDevice *virtual_device,
                                             uint64_t                   time_us,
                                             uint32_t                   button,
                                             ClutterButtonState         button_state)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = self->last_coords;   /* where our last motion put the pointer */
  ClutterModifierType modifiers = 0;
  ClutterEventType type;
  uint32_t clutter_button;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, NULL, &modifiers);

  switch (button)
    {
    case IOS_BTN_LEFT:   clutter_button = CLUTTER_BUTTON_PRIMARY;   break;
    case IOS_BTN_MIDDLE: clutter_button = CLUTTER_BUTTON_MIDDLE;    break;
    case IOS_BTN_RIGHT:  clutter_button = CLUTTER_BUTTON_SECONDARY; break;
    default:             clutter_button = button;                  break;
    }

  type = (button_state == CLUTTER_BUTTON_STATE_PRESSED)
    ? CLUTTER_BUTTON_PRESS : CLUTTER_BUTTON_RELEASE;
  if (button_state == CLUTTER_BUTTON_STATE_PRESSED)
    modifiers |= button_mask (clutter_button);

  event = clutter_event_button_new (type, CLUTTER_EVENT_NONE,
                                    resolve_time (time_us),
                                    pointer, NULL, modifiers, coords,
                                    clutter_button, button, NULL);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_key (ClutterVirtualInputDevice *virtual_device,
                                          uint64_t                   time_us,
                                          uint32_t                   key,
                                          ClutterKeyState            key_state)
{
  ClutterInputDevice *keyboard = get_core_device (virtual_device,
                                                  CLUTTER_KEYBOARD_DEVICE);
  ClutterModifierSet raw_modifiers = { 0 };
  ClutterEventType type;
  ClutterEvent *event;

  /* `key` is an evdev keycode (xkb keycode - 8). The keyval is resolved downstream from
   * the seat keymap; the pump's text path uses notify_keyval instead, which is exact. */
  type = (key_state == CLUTTER_KEY_STATE_PRESSED)
    ? CLUTTER_KEY_PRESS : CLUTTER_KEY_RELEASE;

  event = clutter_event_key_new (type, CLUTTER_EVENT_NONE,
                                 resolve_time (time_us),
                                 keyboard, raw_modifiers, 0,
                                 0 /* keyval (resolved downstream) */,
                                 key /* evcode */, key + 8 /* keycode */, 0);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_keyval (ClutterVirtualInputDevice *virtual_device,
                                             uint64_t                   time_us,
                                             uint32_t                   keyval,
                                             ClutterKeyState            key_state)
{
  ClutterInputDevice *keyboard = get_core_device (virtual_device,
                                                  CLUTTER_KEYBOARD_DEVICE);
  ClutterModifierSet raw_modifiers = { 0 };
  gunichar unicode;
  ClutterEventType type;
  ClutterEvent *event;

  /* ASCII keysyms equal their codepoint; others carry no unicode here (the keysym is
   * still authoritative for keybindings). */
  unicode = (keyval < 0x80) ? (gunichar) keyval : 0;

  type = (key_state == CLUTTER_KEY_STATE_PRESSED)
    ? CLUTTER_KEY_PRESS : CLUTTER_KEY_RELEASE;

  event = clutter_event_key_new (type, CLUTTER_EVENT_NONE,
                                 resolve_time (time_us),
                                 keyboard, raw_modifiers, 0,
                                 keyval, 0 /* evcode */, 0 /* keycode */, unicode);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_scroll_continuous (ClutterVirtualInputDevice *virtual_device,
                                                        uint64_t                   time_us,
                                                        double                     dx,
                                                        double                     dy,
                                                        ClutterScrollSource        scroll_source,
                                                        ClutterScrollFinishFlags   finish_flags)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = self->last_coords;   /* scroll at the pointer's last position */
  graphene_point_t delta = GRAPHENE_POINT_INIT ((float) dx, (float) dy);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, NULL, &modifiers);

  event = clutter_event_scroll_smooth_new (CLUTTER_EVENT_NONE,
                                           resolve_time (time_us),
                                           pointer, NULL, modifiers, coords,
                                           delta, scroll_source, finish_flags);
  push_synthetic_event (event);
}

/* touch-down/motion/up mirror mutter's own reference (meta-seat-impl.c's
 * meta_seat_impl_notify_touch_event_in_impl): sequence = GINT_TO_POINTER(slot + 1) (a "NULL"
 * sequence is special-cased inside Clutter, so slots are offset by one), and CLUTTER_BUTTON1_
 * MASK is latched into modifiers for BEGIN/UPDATE only, matching how a touch implicitly holds
 * "button 1" down for gesture/grab purposes. */

static void
meta_virtual_input_device_ios_notify_touch_down (ClutterVirtualInputDevice *virtual_device,
                                                 uint64_t                   time_us,
                                                 int                        slot,
                                                 double                     x,
                                                 double                     y)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *touch = get_touch_device (virtual_device);
  ClutterEventSequence *sequence = GINT_TO_POINTER (slot + 1);
  graphene_point_t coords = GRAPHENE_POINT_INIT ((float) x, (float) y);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, touch, NULL, NULL, &modifiers);
  self->touch_coords[slot] = coords;

  event = clutter_event_touch_new (CLUTTER_TOUCH_BEGIN, CLUTTER_EVENT_NONE,
                                   resolve_time (time_us), touch, sequence,
                                   modifiers | CLUTTER_BUTTON1_MASK, coords);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_touch_motion (ClutterVirtualInputDevice *virtual_device,
                                                   uint64_t                   time_us,
                                                   int                        slot,
                                                   double                     x,
                                                   double                     y)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *touch = get_touch_device (virtual_device);
  ClutterEventSequence *sequence = GINT_TO_POINTER (slot + 1);
  graphene_point_t coords = GRAPHENE_POINT_INIT ((float) x, (float) y);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, touch, NULL, NULL, &modifiers);
  self->touch_coords[slot] = coords;

  event = clutter_event_touch_new (CLUTTER_TOUCH_UPDATE, CLUTTER_EVENT_NONE,
                                   resolve_time (time_us), touch, sequence,
                                   modifiers | CLUTTER_BUTTON1_MASK, coords);
  push_synthetic_event (event);
}

static void
meta_virtual_input_device_ios_notify_touch_up (ClutterVirtualInputDevice *virtual_device,
                                               uint64_t                   time_us,
                                               int                        slot)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *touch = get_touch_device (virtual_device);
  ClutterEventSequence *sequence = GINT_TO_POINTER (slot + 1);
  graphene_point_t coords = self->touch_coords[slot];   /* notify_touch_up carries no x/y */
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, touch, NULL, NULL, &modifiers);

  event = clutter_event_touch_new (CLUTTER_TOUCH_END, CLUTTER_EVENT_NONE,
                                   resolve_time (time_us), touch, sequence,
                                   modifiers, coords);
  push_synthetic_event (event);
}

/* Not a ClutterVirtualInputDeviceClass vfunc — the base class exposes touch_down/motion/up
 * but no notify_touch_cancel (clutter_event_touch_cancel_new() exists, but only mutter's own
 * seat-impl code builds it directly; see meta-seat-impl.c). XIOS_IN_TOUCH's cancel phase
 * (state=3, e.g. the OS yanking the gesture for a system swipe) needs somewhere to go, so this
 * is a bespoke public entry point on top of the same event-push path, called directly from
 * meta-input-ios.c instead of through clutter_virtual_input_device_notify_*(). */
void
meta_virtual_input_device_ios_notify_touch_cancel (ClutterVirtualInputDevice *virtual_device,
                                                   uint64_t                   time_us,
                                                   int                        slot)
{
  ClutterInputDevice *touch = get_touch_device (virtual_device);
  ClutterEventSequence *sequence = GINT_TO_POINTER (slot + 1);
  ClutterEvent *event;

  g_return_if_fail (CLUTTER_IS_VIRTUAL_INPUT_DEVICE (virtual_device));
  g_return_if_fail (slot >= 0 && slot < CLUTTER_VIRTUAL_INPUT_DEVICE_MAX_TOUCH_SLOTS);

  event = clutter_event_touch_cancel_new (CLUTTER_EVENT_NONE, resolve_time (time_us),
                                          touch, sequence);
  push_synthetic_event (event);
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
  virtual_input_device_class->notify_scroll_continuous =
    meta_virtual_input_device_ios_notify_scroll_continuous;
  virtual_input_device_class->notify_touch_down =
    meta_virtual_input_device_ios_notify_touch_down;
  virtual_input_device_class->notify_touch_motion =
    meta_virtual_input_device_ios_notify_touch_motion;
  virtual_input_device_class->notify_touch_up =
    meta_virtual_input_device_ios_notify_touch_up;
  /* notify_touch_cancel has no base-class vfunc slot; see the bespoke
   * meta_virtual_input_device_ios_notify_touch_cancel() above, called directly. */
}
