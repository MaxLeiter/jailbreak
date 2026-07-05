# Perf / Followup Backlog (audit 2026-06-30; implementation passes through 2026-07-02 — line numbers cited below drift as files change; treat them as anchors, re-grep before editing)

AUDIT COMPLETE with follow-up fixes landing incrementally. Prioritized backlog for the X11-on-iOS project, evidence-cited. Repo root /Users/max/Documents/jailbreak.

=== P0 — CPU where GPU should be (north-star violations, ranked by per-frame cost) ===

P0.1 ✅ VALIDATED on-device 2026-07-01; packaging defaults implemented 2026-07-02 pending rebuild/validation — GTK4 app (kgx) renders GSK-ngl → ANGLE Metal → 3 rotating IOSurfaces → zero-copy into iosc. The shim fix chain (iosc-protocols commits: extension injection for EGL_*_platform_wayland + eglGetPlatformDisplayEXT-via-eglGetProcAddress with EGLint attribs matching xios_egl.c exactly + WINDOW→PBUFFER config rewrite) is correct + necessary. KEY BLOCKER was NOT the shim: GTK apps need GPU IOKit entitlements (AGXDeviceUserClient + IOGPUDeviceUserClient) or MTLCreateSystemDefaultDevice returns nil → ANGLE eglGetPlatformDisplay returns NO_DISPLAY → GSK falls back to CPU. IMPLEMENTED: GTK launch defaults now use IOSC_GSK_RENDERER fallback `ngl`, GTK profile defaults `GSK_RENDERER=${IOSC_GSK_RENDERER:-ngl}`, GTK4 app package recipes sign binaries with a self-contained GPU-client entitlement instead of Procursus general.xml/no-container, and the ANGLE package stages the iosc EGL shim as standing `/var/jb/lib/angle/libEGL.dylib` while keeping real ANGLE at `libEGL.angle.dylib`. REMAINING: rebuild packages and validate on-device. Original finding:
GTK4 clients are forced to CPU cairo rendering despite a validated zero-copy GPU client path.
- x11/apps/iosc-desktop/src/ioscd.c:238 `setenv("GSK_RENDERER","cairo",1)` and x11/wayland/run-kgx.sh:60 — every launched app renders every frame on the CPU into wl_shm, which iosc then re-uploads (see P0.2). Meanwhile iosc_egl_shim.c (built as libiosc_egl.dylib, build-iosc.sh:306-317) already gives any wl_egl_window client (GTK4/GSK, Qt, SDL) ANGLE→Metal rendering straight into IOSurfaces handed to iosc zero-copy, and mutter-on-iosc.md:179 calls it "the client-side GPU path for any wl_egl_window client".
- Fix: flip launchers to GSK_RENDERER=ngl/gl with the shim preloaded (gdk-wayland EGL on ANGLE — same primitive the chooser memory lists for qtwayland), keep cairo as fallback. This is the single biggest CPU load in the desktop: N apps × full-window CPU paint + upload per frame.
- Effort: medium (env/link wiring is small; validating GSK-on-ANGLE-wayland on device is the real work). Owner: desktop-env/iosc track.

P0.2 ✅ DONE (5aaf0fe; validated on-device 2026-07-01 — per-surface texture cache, two windows composite correct colors on GPU, cursor motion = zero uploads). wl_shm composite path re-uploads EVERY visible shm window on EVERY recomposite — including pure cursor moves.
- iosc_gl.c:38 a single reused texture `s_shm_tex` for ALL shm surfaces; iosc_gl_draw_shm (iosc_gl.c:207-235) does a full glTexImage2D upload per surface per draw. recomposite_all (iosc.c:924-995) redraws all mapped surfaces on any damage, and cursor motion triggers it too (iosc.c:3224, drag at 3181). Net: moving the mouse re-uploads every shm window's full pixels to the GPU.
- Fix: per-surface GL texture cache (like cache_get for IOSurfaces, iosc_gl.c:197), upload only committed damage regions via glTexSubImage2D at commit time; composite from cached textures. Cursor motion then costs zero uploads. Also consider a present-side cursor overlay in the Xios app so cursor moves don't recomposite at all (mutter doc notes iOS has no cursor plane; meta-backend-ios.c:91 uses software cursor too).
- Effort: small-medium, contained to iosc_gl.c + commit path. Owner: iosc compositor track. Biggest win after P0.1; also mostly obsoleted BY P0.1 for GPU clients, but shm clients (panel, misc) remain.

P0.3 ✅ DONE (b9cbdec; validated on-device 2026-07-01 — "frame barrier = EGL fence" confirmed on A10, readbacks/logs gated behind IOSC_DEBUG). Per-frame GPU sync + readback + log spam in the compositor hot path (validation debris).
- iosc_gl_end (iosc_gl.c:237-244): glFinish + glReadPixels of the center pixel EVERY frame. recomposite_all then does one more glReadPixels per window (iosc.c:955-960 via iosc_gl_read_at) and unconditional multi-line fprintf per recomposite (iosc.c:936, 954-961); xt_set_app_id also logs unconditionally (iosc.c:2234). glFinish serializes CPU/GPU every frame; readbacks force pipeline stalls.
- Fix: gate all validation reads/logs behind an IOSC_DEBUG env (IOSC_PROBE already is, iosc.c:968); replace glFinish with glFlush + a fence/EGL sync before xios_notify_dirty.
- Effort: small. Owner: iosc compositor track. Cheapest P0 — do first.

P0.4 ◐ PARTIAL 2026-07-02 — repaint is coalesced to one idle per event-loop turn, present-side cursor overlay support exists and now auto-enables when a typed Xios client is connected (`IOSC_APP_CURSOR=0/1` can force either path), wl_surface.frame callbacks retire after the coalesced repaint instead of immediately at commit, and presentation-time feedback is likewise sent after repaint instead of at commit. REMAINING: true output-refresh pacing from Xios/CADisplayLink present ack; callbacks are post-repaint but still event-loop paced, not display-vblank paced. Original finding: No frame pacing: every commit triggers an immediate synchronous full recomposite; frame callbacks fire instantly.
- iosc.c:1408-1416 — commit → recomposite_all (with the P0.3 glFinish) → wl_callback_send_done immediately. An animating client re-renders as fast as it can; two busy clients = 2 full composites per their combined commit rate, unbounded by display refresh.
- Fix: damage-accumulate + coalesce into one repaint per output refresh (a frame clock; the Xios app already runs a CADisplayLink, XScreen.swift:162 — the dirty/present channel could carry pacing back), send frame done on present. Also relevant to Mutter integration (mutter-on-iosc.md risk #7: reconcile CoglOnscreen swap with single-surface present; likely 2-3 output IOSurface rotation — which also removes the current tearing window of compositing into the same IOSurface the app is presenting from).
- Effort: medium. Owner: iosc compositor track.

P0.5 wlr-screencopy is a software row-memcpy readback (the known one — confirmed).
- iosc.c:997-1004 explicitly "SOFTWARE readback; GPU-blit later", clean seam named: xios_read_output_region()'s body plus a fast-path. Implementation is IOSurfaceLock + per-row memcpy in x11/linux-build/patches/xios/xios_surface.c:497-514.
- Per-screenshot, not per-frame, so it ranks below P0.1-P0.4 despite being the marquee example. Fix per the seam comment: GPU blit (glReadPixels into a PBO, or blit output→staging IOSurface) inside xios_read_output_region + fast-path in screencopy_copy (iosc.c:1022-1043).
- Effort: small-medium. Owner: iosc compositor track.

P0.6 ✅ DONE 2026-07-02 — eglSwapBuffers in the EGL shim now uses an EGL fence/client wait with glFlush and falls back to glFinish only if sync is unavailable; IOSC_NBUF=3 rotates on wl_buffer.release and scans all buffers before blocking so it no longer stalls on an arbitrary `cur+1` buffer while another buffer is free. Original finding: Client-side glFinish per swap in the EGL shim.
- iosc_egl_shim.c header (line ~16): eglSwapBuffers = "glFinish, hand pbuf[cur]'s IOSurface to iosc". Full client GPU sync every frame for every GPU client. Fix: fence/sync object + buffer-release-driven rotation (IOSC_NBUF is already 3). Effort: small-medium. Matters more once P0.1 makes GPU clients the norm.

P0.7 ✅ DONE 2026-07-02 — Xwayland glamor IOSurface damage now uses a per-frame EGL fence when `EGL_KHR_fence_sync` is available, falling back to `glFinish()` only when sync support is missing. Original finding: Xwayland's IOSurface glamor backend drained the whole GPU pipeline on every damage post.

=== P1 — Shortcuts/stopgaps that risk correctness or block features ===

P1.1 ✅ DONE before 2026-07-02 — iosc now consumes the shared xios_input_socket reader; the old inline framing path is gone from the hot input socket. Original finding: Input-reader duplication: iosc.c's inline reader (in_client_readable etc., ~iosc.c:4440-4520) vs the extracted copy xios_input_socket.c ("Extracted from iosc.c's inline reader... so iosc and MetaBackendIOS share one framing implementation", xios_input_socket.c:1-10). iosc still uses its inline copy — two framing state machines that can drift. Planned unification (iosc links libxios_glue) is explicitly "post-validation". Owner: iosc track.

P1.2 ✅ DONE 2026-07-02 — xios-glue-stub.h contract-drift risk now has a build-backend-check.sh signature check against the canonical xios_input_socket.h/xios_egl.h surface; the stub was also updated with the missing XIOS_IN_OUTPUT/HAPTIC/VOLUME/APPEARANCE registry entries. Original finding: MetaBackendIOS compiles against the frozen local xios-glue-stub.h while the real libxios_glue ships its own canonical headers; build-xios-glue.sh:86 deliberately does NOT bundle the stub "it can drift". No automated check that stub == shipped headers. Fix: a signature-diff check in build-backend-check.sh. Owner: mutter track.

P1.3 ◐ PARTIAL before 2026-07-02 — MetaBackendIOS now compiles/returns a real default "us" xkb_keymap and MetaSeatIOS exposes a ClutterKeymap. REMAINING: update_stage and MetaInputSettings fills. Original finding: MetaBackendIOS device-iteration TODOs (meta-backend-ios.c:15 "the ones marked TODO are device-iteration fills"): get_keymap returns NULL (iosc_input's compiled "us" keymap not exposed through libxios_glue — meta-backend-ios.c:143; xkb-dependent shell paths may misbehave), update_stage is a no-op (line 163), MetaInputSettings NULL (line 113). Could surface as gnome-shell bring-up blockers. Owner: mutter track.

P1.4 Mutter open risks (docs/mutter-on-iosc.md:291-313): Cogl-on-ANGLE FBO-0 completeness not yet proven THROUGH COGL (smoke test staged, iosc-cogl-smoke); EGLImage-vs-pbuffer IOSurface import bridge (doc line ~540: needs EGL_ANGLE_metal_texture_client_buffer verification, else pbuffer fallback inside libxios_glue); login1-stub answering exactly what gsd calls; gsd D-Bus service breadth. Task #5 (weak-link dead X11/xcb in libmutter) is in flight — the memory-noted guard-if-hit dead code.

P1.5 ✅ DONE 2026-07-02 — xdg-activation tokens now store serial/seat/surface/app_id and commit records retain app_id for later policy/debug hooks. Original finding: xdg-activation token set_app_id is a silent no-op (iosc.c:1788-1790) — tokens don't carry app_id, so activation policy can't ever key on it. Minor today (single-user), one-liner to store.

P1.6 ioscd.sock is world-connectable with a root daemon behind it (documented as acceptable-for-now, iosc-desktop-env.md §8: "can be tightened to a mobile-group socket later"). ioscd only execs fixed binaries, so bounded — but it is a root launch service; tighten when packaging.

P1.7 ✅ DONE 2026-07-02 — iosc's shared input socket now flushes Wayland clients once per drained socket batch instead of after every record, and the per-key stderr trace is behind `IOSC_DEBUG`. Original finding: motion/touch/text bursts paid repeated flush syscalls and every key emitted unconditional stderr.

=== P2 — Deferred followups / cleanups ===

P2.1 iosc.c megafile refactor is QUEUED and the file keeps growing: it's now 7153 lines (plus XScreen.swift 2735); refactor-plan.md is updated to match. Plan's precondition list (panel + input-unification landed, blend fix validated, freeze announced) — input-unification (P1.1) is now done, so the refactor gate is closer. XScreen.swift split is low-contention and can go first per the plan.

P2.2 Post-ICU re-enables (ICU build is task #3, in progress): (a) validate the EDS/calendar-server gnome-shell flavor now carried in `ports/gnome-shell/patches-eds`; the default `ports/gnome-shell/patches` stack still degrades JS side to an empty calendar; (b) rebuild tracker with ICU — tracker.mk:52-58 forces unistring ("only cost is no ICU-quality locale collation").

P2.3 Audio: only the libpulse-simple shim exists; full PulseAudio (or a native-protocol sink) is "still future work for the broadest desktop layer" and mic capture is explicitly deferred (docs/audio-plan.md:105-121).

P2.4 Packaging gaps: the Path-B Xios DDX/IOSurface display path is "functional and verified on-device, but not yet packaged as a .deb" (docs/USER-GUIDE.md:119); layer-shell panel and misc dev binaries live in wayland/out only.

P2.5 Nautilus ecosystem holes: no gvfs (Trash/Network empty), tracker-sparql built but no tracker-miners indexer (search inert), "heavy leaves trimmed" per docs/gnome-apps.md:165-169. GTK3 track wholly deferred (gnome-terminal optional-later, gnome-apps.md:170).

P2.6 ✅ DONE 2026-07-02 — iosc-desktop-env.md now documents the landed app_id raise socket and `ngl` GTK default; refactor-plan.md line counts/gates were refreshed. Original finding: iosc-desktop-env.md §7 still says iosc "cannot" raise by app_id and requests the feature — it HAS landed (wm control socket + wm_find_toplevel_by_app_id, iosc.c:4898-4940, socket up at iosc.c:5705). refactor-plan.md line counts stale (P2.1). Worth a doc pass so future agents don't re-implement.

P2.7 Uncommitted WIP in the working tree: apps/iosc-shell (build-panel.sh, iosc-shell.c, shell-draw.h), linux-build/recipes/startup-notification.mk, and rebuilt wayland/out binaries. NOTE (2026-07-02): the "PARKED per the distribution-chooser pivot" framing is now stale — the iosc-shell track has active, committed development (e.g. 1ee9ed9 configurable desktop widgets, b4819cd redraw hot-path optimization, 906f36d dock gestures, 4a99f44 bar/dock surface split), and iosc-shell.c + panel-layout.h are again modified in the working tree. Treat this as an active track, not a parked one; the residual action is still to commit-or-drop the loose working-tree changes so it isn't half-staged.

P2.8 ✅ DONE before 2026-07-02 — kgx launchers use `kgx -T iosc-kgx -- /var/jb/usr/bin/bash -i`; the stale `-e <cmd>` memory note was incorrect for the current scripts. Original finding: kgx quirk: needs `-e <cmd>` to launch (memory note) — root-cause the default-shell spawn rather than carrying the workaround into launcher .desktop files.

=== P3 — Degraded-but-acceptable (record so we don't forget) ===

- libgtop stub (recipes/libgtop_stub.c): kgx process enumeration returns empty — loses child-process window styling + "command running" close warning only. Could later be a real libproc-based backend (jailbroken, so sysctl/libproc may actually work).
- libei/libeis links-only shim (recipes/libei.mk:5-12): input capture / remote-desktop input NON-FUNCTIONAL by design, inert feature. Same pattern as stubbed libdrm.
- xios-login1-stub (wayland/xios-login1-stub.c): answers the logind calls gnome-session/gsd make; no real session/power management — intended.
- CPU fallback composite mode (iosc.c:984-994, activated at 5622 "GPU compositor unavailable"): top surface only, no stacking — fine as a fallback, never the product path.
- X11 flavor stays software for now (Xvfb/llvmpipe outside the app display path) — explicitly lowest priority per the distribution-chooser; ANGLE-accel (glamor or Xwayland-on-iosc) possible later.
- split-shell cairo/pango CPU renderer — adequate for bar/dock chrome; renderer may be reused for native-mode window chrome.
- gedit skipped in favor of gnome-text-editor (libpeas-2 typelib chain, gnome-apps.md:175-182).
- gnome-shell JS is interpreter-only (JIT-less mozjs) — animations may be sluggish on the A10; compositing stays GPU (mutter-on-iosc.md risk #5). Inherent, not fixable by us.
- ios-inputd degrades gracefully when input-method-v2/virtual-keyboard-v1 absent (ios-inputd.c:293-305) — both protocols are advertised by iosc, so messages are belt-and-braces.

Suggested dispatch order: P0.3 (hours, pure win) → P0.2 → P0.1 (the big one, needs on-device GSK-on-ANGLE validation) → P0.4 → P1.1 → P0.5/P0.6, with P1.3/P1.4 owned by the mutter track in parallel and P2.2 gated on ICU landing.
