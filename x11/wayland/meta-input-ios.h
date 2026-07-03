/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-input-ios.h — the MetaBackendIOS input pump: bridge the Xios input socket to a
 * pair of ClutterVirtualInputDevices (pointer + keyboard) on the backend's default seat.
 *
 * MetaBackendIOS has no evdev/libinput. Instead of a MetaSeatNative input thread it uses
 * the same mechanism as mutter's remote-desktop / EIS code: create virtual devices on the
 * default seat and push events (docs/mutter-on-iosc.md Option (b), Step 3). The event
 * source is the Xios app's AF_UNIX input protocol (libxios_glue / xios-glue-stub.h). GPL-
 * 2.0+, the same license as the mutter files it is modeled on.
 */
#pragma once

#include <glib-object.h>

#include "backends/meta-backend-types.h"

typedef struct _MetaInputIOS MetaInputIOS;

/* Start pumping: open the input socket at `socket_path`, create the pointer + keyboard
 * virtual devices on `backend`'s default seat, and attach a GLib source that translates
 * incoming records into Clutter events on the backend's main context. NULL on failure. */
MetaInputIOS *meta_input_ios_new (MetaBackend *backend,
                                  const char  *socket_path);

/* Stop pumping, drop the virtual devices, close the socket. */
void meta_input_ios_free (MetaInputIOS *input);

/* Outbound: broadcast on-screen-keyboard traits (from Wayland text-input-v3) to the
 * Xios app over the SAME input socket, so it raises/lowers the iOS keyboard. `hint` and
 * `purpose` are the raw zwp_text_input_v3 content-type values; `enabled` is the show
 * flag. Mirrors iosc's input_clients_send_traits() (XIOS_IN_TRAITS). */
void meta_input_ios_send_osk_traits (MetaInputIOS *input,
                                     guint32       hint,
                                     guint32       purpose,
                                     gboolean      enabled);
