/*
 * udev-stub.c — a STUB libudev for iOS (there is no udev / sysfs / hwdb on a jailbroken iPad).
 * Implements only what gnome-bluetooth's lib/pin.c calls: the udev + hwdb handles and the
 * list-entry accessors. The hwdb (modalias -> device-name) lookup returns nothing, so pin.c
 * falls back to the device's own reported name (which the xios-bluez-stub already provides).
 * LGPL-2.1+.
 */
#include "libudev.h"
#include <stdlib.h>

/* Opaque non-NULL sentinels so callers that null-check a handle proceed, then get empty data. */
static int udev_sentinel;
static int hwdb_sentinel;

struct udev *udev_new (void) { return (struct udev *) &udev_sentinel; }
struct udev *udev_unref (struct udev *udev) { (void) udev; return NULL; }

struct udev_hwdb *udev_hwdb_new (struct udev *udev) { (void) udev; return (struct udev_hwdb *) &hwdb_sentinel; }
struct udev_hwdb *udev_hwdb_unref (struct udev_hwdb *hwdb) { (void) hwdb; return NULL; }

struct udev_list_entry *
udev_hwdb_get_properties_list_entry (struct udev_hwdb *hwdb, const char *modalias, unsigned int flags)
{
  (void) hwdb; (void) modalias; (void) flags;
  return NULL;  /* empty hwdb: no properties */
}

struct udev_list_entry *udev_list_entry_get_next (struct udev_list_entry *e) { (void) e; return NULL; }
const char *udev_list_entry_get_name (struct udev_list_entry *e) { (void) e; return NULL; }
const char *udev_list_entry_get_value (struct udev_list_entry *e) { (void) e; return NULL; }
