/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-virtual-input-device-ios.h — the MetaBackendIOS virtual input device.
 *
 * A ClutterVirtualInputDevice that turns the input pump's notify_* calls into ClutterEvents
 * and pushes them onto Clutter's queue (_clutter_event_push) — the light path, without the
 * native backend's libinput input-thread (which native_backend=false compiles out). This is
 * what makes meta-input-ios.c's pump actually deliver pointer+keyboard events to the stage.
 * GPL-2.0+, modeled on meta-virtual-input-device-native.c (minus the thread/evdev coupling).
 */
#pragma once

#include "clutter/clutter.h"

#define META_TYPE_VIRTUAL_INPUT_DEVICE_IOS (meta_virtual_input_device_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaVirtualInputDeviceIOS, meta_virtual_input_device_ios,
                      META, VIRTUAL_INPUT_DEVICE_IOS, ClutterVirtualInputDevice)
