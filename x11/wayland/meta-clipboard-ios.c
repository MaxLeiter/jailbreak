/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

#include "config.h"

#include "backends/ios/meta-clipboard-ios.h"

#include <gio/gio.h>
#include <wayland-server-core.h>

#include "backends/ios/iosc-clipboard-bridge.h"
#include "backends/meta-backend-private.h"
#include "meta/display.h"
#include "meta/meta-context.h"
#include "meta/meta-selection-source.h"
#include "meta/meta-selection.h"
#include "meta/meta-wayland-compositor.h"
#include "xios_surface.h"

typedef struct _MetaSelectionSourceIOS
{
  MetaSelectionSource parent_instance;
  GBytes *items[XIOS_CLIP_KIND_HTML + 1];
} MetaSelectionSourceIOS;

typedef struct _MetaSelectionSourceIOSClass
{
  MetaSelectionSourceClass parent_class;
} MetaSelectionSourceIOSClass;

#define META_TYPE_SELECTION_SOURCE_IOS (meta_selection_source_ios_get_type ())
GType meta_selection_source_ios_get_type (void);
G_DEFINE_TYPE (MetaSelectionSourceIOS,
               meta_selection_source_ios,
               META_TYPE_SELECTION_SOURCE)

struct _MetaClipboardIOS
{
  int ref_count;
  gboolean stopped;
  gboolean started;
  gboolean applying_remote;

  MetaContext *context;                 /* backend/context own this */
  MetaSelection *selection;             /* display owns this */
  char *socket_path;
  gulong context_started_id;
  gulong owner_changed_id;

  MetaSelectionSource *current_owner;
  MetaSelectionSource *remote_source;
  GBytes *remote_items[XIOS_CLIP_KIND_HTML + 1];

  guint64 outbound_serial;
  GCancellable *outbound_cancellable;
};

typedef struct
{
  MetaClipboardIOS *clipboard;
  guint64 serial;
  unsigned pending;
  unsigned published;
} OutboundBatch;

typedef struct
{
  OutboundBatch *batch;
  uint32_t kind;
  GMemoryOutputStream *output;
} OutboundTransfer;

static MetaClipboardIOS *
meta_clipboard_ios_ref (MetaClipboardIOS *clipboard)
{
  g_atomic_int_inc (&clipboard->ref_count);
  return clipboard;
}

static void
clear_items (GBytes **items)
{
  for (uint32_t kind = XIOS_CLIP_KIND_TEXT;
       kind <= XIOS_CLIP_KIND_HTML;
       kind++)
    g_clear_pointer (&items[kind], g_bytes_unref);
}

static void
meta_clipboard_ios_unref (MetaClipboardIOS *clipboard)
{
  if (!g_atomic_int_dec_and_test (&clipboard->ref_count))
    return;

  clear_items (clipboard->remote_items);
  g_clear_object (&clipboard->current_owner);
  g_clear_object (&clipboard->remote_source);
  g_clear_object (&clipboard->outbound_cancellable);
  g_free (clipboard->socket_path);
  g_free (clipboard);
}

static void
meta_selection_source_ios_read_async (MetaSelectionSource *source,
                                      const char          *mimetype,
                                      GCancellable        *cancellable,
                                      GAsyncReadyCallback  callback,
                                      gpointer             user_data)
{
  MetaSelectionSourceIOS *source_ios = (MetaSelectionSourceIOS *) source;
  g_autoptr (GTask) task = g_task_new (source, cancellable, callback, user_data);
  uint32_t kind = ioscclip_kind_for_mime (mimetype);

  g_task_set_source_tag (task, meta_selection_source_ios_read_async);
  if (kind == XIOS_CLIP_KIND_NONE || !source_ios->items[kind])
    {
      g_task_return_new_error (task,
                               G_IO_ERROR,
                               G_IO_ERROR_NOT_FOUND,
                               "MIME type is not in the Xios clipboard");
      return;
    }

  g_task_return_pointer (
    task,
    g_memory_input_stream_new_from_bytes (source_ios->items[kind]),
    g_object_unref);
}

static GInputStream *
meta_selection_source_ios_read_finish (MetaSelectionSource  *source,
                                       GAsyncResult         *result,
                                       GError              **error)
{
  g_return_val_if_fail (
    g_task_get_source_tag (G_TASK (result)) ==
      meta_selection_source_ios_read_async,
    NULL);
  return g_task_propagate_pointer (G_TASK (result), error);
}

static GList *
meta_selection_source_ios_get_mimetypes (MetaSelectionSource *source)
{
  MetaSelectionSourceIOS *source_ios = (MetaSelectionSourceIOS *) source;
  GList *mimetypes = NULL;

  for (uint32_t kind = XIOS_CLIP_KIND_TEXT;
       kind <= XIOS_CLIP_KIND_HTML;
       kind++)
    {
      const char *mimetype;

      if (!source_ios->items[kind])
        continue;
      mimetype = ioscclip_mime_for_kind (kind);
      if (mimetype)
        mimetypes = g_list_append (mimetypes, g_strdup (mimetype));
    }

  return mimetypes;
}

static void
meta_selection_source_ios_finalize (GObject *object)
{
  MetaSelectionSourceIOS *source_ios = (MetaSelectionSourceIOS *) object;

  clear_items (source_ios->items);
  G_OBJECT_CLASS (meta_selection_source_ios_parent_class)->finalize (object);
}

static void
meta_selection_source_ios_class_init (MetaSelectionSourceIOSClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  MetaSelectionSourceClass *source_class = META_SELECTION_SOURCE_CLASS (klass);

  object_class->finalize = meta_selection_source_ios_finalize;
  source_class->get_mimetypes = meta_selection_source_ios_get_mimetypes;
  source_class->read_async = meta_selection_source_ios_read_async;
  source_class->read_finish = meta_selection_source_ios_read_finish;
}

static void
meta_selection_source_ios_init (MetaSelectionSourceIOS *source)
{
}

static MetaSelectionSource *
meta_selection_source_ios_new (GBytes **items)
{
  MetaSelectionSourceIOS *source =
    g_object_new (META_TYPE_SELECTION_SOURCE_IOS, NULL);

  for (uint32_t kind = XIOS_CLIP_KIND_TEXT;
       kind <= XIOS_CLIP_KIND_HTML;
       kind++)
    {
      if (items[kind])
        source->items[kind] = g_bytes_ref (items[kind]);
    }

  return META_SELECTION_SOURCE (source);
}

static void
discard_outbound (MetaClipboardIOS *clipboard)
{
  clipboard->outbound_serial++;
  if (clipboard->outbound_cancellable)
    g_cancellable_cancel (clipboard->outbound_cancellable);
  g_clear_object (&clipboard->outbound_cancellable);
}

static void
outbound_batch_finish (OutboundBatch *batch)
{
  MetaClipboardIOS *clipboard = batch->clipboard;

  if (!clipboard->stopped &&
      batch->serial == clipboard->outbound_serial &&
      batch->published == 0)
    ioscclip_selection_clear ();

  meta_clipboard_ios_unref (clipboard);
  g_free (batch);
}

static void
selection_transfer_done (MetaSelection *selection,
                         GAsyncResult  *result,
                         gpointer       user_data)
{
  OutboundTransfer *transfer = user_data;
  OutboundBatch *batch = transfer->batch;
  MetaClipboardIOS *clipboard = batch->clipboard;
  g_autoptr (GError) error = NULL;

  if (meta_selection_transfer_finish (selection, result, &error) &&
      !clipboard->stopped &&
      batch->serial == clipboard->outbound_serial)
    {
      gsize size = g_memory_output_stream_get_data_size (transfer->output);
      gpointer data = g_memory_output_stream_get_data (transfer->output);

      if (size <= XIOS_CLIP_ITEM_MAX &&
          ioscclip_publish (transfer->kind, data, size) == 0)
        batch->published++;
    }
  else if (error &&
           !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      g_warning ("MetaClipboardIOS: clipboard transfer failed: %s",
                 error->message);
    }

  g_object_unref (transfer->output);
  g_free (transfer);

  batch->pending--;
  if (batch->pending == 0)
    outbound_batch_finish (batch);
}

static void
publish_current_selection (MetaClipboardIOS *clipboard,
                           MetaSelectionSource *new_owner)
{
  char *chosen[XIOS_CLIP_KIND_HTML + 1] = { NULL };
  GList *mimetypes;
  unsigned count = 0;

  discard_outbound (clipboard);
  if (!new_owner)
    {
      ioscclip_selection_clear ();
      return;
    }

  mimetypes =
    meta_selection_get_mimetypes (clipboard->selection,
                                  META_SELECTION_CLIPBOARD);
  for (GList *l = mimetypes; l; l = l->next)
    {
      const char *mimetype = l->data;
      uint32_t kind = ioscclip_kind_for_mime (mimetype);

      if (kind == XIOS_CLIP_KIND_NONE || chosen[kind])
        continue;
      chosen[kind] = g_strdup (mimetype);
      count++;
    }
  g_list_free_full (mimetypes, g_free);

  if (count == 0)
    {
      ioscclip_selection_clear ();
      return;
    }

  ioscclip_selection_begin ();
  clipboard->outbound_cancellable = g_cancellable_new ();

  OutboundBatch *batch = g_new0 (OutboundBatch, 1);
  batch->clipboard = meta_clipboard_ios_ref (clipboard);
  batch->serial = clipboard->outbound_serial;
  batch->pending = count;

  for (uint32_t kind = XIOS_CLIP_KIND_TEXT;
       kind <= XIOS_CLIP_KIND_HTML;
       kind++)
    {
      OutboundTransfer *transfer;

      if (!chosen[kind])
        continue;

      transfer = g_new0 (OutboundTransfer, 1);
      transfer->batch = batch;
      transfer->kind = kind;
      transfer->output =
        G_MEMORY_OUTPUT_STREAM (g_memory_output_stream_new_resizable ());

      meta_selection_transfer_async (
        clipboard->selection,
        META_SELECTION_CLIPBOARD,
        chosen[kind],
        (gssize) XIOS_CLIP_ITEM_MAX + 1,
        G_OUTPUT_STREAM (transfer->output),
        clipboard->outbound_cancellable,
        (GAsyncReadyCallback) selection_transfer_done,
        transfer);
      g_free (chosen[kind]);
    }
}

static void
selection_owner_changed (MetaSelection       *selection,
                         guint                selection_type,
                         MetaSelectionSource *new_owner,
                         gpointer             user_data)
{
  MetaClipboardIOS *clipboard = user_data;

  if (selection_type != META_SELECTION_CLIPBOARD)
    return;

  g_set_object (&clipboard->current_owner, new_owner);
  if (clipboard->applying_remote)
    return;

  publish_current_selection (clipboard, new_owner);
}

static void
clipboard_from_host (uint32_t    kind,
                     const void *data,
                     size_t      len,
                     int         first_of_set,
                     void       *user_data)
{
  MetaClipboardIOS *clipboard = user_data;

  if (clipboard->stopped || !clipboard->selection)
    return;

  if (first_of_set)
    {
      discard_outbound (clipboard);
      clear_items (clipboard->remote_items);
    }

  if (kind == XIOS_CLIP_KIND_NONE)
    {
      g_autoptr (MetaSelectionSource) owner = NULL;

      if (clipboard->current_owner)
        owner = g_object_ref (clipboard->current_owner);
      clipboard->applying_remote = TRUE;
      if (owner)
        meta_selection_unset_owner (clipboard->selection,
                                    META_SELECTION_CLIPBOARD,
                                    owner);
      clipboard->applying_remote = FALSE;
      g_clear_object (&clipboard->remote_source);
      return;
    }

  g_clear_pointer (&clipboard->remote_items[kind], g_bytes_unref);
  clipboard->remote_items[kind] = g_bytes_new (data, len);

  g_autoptr (MetaSelectionSource) source =
    meta_selection_source_ios_new (clipboard->remote_items);
  clipboard->applying_remote = TRUE;
  meta_selection_set_owner (clipboard->selection,
                            META_SELECTION_CLIPBOARD,
                            source);
  clipboard->applying_remote = FALSE;
  g_set_object (&clipboard->remote_source, source);
}

static void
context_started (MetaContext      *context,
                 MetaClipboardIOS *clipboard)
{
  MetaDisplay *display = meta_context_get_display (context);
  MetaWaylandCompositor *compositor =
    meta_context_get_wayland_compositor (context);
  struct wl_display *wayland_display;

  if (!display || !compositor)
    {
      g_warning ("MetaClipboardIOS: compositor selection is unavailable");
      return;
    }

  clipboard->selection = meta_display_get_selection (display);
  wayland_display =
    meta_wayland_compositor_get_wayland_display (compositor);
  if (ioscclip_start (wl_display_get_event_loop (wayland_display),
                      clipboard->socket_path,
                      clipboard_from_host,
                      clipboard) != 0)
    {
      g_warning ("MetaClipboardIOS: could not listen at %s",
                 clipboard->socket_path);
      clipboard->selection = NULL;
      return;
    }

  clipboard->owner_changed_id =
    g_signal_connect (clipboard->selection,
                      "owner-changed",
                      G_CALLBACK (selection_owner_changed),
                      clipboard);
  clipboard->started = TRUE;
  g_message ("MetaClipboardIOS: strict-v%u bridge listening at %s",
             XIOS_PROTOCOL_VERSION,
             clipboard->socket_path);
}

MetaClipboardIOS *
meta_clipboard_ios_new (MetaBackend *backend,
                        const char  *socket_path)
{
  MetaClipboardIOS *clipboard;

  g_return_val_if_fail (META_IS_BACKEND (backend), NULL);
  g_return_val_if_fail (socket_path && *socket_path, NULL);

  clipboard = g_new0 (MetaClipboardIOS, 1);
  clipboard->ref_count = 1;
  clipboard->context = meta_backend_get_context (backend);
  clipboard->socket_path = g_strdup (socket_path);
  clipboard->context_started_id =
    g_signal_connect (clipboard->context,
                      "started",
                      G_CALLBACK (context_started),
                      clipboard);
  return clipboard;
}

void
meta_clipboard_ios_free (MetaClipboardIOS *clipboard)
{
  if (!clipboard || clipboard->stopped)
    return;

  clipboard->stopped = TRUE;
  discard_outbound (clipboard);
  if (clipboard->owner_changed_id && clipboard->selection)
    g_signal_handler_disconnect (clipboard->selection,
                                 clipboard->owner_changed_id);
  if (clipboard->context_started_id)
    g_signal_handler_disconnect (clipboard->context,
                                 clipboard->context_started_id);
  if (clipboard->started)
    ioscclip_stop ();
  clipboard->selection = NULL;
  meta_clipboard_ios_unref (clipboard);
}
