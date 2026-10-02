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

#include <xkbcommon/xkbcommon.h>

#include "backends/ios/meta-clutter-backend-ios.h"
#include "backends/ios/meta-seat-ios.h"
#include "backends/meta-backend-private.h"
#include "clutter/clutter.h"
#include "clutter/clutter-mutter.h"

/* evdev button codes the pump forwards, mapped to Clutter logical buttons. */
#define IOS_BTN_LEFT   0x110
#define IOS_BTN_RIGHT  0x111
#define IOS_BTN_MIDDLE 0x112

/* evdev KEY_CNT: the key code range notify_keyval tracks. */
#define IOS_KEY_CNT 0x300

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

  /* notify_keyval's key bookkeeping, per evdev code, mirroring the native backend's two
   * layers. key_down is this device's own up/down state: a repeated press or release of the
   * same key is dropped (meta-virtual-input-device-native.c's button_count), so a lost release
   * heals on the next press/release. key_count is the seat-style count that also covers the
   * level modifiers synthesized around shifted keysyms (meta-seat-impl.c's button_count): a
   * key event is only pushed on its 0->1 and 1->0 transitions, so a synthesized Shift never
   * releases a Shift the Xios modifier snapshot is still holding. */
  guint8 key_down[IOS_KEY_CNT];
  guint  key_count[IOS_KEY_CNT];
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

/* The backend's current keymap (NULL if none compiled) and locked layout group. */
static struct xkb_keymap *
get_backend_keymap (xkb_layout_index_t *layout)
{
  ClutterBackend *clutter_backend = clutter_get_default_backend ();
  MetaBackend *backend;

  *layout = 0;
  if (!META_IS_CLUTTER_BACKEND_IOS (clutter_backend))
    return NULL;

  backend = meta_clutter_backend_ios_get_backend (META_CLUTTER_BACKEND_IOS (clutter_backend));
  *layout = meta_backend_get_keymap_layout_group (backend);
  return meta_backend_get_keymap (backend);
}

/* Push one key event. `keycode` is an xkb keycode (evdev + 8), or 0 when the keysym has no
 * key in the current layout. The seat builds it from its xkb_state, so it carries the
 * shifted keysym and the held modifiers the way a native key event does. */
static void
push_key_event (ClutterVirtualInputDevice *virtual_device,
                uint64_t                   time_us,
                uint32_t                   keyval,
                xkb_keycode_t              keycode,
                ClutterKeyState            key_state)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *keyboard = get_core_device (virtual_device,
                                                  CLUTTER_KEYBOARD_DEVICE);
  xkb_layout_index_t layout;
  struct xkb_keymap *xkb_keymap = get_backend_keymap (&layout);

  push_synthetic_event (meta_seat_ios_key_event_new (META_SEAT_IOS (seat), keyboard,
                                                     resolve_time (time_us),
                                                     xkb_keymap, layout, keycode, keyval,
                                                     key_state == CLUTTER_KEY_STATE_PRESSED));
}

/* Find the xkb keycode and shift level that type `keyval` in the backend keymap's current
 * layout group. That is the map Mutter's Wayland keyboard sends clients and feeds its own
 * xkb_state with, so the keycode is what turns back into this keysym on the client side.
 * Modeled on meta-virtual-input-device-native.c's
 * pick_keycode_for_keyval_in_current_group_in_impl, but searched level by level so a keysym
 * reachable unshifted never gains a Shift, and only over the levels
 * pick_level_modifier() can reach. */
static gboolean
pick_keycode_for_keyval (uint32_t       keyval,
                         xkb_keycode_t *keycode_out,
                         uint32_t      *level_out)
{
  struct xkb_keymap *xkb_keymap;
  xkb_layout_index_t layout;
  xkb_keycode_t min_keycode, max_keycode, keycode;
  xkb_level_index_t level;

  xkb_keymap = get_backend_keymap (&layout);
  if (!xkb_keymap)
    return FALSE;

  min_keycode = xkb_keymap_min_keycode (xkb_keymap);
  max_keycode = xkb_keymap_max_keycode (xkb_keymap);
  for (level = 0; level <= 2; level++)
    {
      for (keycode = min_keycode; keycode <= max_keycode; keycode++)
        {
          const xkb_keysym_t *syms;
          int num_syms, sym;

          if (keycode < 8 || keycode - 8 >= IOS_KEY_CNT ||
              level >= xkb_keymap_num_levels_for_key (xkb_keymap, keycode, layout))
            continue;

          num_syms = xkb_keymap_key_get_syms_by_level (xkb_keymap, keycode, layout,
                                                       level, &syms);
          for (sym = 0; sym < num_syms; sym++)
            {
              if (syms[sym] == keyval)
                {
                  *keycode_out = keycode;
                  *level_out = level;
                  return TRUE;
                }
            }
        }
    }

  return FALSE;
}

/* The key that selects shift level `level` (1 = Shift, 2 = AltGr), as the native backend's
 * apply_level_modifiers_in_impl picks it. */
static gboolean
pick_level_modifier (uint32_t       level,
                     uint32_t      *keyval_out,
                     xkb_keycode_t *keycode_out)
{
  uint32_t modifier_level;

  *keyval_out = (level == 1) ? XKB_KEY_Shift_L : XKB_KEY_ISO_Level3_Shift;
  return pick_keycode_for_keyval (*keyval_out, keycode_out, &modifier_level) &&
         modifier_level == 0;
}

/* Push a key press/release only on its count's 0->1 / 1->0 transition. */
static void
notify_counted_key (MetaVirtualInputDeviceIOS *self,
                    uint64_t                   time_us,
                    uint32_t                   keyval,
                    xkb_keycode_t              keycode,
                    ClutterKeyState            key_state)
{
  guint *count = &self->key_count[keycode - 8];

  if (key_state == CLUTTER_KEY_STATE_PRESSED)
    {
      if ((*count)++ > 0)
        return;
    }
  else
    {
      if (*count == 0 || --(*count) > 0)
        return;
    }

  push_key_event (CLUTTER_VIRTUAL_INPUT_DEVICE (self), time_us, keyval, keycode, key_state);
}

/* The pump hands us keysyms (hardware keys, the Xios modifier snapshot, soft-keyboard
 * text). Mutter's Wayland keyboard sends clients the event's evdev code and drives its
 * xkb_state from its hardware keycode, so a keyval-only event reaches a Wayland client as
 * key 0 with no modifiers. Like the native backend's notify_keyval, resolve the keysym to a
 * real key in the current keymap and, when it sits on a shifted level, press the level
 * modifier around it. */
static void
meta_virtual_input_device_ios_notify_keyval (ClutterVirtualInputDevice *virtual_device,
                                             uint64_t                   time_us,
                                             uint32_t                   keyval,
                                             ClutterKeyState            key_state)
{
  MetaVirtualInputDeviceIOS *self = META_VIRTUAL_INPUT_DEVICE_IOS (virtual_device);
  gboolean pressed = (key_state == CLUTTER_KEY_STATE_PRESSED);
  xkb_keycode_t keycode = 0, level_keycode = 0;
  uint32_t level = 0, level_keyval = 0;

  if (!pick_keycode_for_keyval (keyval, &keycode, &level) ||
      (level > 0 && !pick_level_modifier (level, &level_keyval, &level_keycode)))
    {
      /* No key types this keysym (e.g. a Latin-1 symbol the "us" layout lacks): keep the
       * keyval-only event. Clutter actors still read the keysym; Wayland clients get key 0. */
      push_key_event (virtual_device, time_us, keyval, 0, key_state);
      return;
    }

  if (self->key_down[keycode - 8] == pressed)
    return;
  self->key_down[keycode - 8] = pressed;

  if (pressed && level_keycode)
    notify_counted_key (self, time_us, level_keyval, level_keycode, key_state);

  notify_counted_key (self, time_us, keyval, keycode, key_state);

  if (!pressed && level_keycode)
    notify_counted_key (self, time_us, level_keyval, level_keycode, key_state);
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
