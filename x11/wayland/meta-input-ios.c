/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-input-ios.c — bridge the Xios input socket to ClutterVirtualInputDevices.
 *
 * MetaBackendIOS has no libinput/evdev. Following mutter's own remote-desktop and EIS
 * code (src/backends/meta-remote-desktop-session.c, meta-eis-client.c), it creates
 * virtual pointer + keyboard devices on the default seat and pushes events into them.
 * The events come from the Xios app's AF_UNIX input protocol, framed by libxios_glue
 * (here the xios-glue-stub API), attached to the backend main context with a GLib source.
 *
 * GPL-2.0+, matching the mutter files this is modeled on.
 */

#include "config.h"

#include "backends/ios/meta-input-ios.h"

#include <glib-unix.h>

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
};

static uint32_t
map_button (uint32_t code)
{
  switch (code)
    {
    case 0: return IOS_BTN_LEFT;
    case 1: return IOS_BTN_RIGHT;
    case 2: return IOS_BTN_MIDDLE;
    default: return code;   /* already an evdev BTN_* */
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

static void
on_input_msg (const struct xios_in_msg *m,
              const char               *text,
              size_t                    text_len,
              uint32_t                  bound_window,
              void                     *user)
{
  MetaInputIOS *input = user;
  (void) bound_window;

  /* Diagnostic: log the first handful of decoded records so a device-side inject test can
   * confirm bytes arrive + decode with the right 24-byte layout (type/x/y). Bounded so it
   * never floods. Remove or lower once the input path is validated. */
  if (input->msg_log_budget > 0)
    {
      g_message ("MetaInputIOS: recv type=%u x=%d y=%d code=%u state=%u mods=%u",
                 m->type, m->x, m->y, m->code, m->state, m->mods);
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
        x = m->x * rx;
        y = m->y * ry;

        /* Diagnostic: the exact coords handed to Clutter + the mapping ratio, so an inject test
         * confirms the pointer lands where expected (in-bounds of the stage screen size). */
        if (input->msg_log_budget > 0)
          g_message ("MetaInputIOS: motion out(%d,%d) *(%.3f,%.3f) -> stage(%.1f,%.1f)",
                     m->x, m->y, rx, ry, x, y);

        clutter_virtual_input_device_notify_absolute_motion (input->pointer,
                                                             CLUTTER_CURRENT_TIME, x, y);

        input->cursor_x = m->x;
        input->cursor_y = m->y;
        xios_notify_cursor (input->cursor_x, input->cursor_y, 1, 1);
        break;
      }

    case XIOS_IN_BUTTON:
      clutter_virtual_input_device_notify_button (input->pointer,
                                                  CLUTTER_CURRENT_TIME,
                                                  map_button (m->code),
                                                  m->state ? CLUTTER_BUTTON_STATE_PRESSED
                                                           : CLUTTER_BUTTON_STATE_RELEASED);
      break;

    case XIOS_IN_KEY:
      /* code is an X keysym; notify_keyval lets Clutter's keymap pick the keycode and
       * latch the required level modifiers, so we do not reimplement iosc_input_lookup. */
      clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                  CLUTTER_CURRENT_TIME,
                                                  m->code,
                                                  m->state ? CLUTTER_KEY_STATE_PRESSED
                                                           : CLUTTER_KEY_STATE_RELEASED);
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
        ClutterScrollFinishFlags finish = (m->state & 1)
          ? (CLUTTER_SCROLL_FINISHED_HORIZONTAL | CLUTTER_SCROLL_FINISHED_VERTICAL)
          : CLUTTER_SCROLL_FINISHED_NONE;

        output_to_stage_ratio (input, &rx, &ry);
        if (m->mods & 2)
          clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                      CLUTTER_CURRENT_TIME,
                                                      0xffe3 /* XK_Control_L */,
                                                      CLUTTER_KEY_STATE_PRESSED);
        clutter_virtual_input_device_notify_scroll_continuous (input->pointer,
                                                               CLUTTER_CURRENT_TIME,
                                                               m->x / 256.0 * rx,
                                                               m->y / 256.0 * ry,
                                                               m->code == 1
                                                                 ? CLUTTER_SCROLL_SOURCE_WHEEL
                                                                 : CLUTTER_SCROLL_SOURCE_FINGER,
                                                               finish);
        if (m->mods & 2)
          clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                      CLUTTER_CURRENT_TIME,
                                                      0xffe3 /* XK_Control_L */,
                                                      CLUTTER_KEY_STATE_RELEASED);
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
  input->msg_log_budget = 20;   /* log the first ~20 records for the inject/touch bring-up test */

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

  if (input->source_id)
    g_source_remove (input->source_id);
  g_clear_object (&input->pointer);
  g_clear_object (&input->keyboard);
  xios_input_socket_free (input->socket);
  g_free (input);
}
