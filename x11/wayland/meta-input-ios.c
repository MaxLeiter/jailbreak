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

/* evdev button codes; defined locally to avoid a linux/input-event-codes.h dependency
 * on the iOS cross toolchain. clutter_virtual_input_device_notify_button() takes the
 * evdev code, exactly as the native/libinput path feeds it. */
#define IOS_BTN_LEFT   0x110
#define IOS_BTN_RIGHT  0x111
#define IOS_BTN_MIDDLE 0x112

struct _MetaInputIOS
{
  xios_input_socket         *socket;
  ClutterVirtualInputDevice *pointer;
  ClutterVirtualInputDevice *keyboard;
  guint                      source_id;
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
              void                     *user)
{
  MetaInputIOS *input = user;

  switch (m->type)
    {
    case XIOS_IN_MOTION:
      {
        /* Socket carries output (physical) pixels; the Clutter stage is in logical
         * coordinates, so divide by the output scale. */
        double scale = xios_output_scale ();

        if (scale <= 0.0)
          scale = 1.0;
        clutter_virtual_input_device_notify_absolute_motion (input->pointer,
                                                             CLUTTER_CURRENT_TIME,
                                                             m->x / scale,
                                                             m->y / scale);
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

static gboolean
on_socket_ready (gint         fd,
                 GIOCondition condition,
                 gpointer     user_data)
{
  MetaInputIOS *input = user_data;

  if (condition & (G_IO_ERR | G_IO_HUP))
    {
      input->source_id = 0;
      return G_SOURCE_REMOVE;
    }

  if (xios_input_socket_dispatch (input->socket, on_input_msg, input) < 0)
    {
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
  int fd;

  socket = xios_input_socket_new (socket_path);
  if (!socket)
    return NULL;

  seat = meta_backend_get_default_seat (backend);

  input = g_new0 (MetaInputIOS, 1);
  input->socket = socket;
  input->pointer = clutter_seat_create_virtual_device (seat, CLUTTER_POINTER_DEVICE);
  input->keyboard = clutter_seat_create_virtual_device (seat, CLUTTER_KEYBOARD_DEVICE);

  fd = xios_input_socket_fd (socket);
  input->source_id = g_unix_fd_add (fd, G_IO_IN | G_IO_ERR | G_IO_HUP,
                                    on_socket_ready, input);

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
