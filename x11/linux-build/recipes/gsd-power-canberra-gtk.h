/* canberra-gtk.h — iOS no-op shim for the gnome-settings-daemon power plugin.
 *
 * The power plugin plays libcanberra event sounds (low/critical battery, UPS alert). iOS has
 * no libcanberra and no ALSA/PulseAlert path for these, so we compile the plugin against this
 * stub: every ca_* call is a no-op returning success. This lets us un-drop the `power` plugin
 * (for the brightness slider) without pulling libcanberra-gtk / GTK3. Only the handful of
 * symbols gpm-common.c + gsd-power-manager.c reference are declared. GPL-2.0+.
 */
#ifndef CANBERRA_GTK_H_XIOS_STUB
#define CANBERRA_GTK_H_XIOS_STUB

#include <stdarg.h>
#include <stdint.h>

typedef struct ca_context ca_context;

/* The only property keys the plugin passes. */
#define CA_PROP_EVENT_ID          "event.id"
#define CA_PROP_EVENT_DESCRIPTION "event.description"

static inline ca_context *
ca_gtk_context_get (void)
{
  return 0;
}

/* Variadic (key,value,... ,NULL) like the real API; we ignore everything. */
static inline int
ca_context_play (ca_context *c, uint32_t id, ...)
{
  (void) c;
  (void) id;
  return 0;   /* CA_SUCCESS */
}

static inline int
ca_context_cancel (ca_context *c, uint32_t id)
{
  (void) c;
  (void) id;
  return 0;   /* CA_SUCCESS */
}

#endif /* CANBERRA_GTK_H_XIOS_STUB */
