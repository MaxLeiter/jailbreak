/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-stage-ios.c — the MetaBackendIOS ClutterStageWindow (see the header).
 *
 * Supplies the ClutterStageWindow vfuncs the base MetaStageImpl leaves NULL, bridged to
 * MetaRendererIOS: get_geometry from the (single fixed) monitor and get_views from the
 * renderer. redraw_view is inherited from MetaStageImpl, whose swap path calls
 * cogl_onscreen_swap_buffers_with_damage on our view framebuffer — which IS a CoglOnscreen
 * (MetaOnscreenIOS), so the present (finish + xios_notify_dirty) happens there, NOT here.
 * finish_frame therefore only settles the frame result. realize / resize / show / hide /
 * get_frame_counter are inherited from MetaStageImpl. Modeled on meta-stage-native.c minus
 * the KMS/atomic per-frame prep. GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-stage-ios.h"

#include "backends/meta-backend-private.h"
#include "backends/meta-renderer.h"
#include "meta/meta-backend.h"
#include "meta/meta-monitor-manager.h"

struct _MetaStageIOS
{
  MetaStageImpl parent;
};

static void clutter_stage_window_iface_init (ClutterStageWindowInterface *iface);

G_DEFINE_TYPE_WITH_CODE (MetaStageIOS, meta_stage_ios, META_TYPE_STAGE_IMPL,
                         G_IMPLEMENT_INTERFACE (CLUTTER_TYPE_STAGE_WINDOW,
                                                clutter_stage_window_iface_init))

static void
meta_stage_ios_get_geometry (ClutterStageWindow *stage_window,
                             MtkRectangle       *geometry)
{
  MetaStageImpl *stage_impl = META_STAGE_IMPL (stage_window);
  MetaBackend *backend = meta_stage_impl_get_backend (stage_impl);
  MetaMonitorManager *monitor_manager =
    meta_backend_get_monitor_manager (backend);

  if (monitor_manager)
    {
      int width, height;

      meta_monitor_manager_get_screen_size (monitor_manager, &width, &height);
      *geometry = (MtkRectangle) {
        .width = width,
        .height = height,
      };
    }
  else
    {
      *geometry = (MtkRectangle) {
        .width = 1,
        .height = 1,
      };
    }
}

static GList *
meta_stage_ios_get_views (ClutterStageWindow *stage_window)
{
  MetaStageImpl *stage_impl = META_STAGE_IMPL (stage_window);
  MetaBackend *backend = meta_stage_impl_get_backend (stage_impl);
  MetaRenderer *renderer = meta_backend_get_renderer (backend);

  return meta_renderer_get_views (renderer);
}

static gboolean
meta_stage_ios_can_clip_redraws (ClutterStageWindow *stage_window)
{
  return TRUE;
}

static void
meta_stage_ios_prepare_frame (ClutterStageWindow *stage_window,
                              ClutterStageView   *stage_view,
                              ClutterFrame       *frame)
{
  /* No per-frame renderer prep on iOS (no KMS/atomic commit); the present happens in
   * finish_frame via the IOSurface dirty-notify. */
}

static void
meta_stage_ios_finish_frame (ClutterStageWindow *stage_window,
                             ClutterStageView   *stage_view,
                             ClutterFrame       *frame)
{
  /* If this frame actually painted, the redraw path's onscreen swap (MetaOnscreenIOS::
   * swap_buffers_with_damage) already set the result to PENDING_PRESENTED and a COMPLETE frame
   * event is on its way to drive clutter_stage_view_notify_presented. If the frame had NO redraw
   * clip, redraw_view (and therefore the swap) never ran, so there is NO result yet and NO
   * presentation notification will come. Settle those as IDLE so the ClutterFrameClock re-arms
   * immediately instead of hanging in PENDING_PRESENTED forever.
   *
   * This was THE input-delivery bug: previously finish_frame unconditionally forced
   * PENDING_PRESENTED, so any input-only frame (pointer events don't dirty the stage, so the
   * frame carries no redraw clip -> no swap -> no COMPLETE) left the clock stuck. With the clock
   * stalled, handle_frame_clock_before_frame -> _clutter_stage_process_queued_events never ran
   * again, so queued MOTION/BUTTON events were never delivered to actors (hover + clicks dead)
   * even though pointer motion still injected and crossings — emitted synchronously in
   * clutter_stage_handle_event — kept updating the actor-under-cursor. Mirrors
   * meta_stage_native_finish_frame's `if (!has_result) set IDLE`. */
  if (!clutter_frame_has_result (frame))
    clutter_frame_set_result (frame, CLUTTER_FRAME_RESULT_IDLE);
}

static void
clutter_stage_window_iface_init (ClutterStageWindowInterface *iface)
{
  iface->get_geometry = meta_stage_ios_get_geometry;
  iface->get_views = meta_stage_ios_get_views;
  iface->can_clip_redraws = meta_stage_ios_can_clip_redraws;
  iface->prepare_frame = meta_stage_ios_prepare_frame;
  iface->finish_frame = meta_stage_ios_finish_frame;
}

static void
meta_stage_ios_init (MetaStageIOS *stage_ios)
{
}

static void
meta_stage_ios_class_init (MetaStageIOSClass *klass)
{
}
