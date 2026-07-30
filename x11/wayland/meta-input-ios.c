/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-input-ios.c — bridge the Xios input socket to ClutterVirtualInputDevices.
 *
 * MetaBackendIOS has no libinput/evdev. Following mutter's own remote-desktop and EIS
 * code (src/backends/meta-remote-desktop-session.c, meta-eis-client.c), it creates
 * virtual pointer + keyboard devices on the default seat and pushes events into them.
 * The events come from the Xios app's AF_UNIX input protocol, framed by libxios_glue
 * (declared through the flat xios-glue-stub compile contract), attached to the backend main
 * context with a GLib source.
 *
 * GPL-2.0+, matching the mutter files this is modeled on.
 */

#include "config.h"

#include "backends/ios/meta-input-ios.h"

#include <glib-unix.h>

#include "backends/ios/meta-monitor-manager-ios.h"
#include "backends/ios/meta-virtual-input-device-ios.h"
#include "backends/ios/xios-glue-stub.h"
#include "backends/meta-backend-private.h"
#include "clutter/clutter.h"
#include "meta/meta-monitor-manager.h"

/* evdev button codes; defined locally to avoid a linux/input-event-codes.h dependency
 * on the iOS cross toolchain. clutter_virtual_input_device_notify_button() takes the
 * evdev code, exactly as the native/libinput path feeds it. */
#define IOS_BTN_LEFT   0x110
#define IOS_BTN_RIGHT  0x111
#define IOS_BTN_MIDDLE 0x112

struct _MetaInputIOS
{
  MetaBackend               *backend;            /* for the monitor manager (input coord space) */
  xios_input_socket         *socket;
  ClutterVirtualInputDevice *pointer;
  ClutterVirtualInputDevice *keyboard;
  guint                      source_id;
  int                        last_client_count;  /* log connect/disconnect edges */
  int                        msg_log_budget;     /* log the first few decoded records */
  int                        cursor_x;
  int                        cursor_y;
  uint32_t                   wire_mods;         /* Xios modifier snapshot, bits 0..5 */
};

static int
input_log_budget_from_env (void)
{
  const char *value = g_getenv ("XIOS_INPUT_LOG_BUDGET");
  char *end = NULL;
  gint64 parsed;

  if (!value || !*value)
    return 0;

  parsed = g_ascii_strtoll (value, &end, 10);
  if (end == value || *end != '\0' || parsed < 0)
    {
      g_warning ("MetaInputIOS: ignoring invalid XIOS_INPUT_LOG_BUDGET=%s", value);
      return 0;
    }

  return parsed > G_MAXINT ? G_MAXINT : (int) parsed;
}

static uint32_t
map_button (uint32_t code)
{
  /* Wire buttons are X-style (1 = left, 2 = middle, 3 = right), matching the Xios app's
   * sendClick() panel + single-tap and iosc.c's handle_button ("Wire buttons are X-style").
   * This backend previously used a 0-based map (0=left, 1=right), so the app's left click /
   * every single TAP (button 1) was injected as a RIGHT click and nothing activated.
   * Raw evdev codes (>= BTN_LEFT, e.g. from a physical mouse) pass through unchanged. */
  switch (code)
    {
    case 1: return IOS_BTN_LEFT;
    case 2: return IOS_BTN_MIDDLE;
    case 3: return IOS_BTN_RIGHT;
    default: return code;   /* already an evdev BTN_* (>= 0x110) */
    }
}

/* Ratio mapping output-pixel wire coordinates/deltas into the stage's coordinate space,
 * which is meta_monitor_manager_get_screen_size() — the SAME value meta-stage-ios uses for
 * its geometry. In the DEFAULT PHYSICAL layout mode the screen is the full output size
 * (e.g. 2160x1620), so this is identity; only with the experimental scale-monitor-framebuffer
 * feature (LOGICAL mode) is it the /scale'd size. Dividing by a fixed xios_output_scale()=2
 * was WRONG in PHYSICAL mode. Shared by the MOTION and AXIS cases so they cannot drift. */
static void
output_to_stage_ratio (MetaInputIOS *input,
                       double       *ratio_x,
                       double       *ratio_y)
{
  MetaMonitorManager *monitor_manager =
    meta_backend_get_monitor_manager (input->backend);
  int out_w = 0, out_h = 0, screen_w = 0, screen_h = 0;

  xios_output_geometry (&out_w, &out_h);
  if (monitor_manager)
    meta_monitor_manager_get_screen_size (monitor_manager, &screen_w, &screen_h);

  *ratio_x = (out_w > 0 && screen_w > 0) ? (double) screen_w / out_w : 1.0;
  *ratio_y = (out_h > 0 && screen_h > 0) ? (double) screen_h / out_h : 1.0;
}

static void
notify_keyval_click (MetaInputIOS *input,
                     uint32_t      keyval)
{
  clutter_virtual_input_device_notify_keyval (input->keyboard,
                                              CLUTTER_CURRENT_TIME, keyval,
                                              CLUTTER_KEY_STATE_PRESSED);
  clutter_virtual_input_device_notify_keyval (input->keyboard,
                                              CLUTTER_CURRENT_TIME, keyval,
                                              CLUTTER_KEY_STATE_RELEASED);
}

static uint32_t
modifier_bit_for_keyval (uint32_t keyval)
{
  switch (keyval)
    {
    case 0xffe1: case 0xffe2: return 1u << 0; /* Shift L/R */
    case 0xffe3: case 0xffe4: return 1u << 1; /* Control L/R */
    case 0xffe9: case 0xffea: return 1u << 2; /* Alt L/R */
    case 0xffeb: case 0xffec: return 1u << 3; /* Super L/R */
    case 0xffe5: return 1u << 4;              /* Caps Lock */
    case 0xff7f: return 1u << 5;              /* Num Lock */
    default: return 0;
    }
}

static void
sync_wire_modifiers (MetaInputIOS *input,
                     uint32_t      next)
{
  static const struct { uint32_t bit, keyval; } depressed[] = {
    { 1u << 0, 0xffe1 }, /* Shift_L */
    { 1u << 1, 0xffe3 }, /* Control_L */
    { 1u << 2, 0xffe9 }, /* Alt_L */
    { 1u << 3, 0xffeb }, /* Super_L */
  };
  uint32_t changed = input->wire_mods ^ next;

  for (size_t i = 0; i < G_N_ELEMENTS (depressed); i++)
    if (changed & depressed[i].bit)
      clutter_virtual_input_device_notify_keyval (
        input->keyboard, CLUTTER_CURRENT_TIME, depressed[i].keyval,
        (next & depressed[i].bit) ? CLUTTER_KEY_STATE_PRESSED
                                  : CLUTTER_KEY_STATE_RELEASED);

  /* Lock modifiers toggle on a complete click, rather than staying depressed. */
  if (changed & (1u << 4)) notify_keyval_click (input, 0xffe5); /* Caps_Lock */
  if (changed & (1u << 5)) notify_keyval_click (input, 0xff7f); /* Num_Lock */
  input->wire_mods = next;
}

static void
on_input_msg (const xios_msg           *m,
              const char               *text,
              size_t                    text_len,
              uint32_t                  bound_window,
              void                     *user)
{
  MetaInputIOS *input = user;
  gboolean log_record = input->msg_log_budget > 0;
  (void) bound_window;

  /* Opt-in diagnostic: log the first N decoded records so a device-side inject test can
   * confirm bytes arrive + decode with the right 24-byte layout (type/x/y). */
  if (log_record)
    {
      g_message ("MetaInputIOS: recv type=%u x=%d y=%d code=%u state=%u mods=%u",
                 m->type, XIOS_INPUT_X(m), XIOS_INPUT_Y(m), XIOS_INPUT_CODE(m), XIOS_INPUT_STATE(m), XIOS_INPUT_MODS(m));
      input->msg_log_budget--;
    }

  switch (m->type)
    {
    case XIOS_IN_MOTION:
      {
        /* Socket carries ABSOLUTE output-pixel position (0..2160 x 0..1620). Map it into the
         * stage's coordinate space via output_to_stage_ratio(): a fixed /xios_output_scale()
         * parked the pointer in the top-left quadrant in PHYSICAL mode, so clicks landed on
         * the wrong widget (or nothing) and buttons never activated. Ratio-mapping to the live
         * screen size is correct in either mode + survives rotation. */
        double rx, ry, x, y;

        output_to_stage_ratio (input, &rx, &ry);
        x = XIOS_INPUT_X(m) * rx;
        y = XIOS_INPUT_Y(m) * ry;

        /* Diagnostic: the exact coords handed to Clutter + the mapping ratio, so an inject test
         * confirms the pointer lands where expected (in-bounds of the stage screen size). */
        if (log_record)
          g_message ("MetaInputIOS: motion out(%d,%d) *(%.3f,%.3f) -> stage(%.1f,%.1f)",
                     XIOS_INPUT_X(m), XIOS_INPUT_Y(m), rx, ry, x, y);

        clutter_virtual_input_device_notify_absolute_motion (input->pointer,
                                                             CLUTTER_CURRENT_TIME, x, y);

        input->cursor_x = XIOS_INPUT_X(m);
        input->cursor_y = XIOS_INPUT_Y(m);
        xios_notify_cursor (input->cursor_x, input->cursor_y, 1, 1);
        break;
      }

    case XIOS_IN_BUTTON:
      clutter_virtual_input_device_notify_button (input->pointer,
                                                  CLUTTER_CURRENT_TIME,
                                                  map_button (XIOS_INPUT_CODE(m)),
                                                  XIOS_INPUT_STATE(m) ? CLUTTER_BUTTON_STATE_PRESSED
                                                           : CLUTTER_BUTTON_STATE_RELEASED);
      break;

    case XIOS_IN_KEY:
      /* Preserve true hardware down/up and synchronize the complete modifier
       * snapshot. Modifier key records are represented by sync_wire_modifiers()
       * itself; ordinary releases happen before the snapshot changes so a
       * Ctrl-key chord remains active for the released key. */
      if (modifier_bit_for_keyval (XIOS_INPUT_CODE(m)))
        {
          sync_wire_modifiers (input, XIOS_INPUT_MODS(m));
          break;
        }
      if (XIOS_INPUT_STATE(m))
        sync_wire_modifiers (input, XIOS_INPUT_MODS(m));
      clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                   CLUTTER_CURRENT_TIME,
                                                   XIOS_INPUT_CODE(m),
                                                   XIOS_INPUT_STATE(m) ? CLUTTER_KEY_STATE_PRESSED
                                                            : CLUTTER_KEY_STATE_RELEASED);
      if (!XIOS_INPUT_STATE(m))
        sync_wire_modifiers (input, XIOS_INPUT_MODS(m));
      break;

    case XIOS_IN_AXIS:
      {
        /* Two-finger / wheel scroll. x,y are deltas in 1/256 output px (wl_fixed units);
         * map them into stage px with the same live ratio as MOTION (identity in the default
         * PHYSICAL layout mode — a fixed /xios_output_scale() halved scroll distances there).
         * state bit0 = the fingers left the glass -> finish flags so Clutter's kinetic scroll
         * flings. mods bit1 = latch Ctrl around the frame (the app's pinch-to-zoom =
         * ctrl+scroll). code 1 = wheel notch, else continuous finger scroll. */
        double rx, ry;
        ClutterScrollFinishFlags finish = (XIOS_INPUT_STATE(m) & 1)
          ? (CLUTTER_SCROLL_FINISHED_HORIZONTAL | CLUTTER_SCROLL_FINISHED_VERTICAL)
          : CLUTTER_SCROLL_FINISHED_NONE;

        output_to_stage_ratio (input, &rx, &ry);
        if (XIOS_INPUT_MODS(m) & 2)
          clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                      CLUTTER_CURRENT_TIME,
                                                      0xffe3 /* XK_Control_L */,
                                                      CLUTTER_KEY_STATE_PRESSED);
        clutter_virtual_input_device_notify_scroll_continuous (input->pointer,
                                                               CLUTTER_CURRENT_TIME,
                                                               XIOS_INPUT_X(m) / 256.0 * rx,
                                                               XIOS_INPUT_Y(m) / 256.0 * ry,
                                                               XIOS_INPUT_CODE(m) == 1
                                                                 ? CLUTTER_SCROLL_SOURCE_WHEEL
                                                                 : CLUTTER_SCROLL_SOURCE_FINGER,
                                                               finish);
        if (XIOS_INPUT_MODS(m) & 2)
          clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                      CLUTTER_CURRENT_TIME,
                                                      0xffe3 /* XK_Control_L */,
                                                      CLUTTER_KEY_STATE_RELEASED);
        break;
      }

    case XIOS_IN_TOUCH:
      {
        /* Real multitouch. code = touch id (wire slot 0..9, per xios_input_socket.h); the
         * wire's id range already fits inside Clutter's 0..31 virtual-touch slot space, so it
         * is used directly as the slot with no separate id->slot table. state = phase (0 up /
         * 1 down / 2 motion / 3 cancel), matching iosc.c's handle_touch. Position uses the
         * SAME output_to_stage_ratio() conversion as MOTION so touch and mouse coordinates
         * never drift apart across rotation/scale changes. */
        double rx, ry, x, y;
        int slot = (int) XIOS_INPUT_CODE(m);

        if (slot < 0 || slot >= CLUTTER_VIRTUAL_INPUT_DEVICE_MAX_TOUCH_SLOTS)
          {
            g_warning ("MetaInputIOS: touch id %d out of range, dropping", slot);
            break;
          }

        output_to_stage_ratio (input, &rx, &ry);
        x = XIOS_INPUT_X(m) * rx;
        y = XIOS_INPUT_Y(m) * ry;

        switch (XIOS_INPUT_STATE(m))
          {
          case 1: /* down */
            clutter_virtual_input_device_notify_touch_down (input->pointer, CLUTTER_CURRENT_TIME,
                                                             slot, x, y);
            break;
          case 2: /* motion */
            clutter_virtual_input_device_notify_touch_motion (input->pointer, CLUTTER_CURRENT_TIME,
                                                               slot, x, y);
            break;
          case 0: /* up */
            clutter_virtual_input_device_notify_touch_up (input->pointer, CLUTTER_CURRENT_TIME, slot);
            break;
          case 3: /* cancel */
          default:
            meta_virtual_input_device_ios_notify_touch_cancel (input->pointer, CLUTTER_CURRENT_TIME, slot);
            break;
          }
        break;
      }

    case XIOS_IN_TABLET:
      {
        /* Minimal viable Apple Pencil: map straight onto the pointer path — the SAME
         * output_to_stage_ratio() conversion and virtual device MOTION/BUTTON already use —
         * so the Pencil at least works under GNOME. Pressure (code) and tilt (mods) are
         * dropped; a real ClutterInputDeviceTool tablet-tool implementation (zwp_tablet-v2
         * axes via a dedicated tool, proximity events) is a future upgrade — see iosc.c's
         * handle_pencil for the fuller proximity_in/down/motion/up/proximity_out model this
         * leaves on the table. state phases match XIOS_IN_TOUCH: 0 up, 1 down, 2 motion,
         * 3 cancel (iosc.c's IOSC_PEN_* constants). */
        double rx, ry, x, y;

        output_to_stage_ratio (input, &rx, &ry);
        x = XIOS_INPUT_X(m) * rx;
        y = XIOS_INPUT_Y(m) * ry;

        clutter_virtual_input_device_notify_absolute_motion (input->pointer, CLUTTER_CURRENT_TIME, x, y);
        input->cursor_x = XIOS_INPUT_X(m);
        input->cursor_y = XIOS_INPUT_Y(m);
        xios_notify_cursor (input->cursor_x, input->cursor_y, 1, 1);

        switch (XIOS_INPUT_STATE(m))
          {
          case 1: /* down: press where the tip landed */
            clutter_virtual_input_device_notify_button (input->pointer, CLUTTER_CURRENT_TIME,
                                                        IOS_BTN_LEFT, CLUTTER_BUTTON_STATE_PRESSED);
            break;
          case 0: /* up */
          case 3: /* cancel: release rather than leave the button stuck down */
            clutter_virtual_input_device_notify_button (input->pointer, CLUTTER_CURRENT_TIME,
                                                        IOS_BTN_LEFT, CLUTTER_BUTTON_STATE_RELEASED);
            break;
          case 2: /* motion: the absolute_motion above already placed the pointer */
          default:
            break;
          }
        break;
      }

    case XIOS_IN_OUTPUT:
      {
        /* Device rotation / logical resize. x,y = requested LOGICAL WxH (0,0 = derive from
         * the launch size + transform); code = wl_output transform (0/1/2/3). The monitor
         * manager replaces the backing IOSurface first; reload then rebuilds Mutter's logical
         * monitor and renderer view against the replacement surface. */
        MetaMonitorManager *monitor_manager = meta_backend_get_monitor_manager (input->backend);

        if (monitor_manager)
          {
            if (meta_monitor_manager_ios_set_output_size (META_MONITOR_MANAGER_IOS (monitor_manager),
                                                          (int) XIOS_INPUT_CODE(m), XIOS_INPUT_X(m), XIOS_INPUT_Y(m)))
              meta_monitor_manager_reload (monitor_manager);
          }
        break;
      }

    case XIOS_IN_TEXT:
      /* Committed text (soft keyboard / paste): type each byte as a keyval click.
       * '\n' -> Return; Latin-1 keysyms equal their codepoint. Multibyte UTF-8 is
       * skipped here (the IME path in ios-inputd covers full unicode via commit_string). */
      for (size_t i = 0; i < text_len; i++)
        {
          unsigned char c = (unsigned char) text[i];

          if (c == '\n')
            notify_keyval_click (input, 0xff0d);   /* XK_Return */
          else if (c < 0x80)
            notify_keyval_click (input, c);
        }
      break;

    default:
      break;
    }
}

/* Poll the input socket on a timer instead of watching its fd. xios_input_socket_fd() returns
 * a KQUEUE descriptor, and adding a kqueue fd to GLib's main loop (g_unix_fd_add -> g_poll) did
 * NOT wake on iOS — so the earlier fd-watch never fired and no input was ever drained.
 * xios_input_socket_dispatch is a non-blocking kevent(timeout=0) drain (accept + read + decode),
 * so calling it every ~8ms reliably pumps connections + records regardless of kqueue pollability.
 * ~120Hz is imperceptible latency; making this event-driven again needs the glue to expose a
 * pollable listen fd or a GSource (future optimization, not correctness). */
static gboolean
on_poll_tick (gpointer user_data)
{
  MetaInputIOS *input = user_data;
  int clients, n;

  clients = xios_input_socket_client_count (input->socket);
  if (clients != input->last_client_count)
    {
      g_message ("MetaInputIOS: input client count %d -> %d (app %s)",
                 input->last_client_count, clients,
                 clients > input->last_client_count ? "connected" : "disconnected");
      if (clients == 0)
        sync_wire_modifiers (input, 0);
      input->last_client_count = clients;
    }

  n = xios_input_socket_dispatch (input->socket, on_input_msg, input);
  if (n < 0)
    {
      g_warning ("MetaInputIOS: fatal input socket error, stopping the input pump");
      input->source_id = 0;
      return G_SOURCE_REMOVE;
    }

  return G_SOURCE_CONTINUE;
}

MetaInputIOS *
meta_input_ios_new (MetaBackend *backend,
                    const char  *socket_path)
{
  MetaInputIOS *input;
  ClutterSeat *seat;
  xios_input_socket *socket;

  socket = xios_input_socket_new (socket_path);
  if (!socket)
    return NULL;

  seat = meta_backend_get_default_seat (backend);

  input = g_new0 (MetaInputIOS, 1);
  input->backend = backend;
  input->socket = socket;
  input->pointer = clutter_seat_create_virtual_device (seat, CLUTTER_POINTER_DEVICE);
  input->keyboard = clutter_seat_create_virtual_device (seat, CLUTTER_KEYBOARD_DEVICE);
  input->last_client_count = 0;
  input->msg_log_budget = input_log_budget_from_env ();
  if (input->msg_log_budget > 0)
    g_message ("MetaInputIOS: logging first %d input records", input->msg_log_budget);

  /* ~8ms poll of the (kqueue-backed) input socket; see on_poll_tick for why not fd-watched. */
  input->source_id = g_timeout_add (8, on_poll_tick, input);
  g_message ("MetaInputIOS: input pump polling %s (8ms)", socket_path);

  return input;
}

void
meta_input_ios_free (MetaInputIOS *input)
{
  if (!input)
    return;
  sync_wire_modifiers (input, 0);

  if (input->source_id)
    g_source_remove (input->source_id);
  g_clear_object (&input->pointer);
  g_clear_object (&input->keyboard);
  xios_input_socket_free (input->socket);
  g_free (input);
}

void
meta_input_ios_send_osk_traits (MetaInputIOS *input,
                                guint32       hint,
                                guint32       purpose,
                                gboolean      enabled)
{
  /* Byte-identical to iosc's input_clients_send_traits(): code=hint, state=purpose,
   * mods=enabled. The Xios app maps purpose->UIKeyboardType and raises/lowers the
   * iOS keyboard on the enabled flag. Broadcast to every connected app client. */
  xios_msg msg = xios_input_message (XIOS_IN_TRAITS, 0, 0, hint, purpose,
                                     enabled ? 1u : 0u);

  if (input && input->socket)
    xios_input_socket_broadcast (input->socket, &msg, sizeof msg);
}
