/*
 * libudev.h — a MINIMAL libudev header for the iOS stub. iOS has no udev; this declares only
 * the handful of entry points gnome-bluetooth's lib/pin.c uses (the hwdb modalias->name lookup)
 * plus the udev_list_entry_foreach macro. LGPL-2.1+ (matches libudev). NOT the full systemd API.
 */
#ifndef _LIBUDEV_H_
#define _LIBUDEV_H_

#ifdef __cplusplus
extern "C" {
#endif

struct udev;
struct udev_hwdb;
struct udev_list_entry;

struct udev *udev_new (void);
struct udev *udev_unref (struct udev *udev);

struct udev_hwdb *udev_hwdb_new (struct udev *udev);
struct udev_hwdb *udev_hwdb_unref (struct udev_hwdb *hwdb);
struct udev_list_entry *udev_hwdb_get_properties_list_entry (struct udev_hwdb *hwdb,
                                                             const char *modalias,
                                                             unsigned int flags);

struct udev_list_entry *udev_list_entry_get_next (struct udev_list_entry *list_entry);
const char *udev_list_entry_get_name (struct udev_list_entry *list_entry);
const char *udev_list_entry_get_value (struct udev_list_entry *list_entry);

#define udev_list_entry_foreach(list_entry, first_entry) \
        for (list_entry = first_entry; \
             list_entry != NULL; \
             list_entry = udev_list_entry_get_next (list_entry))

#ifdef __cplusplus
}
#endif

#endif /* _LIBUDEV_H_ */
