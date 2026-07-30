# Perf / Followup Backlog (audit 2026-06-30; implementation passes through 2026-07-02 — line numbers cited below drift as files change; treat them as anchors, re-grep before editing)

AUDIT COMPLETE with follow-up fixes landing incrementally. Prioritized backlog for the X11-on-iOS project, evidence-cited. Repo root /Users/max/Documents/jailbreak.

RE-VERIFIED 2026-07-29 against the tree (device checks limited — the KDE stack was down
mid-install by another session). Confirmed still DONE by code inspection: P0.2 (per-surface
shm cache + glTexSubImage2D damage uploads, iosc_gl.c:480-537), P0.3 (glFlush + EGL fence,
glFinish only as the no-extension fallback, iosc_gl.c:638-649), P0.6 (IOSC_NBUF 3 rotation).
Confirmed still OPEN: P0.5 (software readback). Updated below: P0.1 (a stale conffile caveat),
P2.1 (line counts grew), P2.7 (now resolved), P3 (panel renderer re-confirmed as the last
CPU painter in the desktop).

=== P0 — CPU where GPU should be (north-star violations, ranked by per-frame cost) ===

P0.1 ✅ DONE/VALIDATED — GTK4 app (kgx) renders GSK-ngl → ANGLE Metal → rotating IOSurfaces → zero-copy into iosc, and the entitlement/shim packaging defaults have since shipped across the GTK4 app wave. The shim fix chain (extension injection for EGL platform Wayland + proc-address fallback + WINDOW→PBUFFER config rewrite) remains required. GTK GPU clients use the narrow AGX/IOGPU entitlement tier; the ANGLE package stages the iosc EGL shim at `/var/jb/lib/angle/libEGL.dylib` and keeps real ANGLE at `libEGL.angle.dylib`. Original finding:
GTK4 clients are forced to CPU cairo rendering despite a validated zero-copy GPU client path.
- x11/apps/iosc-desktop/src/ioscd.c:238 `setenv("GSK_RENDERER","cairo",1)` and x11/wayland/run-kgx.sh:60 — every launched app renders every frame on the CPU into wl_shm, which iosc then re-uploads (see P0.2). Meanwhile iosc_egl_shim.c (built as libiosc_egl.dylib, build-iosc.sh:306-317) already gives any wl_egl_window client (GTK4/GSK, Qt, SDL) ANGLE→Metal rendering straight into IOSurfaces handed to iosc zero-copy, and mutter-on-iosc.md:179 calls it "the client-side GPU path for any wl_egl_window client".
- Fix: flip launchers to GSK_RENDERER=ngl/gl with the shim preloaded (gdk-wayland EGL on ANGLE — same primitive the chooser memory lists for qtwayland), keep cairo as fallback. This is the single biggest CPU load in the desktop: N apps × full-window CPU paint + upload per frame.
- Effort: medium (env/link wiring is small; validating GSK-on-ANGLE-wayland on device is the real work). Owner: desktop-env/iosc track.
- CAVEAT found 2026-07-29 (does NOT reopen P0.1; the session path is genuinely GPU): the
  session forces ngl via `setenv("GSK_RENDERER","ngl",1)` — overwrite flag 1 — in
  ioscd.c:1137 and iosc-shell/shell-draw.h:416, plus xios-session-lib.sh:1042 and
  xios-capability-profiles.sh:122,181. So anything the desktop launches is on GSK-ngl
  regardless of the environment. BUT the installed `libgtk-4-1 4.14.5+wl1` still ships
  `/var/jb/etc/profile.d/10-gtk-renderer.sh` = cairo, so a GTK4 app started from an
  interactive login shell (e.g. over SSH, outside the session) silently CPU-renders.
  gtk4.mk:101 already prints `ngl`, so a gtk4 rebuild fixes the default — but note dpkg
  considers that conffile locally modified on Max's device (a `.dpkg-dist` is already
  parked beside it), so the upgrade will NOT replace it; the file needs reconciling
  by hand or the device stays on cairo for shell-launched apps and it will look like
  the rebuild didn't work.

P0.2 ✅ DONE (5aaf0fe; validated on-device 2026-07-01 — per-surface texture cache, two windows composite correct colors on GPU, cursor motion = zero uploads). wl_shm composite path re-uploads EVERY visible shm window on EVERY recomposite — including pure cursor moves.
- iosc_gl.c:38 a single reused texture `s_shm_tex` for ALL shm surfaces; iosc_gl_draw_shm (iosc_gl.c:207-235) does a full glTexImage2D upload per surface per draw. recomposite_all (iosc.c:924-995) redraws all mapped surfaces on any damage, and cursor motion triggers it too (iosc.c:3224, drag at 3181). Net: moving the mouse re-uploads every shm window's full pixels to the GPU.
- Fix: per-surface GL texture cache (like cache_get for IOSurfaces, iosc_gl.c:197), upload only committed damage regions via glTexSubImage2D at commit time; composite from cached textures. Cursor motion then costs zero uploads. Also consider a present-side cursor overlay in the Xios app so cursor moves don't recomposite at all (mutter doc notes iOS has no cursor plane; meta-backend-ios.c:91 uses software cursor too).
- Effort: small-medium, contained to iosc_gl.c + commit path. Owner: iosc compositor track. Biggest win after P0.1; also mostly obsoleted BY P0.1 for GPU clients, but shm clients (panel, misc) remain.

P0.3 ✅ DONE (b9cbdec; validated on-device 2026-07-01 — "frame barrier = EGL fence" confirmed on A10, readbacks/logs gated behind IOSC_DEBUG). Per-frame GPU sync + readback + log spam in the compositor hot path (validation debris).
- iosc_gl_end (iosc_gl.c:237-244): glFinish + glReadPixels of the center pixel EVERY frame. recomposite_all then does one more glReadPixels per window (iosc.c:955-960 via iosc_gl_read_at) and unconditional multi-line fprintf per recomposite (iosc.c:936, 954-961); xt_set_app_id also logs unconditionally (iosc.c:2234). glFinish serializes CPU/GPU every frame; readbacks force pipeline stalls.
- Fix: gate all validation reads/logs behind an IOSC_DEBUG env (IOSC_PROBE already is, iosc.c:968); replace glFinish with glFlush + a fence/EGL sync before xios_notify_dirty.
- Effort: small. Owner: iosc compositor track. Cheapest P0 — do first.

P0.4 ✅ DONE 2026-07-29 — display-refresh pacing landed; the repaint is now vblank-paced
and frame callbacks retire on actual present. The 2026-07-02 half (coalesce to one idle
per event-loop turn, present-side cursor overlay auto-enabling for a typed Xios client
via `IOSC_APP_CURSOR=0/1`, callbacks and presentation feedback after the coalesced
repaint rather than at commit) is unchanged; what closes the item is the other half:
- The app streams its display clock over the existing app socket as XIOS_MSG_PACING
  (0x06): CADisplayLink.targetTimestamp, the refresh interval, and the
  CAFrameRateRange. iosc schedules the coalesced repaint to FINISH a quarter-interval
  before the app's next tick samples the output IOSurface, instead of on the next
  event-loop turn (`repaint_delay_ms` / `g_repaint_timer` in iosc.c). No display clock
  = the old idle behaviour, byte for byte.
- XIOS_MSG_PRESENTED gained the real `presentedTime` from
  MTLDrawable.addPresentedHandler, and the ack MOVED from the command buffer's
  completed handler to the drawable's presented handler — which is what makes
  wl_surface.frame retire post-present rather than post-repaint. Presentation-time
  feedback reports the measured present and the real refresh interval instead of "now"
  and a hardcoded 16666666.
- Wire values are deltas from send time, never timestamps: CACurrentMediaTime() and
  CLOCK_MONOTONIC are different clocks. See XIOS_MSG_PACING in xios_surface.h.
- `preferredFramesPerSecond` (deprecated) is gone; the 20/60 flip is now two
  CAFrameRateRanges behind one `setPacingRange()` seam.
- Visibility: `pacing=vblank fps=... interval=...` in `xios-status`, published
  separately by the app and the compositor so "the app is offering a clock" and "the
  compositor accepted one" are distinguishable.
Original finding: No frame pacing: every commit triggers an immediate synchronous full recomposite; frame callbacks fire instantly.
- iosc.c:1408-1416 — commit → recomposite_all (with the P0.3 glFinish) → wl_callback_send_done immediately. An animating client re-renders as fast as it can; two busy clients = 2 full composites per their combined commit rate, unbounded by display refresh.
- STILL OPEN, split out of P0.4: the multi-buffer half of the original fix. iosc still
  composites into the SAME output IOSurface the app presents from, so the tearing
  window named here remains, and Mutter integration still wants the 2-3 surface
  rotation (mutter-on-iosc.md risk #7: reconcile CoglOnscreen swap with single-surface
  present). Pacing narrows that window — the composite now lands in a known gap before
  the app samples — but does not close it. Effort: medium. Owner: iosc compositor track.
- ALSO OPEN: the native iPadOS flavor (iosc-host) is unpaced. It draws per-window
  canvases over the NATIVE_FRAME record family, so there is no single dirty/present
  channel to carry targetTimestamp and no shared output surface to report a present
  for; it got the CAFrameRateRange only. Pacing it means per-window pacing state on the
  0x40-0x5f records. Effort: medium. Owner: native-iPadOS track.

P0.5 wlr-screencopy is a software row-memcpy readback (the known one — confirmed).
- iosc.c:997-1004 explicitly "SOFTWARE readback; GPU-blit later", clean seam named: xios_read_output_region()'s body plus a fast-path. Implementation is IOSurfaceLock + per-row memcpy in x11/linux-build/patches/xios/xios_surface.c:497-514.
- Per-screenshot, not per-frame, so it ranks below P0.1-P0.4 despite being the marquee example. Fix per the seam comment: GPU blit (glReadPixels into a PBO, or blit output→staging IOSurface) inside xios_read_output_region + fast-path in screencopy_copy (iosc.c:1022-1043).
- Effort: small-medium. Owner: iosc compositor track.
- STILL OPEN, re-verified 2026-07-29: `xios_read_output_region` has moved to
  xios_surface.c:904 and still does the per-row `memcpy` (now line 923).
  Unchanged in substance; only the line anchors drifted.

P0.6 ✅ DONE 2026-07-02 — eglSwapBuffers in the EGL shim now uses an EGL fence/client wait with glFlush and falls back to glFinish only if sync is unavailable; IOSC_NBUF=3 rotates on wl_buffer.release and scans all buffers before blocking so it no longer stalls on an arbitrary `cur+1` buffer while another buffer is free. Original finding: Client-side glFinish per swap in the EGL shim.
- iosc_egl_shim.c header (line ~16): eglSwapBuffers = "glFinish, hand pbuf[cur]'s IOSurface to iosc". Full client GPU sync every frame for every GPU client. Fix: fence/sync object + buffer-release-driven rotation (IOSC_NBUF is already 3). Effort: small-medium. Matters more once P0.1 makes GPU clients the norm.

P0.7 ✅ DONE 2026-07-02 — Xwayland glamor IOSurface damage now uses a per-frame EGL fence when `EGL_KHR_fence_sync` is available, falling back to `glFinish()` only when sync support is missing. Original finding: Xwayland's IOSurface glamor backend drained the whole GPU pipeline on every damage post.

=== P1 — Shortcuts/stopgaps that risk correctness or block features ===

P1.1 ✅ DONE before 2026-07-02 — iosc now consumes the shared xios_input_socket reader; the old inline framing path is gone from the hot input socket. Original finding: Input-reader duplication: iosc.c's inline reader (in_client_readable etc., ~iosc.c:4440-4520) vs the extracted copy xios_input_socket.c ("Extracted from iosc.c's inline reader... so iosc and MetaBackendIOS share one framing implementation", xios_input_socket.c:1-10). iosc still uses its inline copy — two framing state machines that can drift. Planned unification (iosc links libxios_glue) is explicitly "post-validation". Owner: iosc track.

P1.2 ✅ DONE — the flat MetaBackendIOS glue contract is checked against canonical `xios_input_socket.h`, `xios_egl.h`, and `xios_surface.h`; the type registry, message layout, input API, EGL API, and surface lifecycle cannot silently drift before backend compilation. Original finding: MetaBackendIOS compiled against a local declaration header while libxios_glue shipped separate canonical headers. Owner: mutter track.

P1.3 ✅ DONE — MetaBackendIOS compiles/returns a real default `us` xkb_keymap, MetaSeatIOS exposes a ClutterKeymap, and `update_stage` rebuilds renderer views and sizes the stage. `get_input_settings()` intentionally returns NULL because the backend has no physical/libinput devices to configure; that is an iOS invariant, not an unfinished stub. Original finding was from the pre-first-light backend. Owner: mutter track.

P1.4 ✅ CORE RISKS CLOSED — Cogl-on-ANGLE FBO-0 rendering and Xios presentation reached first pixels; IOSurface client imports use the implemented ANGLE pbuffer/EGLImage bridge; login1/session shims boot the packaged GNOME session; and dead X11/XCB links are postprocessed in the Mutter package. Broader gsd service coverage remains ordinary desktop polish and is tracked in `docs/handoff/gnome-session.md`, not a Mutter first-light blocker.

P1.5 ✅ DONE 2026-07-02 — xdg-activation tokens now store serial/seat/surface/app_id and commit records retain app_id for later policy/debug hooks. Original finding: xdg-activation token set_app_id is a silent no-op (iosc.c:1788-1790) — tokens don't carry app_id, so activation policy can't ever key on it. Minor today (single-user), one-liner to store.

P1.6 ✅ DONE — packaged ioscd creates `/var/jb/tmp/ioscd.sock` as `mobile:mobile` mode 0660; package reinstall validation confirmed the ownership/mode and functional launcher verbs.

P1.7 ✅ DONE 2026-07-02 — iosc's shared input socket now flushes Wayland clients once per drained socket batch instead of after every record, and the per-key stderr trace is behind `IOSC_DEBUG`. Original finding: motion/touch/text bursts paid repeated flush syscalls and every key emitted unconditional stderr.

=== P2 — Deferred followups / cleanups ===

P2.1 iosc.c megafile refactor is QUEUED and the file keeps growing: as of 2026-07-29 it is
8964 lines (plus XScreen.swift 4350) — up from 7153/2735 at the last pass, so both files grew
~25-60% while the refactor stayed queued; refactor-plan.md counts are stale again. Plan's precondition list (panel + input-unification landed, blend fix validated, freeze announced) — input-unification (P1.1) is now done, so the refactor gate is closer. XScreen.swift split is low-contention and can go first per the plan.

P2.2 Post-ICU re-enables (ICU build is task #3, in progress): (a) validate the EDS/calendar-server gnome-shell flavor now carried in `ports/gnome-shell/patches-eds`; the default `ports/gnome-shell/patches` stack still degrades JS side to an empty calendar; (b) rebuild tracker with ICU — tracker.mk:52-58 forces unistring ("only cost is no ICU-quality locale collation").

P2.3 Audio: only the libpulse-simple shim exists; full PulseAudio (or a native-protocol sink) is "still future work for the broadest desktop layer" and mic capture is explicitly deferred (docs/audio-plan.md:105-121).

P2.4 Packaging gaps: the Path-B Xios DDX/IOSurface display path is "functional and verified on-device, but not yet packaged as a .deb" (docs/USER-GUIDE.md:119); layer-shell panel and misc dev binaries live in wayland/out only.

P2.5 Nautilus ecosystem holes: no gvfs (Trash/Network empty), tracker-sparql built but no tracker-miners indexer (search inert), "heavy leaves trimmed" per docs/gnome-apps.md:165-169. GTK3 track wholly deferred (gnome-terminal optional-later, gnome-apps.md:170).

P2.6 ✅ DONE 2026-07-02 — iosc-desktop-env.md now documents the landed app_id raise socket and `ngl` GTK default; refactor-plan.md line counts/gates were refreshed. Original finding: iosc-desktop-env.md §7 still says iosc "cannot" raise by app_id and requests the feature — it HAS landed (wm control socket + wm_find_toplevel_by_app_id, iosc.c:4898-4940, socket up at iosc.c:5705). refactor-plan.md line counts stale (P2.1). Worth a doc pass so future agents don't re-implement.

P2.7 Uncommitted WIP in the working tree: apps/iosc-shell (build-panel.sh, iosc-shell.c, shell-draw.h), linux-build/recipes/startup-notification.mk, and rebuilt wayland/out binaries. NOTE (2026-07-02): the "PARKED per the distribution-chooser pivot" framing is now stale — the iosc-shell track has active, committed development (e.g. 1ee9ed9 configurable desktop widgets, b4819cd redraw hot-path optimization, 906f36d dock gestures, 4a99f44 bar/dock surface split), and iosc-shell.c + panel-layout.h are again modified in the working tree. Treat this as an active track, not a parked one; the residual action is still to commit-or-drop the loose working-tree changes so it isn't half-staged.
  ✅ RESOLVED 2026-07-29 — `git status --porcelain` is clean; the loose changes were committed.

P2.8 ✅ DONE before 2026-07-02 — kgx launchers use `kgx -T iosc-kgx -- /var/jb/usr/bin/bash -i`; the stale `-e <cmd>` memory note was incorrect for the current scripts. Original finding: kgx quirk: needs `-e <cmd>` to launch (memory note) — root-cause the default-shell spawn rather than carrying the workaround into launcher .desktop files.

=== P3 — Degraded-but-acceptable (record so we don't forget) ===

- ✅ DONE 2026-07-18 — the empty libgtop shim was replaced by `libgtop_ios.c`, which implements
  process enumeration, uid/parent lookup, and argv through Darwin sysctls. The arm64
  `libgtop-2.0-11 2.41.3+ios2` package is built; only device UI smoke remains.
- libei/libeis links-only shim (recipes/libei.mk:5-12): input capture / remote-desktop input NON-FUNCTIONAL by design, inert feature. Same pattern as stubbed libdrm.
- xios-login1-stub (wayland/xios-login1-stub.c): answers the logind calls gnome-session/gsd make; no real session/power management — intended.
- The incomplete top-surface-only CPU compositor remains solely behind
  `IOSC_ALLOW_CPU_DIAGNOSTIC=1`; production initialization and runtime GPU loss
  fail closed.
- The X11 flavor uses rootless Xwayland on GPU-accelerated iosc. The legacy
  bare Xios server, Xvfb, and VNC remain separately installable diagnostics and
  are no longer dependencies or recommendations of the flavor meta.
- split-shell cairo/pango CPU renderer — adequate for bar/dock chrome; renderer may be reused for native-mode window chrome.
  RE-CONFIRMED 2026-07-29: still the bar/dock path (iosc-shell/shell-draw.h:244-247 builds a
  `cairo_image_surface_create_for_data` + `cairo_t` and paints on the CPU). Note the `ngl`
  setenv at shell-draw.h:416 governs apps the shell LAUNCHES, not the shell's own painting —
  easy to misread as the panel being on the GPU. With P0.2 landed, a static panel costs ~zero
  re-uploads, so the cost only shows up when the panel actually animates (clock tick, dock
  gestures). This is now the last CPU painter in the desktop and the natural next target if
  the no-CPU-rendering goal is to be taken literally.
- gedit skipped in favor of gnome-text-editor (libpeas-2 typelib chain, gnome-apps.md:175-182).
- gnome-shell JS is interpreter-only (JIT-less mozjs) — animations may be sluggish on the A10; compositing stays GPU (mutter-on-iosc.md risk #5). Inherent, not fixable by us.
- ios-inputd degrades gracefully when input-method-v2/virtual-keyboard-v1 absent (ios-inputd.c:293-305) — both protocols are advertised by iosc, so messages are belt-and-braces.

Suggested dispatch order: P0.3 (hours, pure win) → P0.2 → P0.1 (the big one, needs on-device GSK-on-ANGLE validation) → P0.4 → P1.1 → P0.5/P0.6, with P1.3/P1.4 owned by the mutter track in parallel and P2.2 gated on ICU landing.

2026-07-29: P0.4 is closed except for the output-surface rotation and the native flavor,
both split out under it. Present-side MetalFX spatial upscaling landed alongside it
(opt-in, default off — `IOSC_UPSCALE=auto|<factor>`, or `XIOS_UPSCALE` in the app's own
environment; `upscale=` in `xios-status`). It is the cheapest remaining lever on this
hardware and does not appear as a numbered item here because it is not a shortcut being
paid down — see docs/ios-platform-features.md §2 on branch
claude/ios-features-graphics-50ff62. The thermal/jetsam track (§3 there) is sequenced
next and clamps the frame-rate range P0.4 introduced.
