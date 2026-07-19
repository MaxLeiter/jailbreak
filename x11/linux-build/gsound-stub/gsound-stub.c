/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */
/*
 * gsound-stub.c — an ABI-compatible STUB of libgsound for iOS.
 *
 * gnome-control-center's sound panel and gnome-bluetooth link gsound (a GObject wrapper over
 * libcanberra) to play short UI event sounds (test-speaker, device-paired chime). libcanberra
 * has no iOS backend, so this stub exports the libgsound public ABI using the real upstream
 * headers and maps event sounds to iOS AudioToolbox system sounds when available. The actual
 * media/audio output path remains libpulse/gvc. LGPL-2.1+.
 */
#include "gsound.h"
#include <dlfcn.h>
#include <gio/gio.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

GQuark
gsound_error_quark (void)
{
  return g_quark_from_static_string ("gsound-error-quark");
}

/* GSoundContext: a real registered GObject type, empty behaviour. Both the instance and class
 * structs are opaque in the public header (defined in upstream's private .c), so declare them. */
struct _GSoundContext { GObject parent_instance; };
struct _GSoundContextClass { GObjectClass parent_class; };
G_DEFINE_TYPE (GSoundContext, gsound_context, G_TYPE_OBJECT)
static void gsound_context_init (GSoundContext *c) { (void) c; }
static void gsound_context_class_init (GSoundContextClass *k) { (void) k; }

typedef void (*AudioServicesPlaySystemSoundFn) (uint32_t sound_id);
typedef void (*AudioServicesPlayAlertSoundFn) (uint32_t sound_id);

static void
load_audio_toolbox (AudioServicesPlaySystemSoundFn *play,
                    AudioServicesPlayAlertSoundFn  *alert)
{
  static void *handle;
  static AudioServicesPlaySystemSoundFn play_fn;
  static AudioServicesPlayAlertSoundFn alert_fn;
  static int loaded;
  if (!loaded)
    {
      loaded = 1;
      handle = dlopen ("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
                       RTLD_LAZY | RTLD_LOCAL);
      if (handle)
        {
          play_fn = (AudioServicesPlaySystemSoundFn) dlsym (handle, "AudioServicesPlaySystemSound");
          alert_fn = (AudioServicesPlayAlertSoundFn) dlsym (handle, "AudioServicesPlayAlertSound");
        }
    }
  *play = play_fn;
  *alert = alert_fn;
}

static uint32_t
sound_id_for_event (const char *event_id)
{
  if (!event_id || !*event_id)
    return 1104;  /* Tock */
  if (strstr (event_id, "error") || strstr (event_id, "warning") ||
      strstr (event_id, "bell") || strstr (event_id, "dialog"))
    return 1005;  /* alarm-ish */
  if (strstr (event_id, "complete") || strstr (event_id, "success"))
    return 1007;
  if (strstr (event_id, "device") || strstr (event_id, "bluetooth"))
    return 1106;
  if (strstr (event_id, "message") || strstr (event_id, "notification"))
    return 1007;
  return 1104;
}

static gboolean
attr_value_is_false (const char *value)
{
  return value && (!g_ascii_strcasecmp (value, "0") ||
                   !g_ascii_strcasecmp (value, "false") ||
                   !g_ascii_strcasecmp (value, "no") ||
                   !g_ascii_strcasecmp (value, "off"));
}

static gboolean
play_event_id (const char *event_id, gboolean alert)
{
  if (g_getenv ("XIOS_GSOUND_DISABLE"))
    return TRUE;
  AudioServicesPlaySystemSoundFn play = NULL;
  AudioServicesPlayAlertSoundFn alert_play = NULL;
  load_audio_toolbox (&play, &alert_play);
  uint32_t sid = sound_id_for_event (event_id);
  if (alert && alert_play)
    alert_play (sid);
  else if (play)
    play (sid);
  return TRUE;
}

static const char *
event_id_from_attrs (GHashTable *attrs, gboolean *enabled)
{
  if (enabled)
    {
      const char *v = attrs ? g_hash_table_lookup (attrs, GSOUND_ATTR_CANBERRA_ENABLE) : NULL;
      *enabled = !attr_value_is_false (v);
    }
  return attrs ? g_hash_table_lookup (attrs, GSOUND_ATTR_EVENT_ID) : NULL;
}

static const char *
event_id_from_valist (va_list ap, gboolean *enabled)
{
  const char *event_id = NULL;
  if (enabled) *enabled = TRUE;
  for (;;)
    {
      const char *key = va_arg (ap, const char *);
      if (!key) break;
      const char *value = va_arg (ap, const char *);
      if (!value) break;
      if (strcmp (key, GSOUND_ATTR_EVENT_ID) == 0)
        event_id = value;
      else if (enabled && strcmp (key, GSOUND_ATTR_CANBERRA_ENABLE) == 0)
        *enabled = !attr_value_is_false (value);
    }
  return event_id;
}

GSoundContext *
gsound_context_new (GCancellable *cancellable, GError **error)
{
  (void) cancellable; (void) error;
  return g_object_new (GSOUND_TYPE_CONTEXT, NULL);
}

gboolean gsound_context_open (GSoundContext *c, GError **e) { (void) c; (void) e; return TRUE; }
gboolean gsound_context_set_attributes (GSoundContext *c, GError **e, ...) { (void) c; (void) e; return TRUE; }
gboolean gsound_context_set_attributesv (GSoundContext *c, GHashTable *a, GError **e) { (void) c; (void) a; (void) e; return TRUE; }
gboolean gsound_context_set_driver (GSoundContext *c, const char *d, GError **e) { (void) c; (void) d; (void) e; return TRUE; }
gboolean
gsound_context_play_simple (GSoundContext *c, GCancellable *ca, GError **e, ...)
{
  (void) c; (void) ca; (void) e;
  gboolean enabled = TRUE;
  va_list ap;
  va_start (ap, e);
  const char *event_id = event_id_from_valist (ap, &enabled);
  va_end (ap);
  return enabled ? play_event_id (event_id, FALSE) : TRUE;
}

gboolean
gsound_context_play_simplev (GSoundContext *c, GHashTable *a, GCancellable *ca, GError **e)
{
  (void) c; (void) ca; (void) e;
  gboolean enabled = TRUE;
  const char *event_id = event_id_from_attrs (a, &enabled);
  return enabled ? play_event_id (event_id, FALSE) : TRUE;
}
gboolean gsound_context_cache (GSoundContext *c, GError **e, ...) { (void) c; (void) e; return TRUE; }
gboolean gsound_context_cachev (GSoundContext *c, GHashTable *a, GError **e) { (void) c; (void) a; (void) e; return TRUE; }

/* Async play: dispatch the system sound above, then complete via a GTask so the caller's
 * callback fires and play_full_finish() reports the operation correctly. */
static void
play_full_common (GSoundContext *c, GCancellable *ca, GAsyncReadyCallback cb, gpointer ud)
{
  GTask *task = g_task_new (c, ca, cb, ud);
  g_task_return_boolean (task, TRUE);
  g_object_unref (task);
}

void
gsound_context_play_full (GSoundContext *c, GCancellable *ca,
                          GAsyncReadyCallback cb, gpointer ud, ...)
{
  gboolean enabled = TRUE;
  va_list ap;
  va_start (ap, ud);
  const char *event_id = event_id_from_valist (ap, &enabled);
  va_end (ap);
  if (enabled)
    play_event_id (event_id, TRUE);
  play_full_common (c, ca, cb, ud);
}

void
gsound_context_play_fullv (GSoundContext *c, GHashTable *a, GCancellable *ca,
                           GAsyncReadyCallback cb, gpointer ud)
{
  gboolean enabled = TRUE;
  const char *event_id = event_id_from_attrs (a, &enabled);
  if (enabled)
    play_event_id (event_id, TRUE);
  play_full_common (c, ca, cb, ud);
}

gboolean
gsound_context_play_full_finish (GSoundContext *c, GAsyncResult *r, GError **e)
{
  (void) c;
  return g_task_propagate_boolean (G_TASK (r), e);
}
