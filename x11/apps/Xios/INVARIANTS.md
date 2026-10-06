# Xios app invariants

Every non-obvious behavior the app must keep, collected 2026-10-06 from the handoff docs, code
comments and fix commits, for the v2 rewrite (`x11/docs/xios-v2-design.md`). Each item says
where the v2 code enforces it (paths are under `Sources/`, `file:line` as of the M1 commit; the
symbol name is the stable anchor). `[T]` = covered by `Tests/run.sh` (host-side, no device).
`[D]` = needs the on-device check listed in `x11/docs/handoff/xios-app.md` before v2 ships.
The pre-rewrite references (`XS:` = the old `XScreen.swift`) are gone with that file.

## Present and frame ownership

1. Ack `presentedTime` only from `drawable.addPresentedHandler`, with no second ack path. iosc's 100 ms present-ack valve is the net; a fallback races it and loses the measurement. An ack with presentedTime==0 still acks, without a timestamp. Enforced: `Present/Renderer.swift:118` (`render`, the only `addPresentedHandler`), ack in `Session/SurfaceLink.swift:244` (`present`'s `onPresented`).
2. Send ages as deltas (`CACurrentMediaTime()-at`), never timestamps; pacing as `targetTimestamp - now`. The two sides use different clocks. Enforced: `Session/SurfaceLink.swift:244` (age), `Session/SessionConnection.swift:376` (`sendPacing`).
3. Send PACING at the top of every tick, before the drain. Enforced: `Session/SessionConnection.swift:359` (`tick` sends it first), called before the drain in `Present/PresentView.swift:157` (`tick`).
4. Set frame rate only through one `setPacingRange` seam with `CAFrameRateRange`, never `preferredFramesPerSecond`. The thermal track clamps that seam. Enforced: `Present/FrameClock.swift:38` (`setRange`).
5. Stream-v2 DIRTY is an ownership transfer: consume exactly one frame per drain, never coalesce. Enforced: `Session/SurfaceLink.swift:203` (`pump` drains once, and not at all while a frame is pending); C side `C/XSurface.c` unchanged.
6. On accepting the next DIRTY, release the previously held allocation: empty command buffer on the same queue, `encodeSignalEvent(release, seq)`, commit, then `xsurface_released`. No CPU wait. Keep the current frame held for idle redraw and zoom. Enforced: `Session/SurfaceLink.swift:323` (`submitHeldRelease`), called from `pump` and `close`.
7. While a frame's fence import is outstanding: no drain, no RELEASE, no unfenced sample. Enforced: `Session/SurfaceLink.swift:233` (`present` returns `.notYet`) and `pump` skipping the drain while `pendingStreamFrame`.
8. Never sample before the first DIRTY (seq==0). Enforced: `Session/SurfaceLink.swift:229`.
9. A missing or invalid fence on a frame means teardown(lost), never an unfenced present. Enforced: `Session/SurfaceLink.swift:234` -> `SessionConnection.surfaceLost`.
10. A failed release-fence import fails the adopt. A legacy connection with no token is OK (mutter/Xorg fixed one-surface producers). Enforced: `Session/SurfaceLink.swift:73` (`importReleaseFence`) and `adopt`.
11. Broker imports run off main with a 2 s timeout; results for superseded tokens are dropped; the release event is cached across reconnects by token. Enforced: release import on the connect queue (`Session/SessionConnection.swift:195` `startConnect`), present import `Session/SurfaceLink.swift:297`, cache `releaseCache` in `SessionConnection`.
12. The broker return is `NS_RETURNS_RETAINED`, otherwise every import leaks an event. Enforced: `apps/shared/XiosMetalEventBroker.h` (unchanged, shared).
13. SURFACE_DROP of the displayed surface is retired and freed only after a later DIRTY switches away. Enforced: `C/XSurface.c` (unchanged). New in v2: the texture cache is pruned with `xsurface_surface_known` so a dropped surface is not pinned (`Session/SurfaceLink.swift:159`).
14. FLIP_Y swaps V only. Framebuffer and input geometry stay the compositor output, not the client surface dimensions. Enforced: `Present/FitTransform.swift:58` (`clipVertices(flipY:)`) [T]; geometry from `xsurface_width/height` in `SurfaceLink.syncGeometry`.
15. Geometry source of truth is the IOSurface. A post-connect HELLO with different geometry means -1 and a full re-adopt. Enforced: `C/XSurface.c` (unchanged) -> drain -1 -> `surfaceLost` reconnects.
16. Re-sync surface geometry after every drain so fb dims never go stale. Enforced: `Session/SurfaceLink.swift:130` (`syncGeometry`, called at the end of `pump`).
17. `resetZoom` on every adopt and geometry change. Enforced: `Present/PresentView.swift:429` (`presenterDidAdopt`) and the `onGeometryChange` closure passed to `pump` (`PresentView.swift:179`).
18. Shaders force alpha to 1. Enforced: `Present/Shaders.metal:18`.
19. MetalFX: default off; `auto` declines at the shipping geometry by design; gate on `supportsDevice` at runtime with a weak link; relax `framebufferOnly` only while on; `syncUpscaler` idempotent, run after Metal exists and on every foreground; the upscale hint must not trigger a re-adopt. Enforced: `Present/Renderer.swift:276` (`syncUpscaler`), `attach(layer:)`, `SessionManager.appDidBecomeActive`; `setCompositorUpscaleHint` never touches a connection; weak link in `project.yml`.

## Lifecycle, memory, jetsam

20. On drain EOF, release the IOSurface and texture promptly; do not hold the dead surface. This is what avoids flavor-switch jetsam. v2 change: it then reconnects at once (see 55) instead of waiting for a poll, resolving the endpoint fresh from the registry on every attempt, so it never sticks to a dead path. Enforced: `Session/SessionConnection.swift:284` (`surfaceLost`), `SurfaceLink.close` (`SurfaceLink.swift:353`) [D].
21. The holding frame is a black clear, not a full-size texture (~50 MB saved; v1 used a 1x1 texture). Enforced: `Present/Renderer.swift:139` (`presentBlack`); shown by `PresentView.tick` immediately on a switch and after 0.6 s on a lost stream.
22. While backgrounded: pause the display link, bump generations, release input, surface, fences, textures and upscaler. On foreground, reload and reconnect. Enforced: `Session/SessionManager.swift:175` (`appDidEnterBackground`: registry stopped, `detach`), `:182` (`appDidBecomeActive`), `Present/PresentView.setPresenting`.
23. `MTLCreateSystemDefaultDevice()` returns nil when backgrounded; retry on active. Enforced: `Present/Renderer.swift:26` (`make`), retried in `SessionManager.appDidBecomeActive`; `RootViewController.setBackgrounded` builds the desktop then.
24. Connect retries bail on a generation change or background. Enforced: `Session/SessionConnection.swift:224` (epoch checks in the connect job), epochs bumped by `detach`.
25. FrontBoard gives the app no environment. Production knobs come from config files only; env vars are debug-only. Enforced: `Core/Paths.swift`, `Renderer.resolveUpscaleMode` (`Renderer.swift:237`).
26. SO_NOSIGPIPE on every socket. Enforced: `Core/Socket.swift` (ioscd, a11y), `C/IoscInput.c`, `C/IoscClipboard.c`, `C/SysIntClient.c`, `C/XSurface.c`.
27. All ioscd I/O off main with bounded timeouts. SESSION replies are read up to the first newline. Enforced: `Core/IOSCDClient.swift` (serial queue, `stopAtNewline`), completion hops to main.
28. A presented session whose config or DDX socket is gone is treated as gone, not on one bad read. v2: the registry owns this. A running desktop whose display socket has been missing for 3 s is `killed`; a torn JSON read is retried and then ignored. Enforced: `Core/SessionRegistry.swift:185` (`applyKilledDetection`), `:98` (`readJSON`) [T].
29. `iosc_status_set_producer("Xios")` resolves eagerly and unlinks the predecessor's sidecar, because the app is killed rather than exiting. Enforced: `Diagnostics/StatusWriter.swift:29`, started first thing in `AppDelegate`.
30. Status sidecar writes use O_EXCL|O_NOFOLLOW. Enforced: `apps/shared/iosc_status.c` (unchanged).
31. Never `CGContext(data:)` over Swift storage. Copy cursor pixels before the next drain; they belong to the connection. Enforced: `Present/CursorPlane.swift:110` (`adoptClientImage` copies into `Data`).

## Input

32. Wire coordinates are absolute framebuffer (output) pixels; iosc divides by scale once. Verified, do not re-chase. Enforced: `Input/TouchRouter.swift` (`framebufferPoint` through `FitTransform`).
33. AXIS: 1/256 fb-px fixed point, wl_pointer sign, keep the sub-unit remainder, axis_stop at lift, never synthesize momentum (clients fling). Source 0 finger/continuous, 1 wheel. Enforced: `Input/Gestures.swift:302` (`sendScroll`, `sendScrollStop`), `:250` (`handleTwoFingerPan`).
34. Trackpad pinch/rotate become one pointer gesture: first recognizer to start opens it, last to end closes it; scale and rotation absolute since begin. Finger pinch stays app zoom (1...6). Enforced: `Input/Gestures.swift:154` (`trackpadGestureBegan/Ended`), `:173` (`sendTrackpadGesture`), `:203` (`handlePinch`).
35. Indirect pointer: the touch phase is authoritative, `buttonMask` only refines it. Hover with buttons held and no touch self-heals with a release. Enforced: `Input/TouchRouter.swift:346` (`hardwarePointerMask`), `:374` (`hoverMoved`).
36. With a mouse attached, hide our cursor overlay and dress the system pointer via UIPointerInteraction. Shape 0 = hidden. Invalidate only on a category flip. Our overlay draws only on mutter or when a client cursor image exists. Enforced: `Present/CursorPlane.swift:62` (`update`), `:218` (`noteShape`), `:246` (`systemPointerStyle`).
37. KDE desktop preset: one direct finger goes through the pointer lane and the parallel wl_touch is suppressed. kde-mobile and explicit touch_replaces_pointer keep wl_touch. Pencil and indirect input unchanged. FIXED in v2: the lane is decided once when a gesture starts and held until all fingers lift, so a second finger no longer flips it. Enforced: `Input/LaneTracker.swift:9` [T], `Input/TouchRouter.swift:105`, policy in `Present/PresentView.swift:336` (`touchReplacesPointer`) [D].
38. Finger press is deferred: commits on 12 pt movement or lift; a 0.55 s still hold is right click plus haptic. v2: long-press is ALWAYS right click, the iosc context menu is gone. Enforced: `Input/TouchRouter.swift:44` (`longPressSeconds`), `:299` (`fireLongPress`).
39. 3+ fingers cancel all wl_touch and suppress until all lift. Two fingers cancel the pending press. Enforced: `Input/TouchRouter.swift:219` (`beginAppGestureSuppression`), `Input/Gestures.swift` (`twoFingerBegan`).
40. Touch slots are stable 0..9; always send up/cancel, even off-framebuffer. Enforced: `Input/TouchRouter.swift:230` (`touchSlot`, `forward`).
41. Pencil sends coalesced touches (240 Hz) with force, tilt, azimuth. No file I/O on the motion path. Enforced: `Input/TouchRouter.swift` (`forward`); the committed-press log goes through `StatusWriter.touchLog` (background queue).
42. Reset input latches on every drop, reopen or close: keys, trackpad buttons, emulated left press, pending press, touch slots, plus (v2) an open scroll or trackpad gesture. Releases go out only if the outgoing connection is still open. Enforced: `Input/TouchRouter.swift:92` (`resetLatches`), `Input/Gestures.swift` (`resetLatches`), triggered by `Present/PresentView.swift:408` (`presenterWillRelease`) from `SessionConnection.detach`, `inputDropped` and input reopen; links are read through `SessionConnection.openInput` so a dead link is never written.
43. Hardware keyboard: release ordinary keys before modifiers on disconnect, resign-active and keyboard disconnect; suppress a UIKit echo within 120 ms of a GC transition; Command = Super. Enforced: `apps/shared/XiosHardwareKeyboard.swift` (unchanged), `releasePressedKeys` in `presenterWillRelease`, echo check in `Input/KeyboardInput.swift` (`insertText`).
44. Input queues under backpressure (64 KiB) instead of disconnecting. TEXT is cut on code point boundaries into 4096-byte records. Poll traits every tick to flush. Enforced: `C/IoscInput.c:23` (`OUTQ_MAX`), `:171` (TEXT split), `Session/SessionConnection.swift:391` (`serviceInput` every tick).
45. Return and Tab from the OSK go as KEY taps, not TEXT. Enforced: `Input/KeyboardInput.swift:203` (`sendTextWithKeyBreaks`).
46. OSK policy: the auto hook runs on every TRAITS record before the change guard; a keyboard the user opened or dismissed stays user-owned; 200 ms debounced hide covers focus hops; secure entry when hidden, sensitive, or purpose 8/9. Enforced: `Input/KeyboardInput.swift:68` (`updateAuto`), `:90` (`applyTraits`).
47. Never infer input or clipboard sockets from a global default; a missing endpoint is a reported config error. Enforced: `Core/Models.swift:65` (`SessionEndpoints.configurationError`), `Core/SessionParsing.swift` (only the helper sockets fall back to globals, and only when the session names none) [T].

## Clipboard

48. Connect off main, adopt on main, epoch-guarded. After connect wait ~30 ticks: the desktop wins if it replays, otherwise push iOS. An empty pasteboard on connect does not clear the desktop. Enforced: `Session/ClipboardLink.swift:97` (`connect`), `:45` (`service`), `:156` (`push`).
49. Image encode and writes on a serial clipboard queue with a dup'd fd; echo guards live on that queue; a failed write shuts the socket and main reconnects. Enforced: `Session/ClipboardLink.swift:202` (`write`).
50. A single http(s) URI becomes `public.url`; file:// goes as text only. Enforced: `Session/ClipboardLink.swift:119` (`commitReceived`).

## SysInt

51. The C links are unsynchronized. v2: every call on a SysInt handle (open, send, poll, close, lazy connect) runs on one serial queue, and the volume KVO hops to main before touching the link reference. Enforced: `Session/SysIntLink.swift` (all), `Integration/SystemIntegration.swift:73`.
52. Keep only the newest volume request, with bounded retry. Enforced: `Integration/SystemIntegration.swift:184`.
53. Drain brightness and volume every poll (shared one-slot stash). Enforced: `Session/SysIntLink.swift:67` (`poll`), `C/SysIntClient.c`.
54. Brightness goes through `UIScreen.brightness` in the app (BKS is inert outside SpringBoard). Enforced: `Integration/SystemIntegration.swift:220`.
55. OUTPUT: force a resend after every adopt and layout; 0,0 means iosc swaps; both landscapes are transform 0. FIXED in v2: iosc drops app clients on OUTPUT; the app now reconnects immediately on that EOF and shows the last frame (black only after 0.6 s) instead of black plus a poll wait. Enforced: `Present/PresentView.swift:109` (`layoutSubviews`), `:429` (`presenterDidAdopt`), `Integration/SystemIntegration.swift:143` (`syncOutputNow`), reconnect in `SessionConnection.surfaceLost` [D].
56. Audio session stays `.ambient` + `.mixWithOthers` so PulseAudio playback is never interrupted. Enforced: `Integration/SystemIntegration.swift:160`.

## ioscd contract

57. ioscd honors destructive SESSION only from root or a peer whose path is `*/Xios.app/Xios` (or comm `Xios`). Keep the bundle and executable name. Slots and `app` are non-destructive. `app` sends a desktop-file id, never Exec text. Enforced: `project.yml` (bundle id `com.max.xios`, product `Xios`), `Core/IOSCDProtocol.swift` (`isValidDesktopFileID`), `Session/SessionManager.swift:243` (`perform`) [T].
58. Unqualified `stop` stops everything. Slot stops must carry the slot. Enforced: `SessionInfo.ioscdSlot` (nil only for legacy Main), the "Stop All Desktops" wording and confirmation in `UI/LauncherViewController.swift` (`confirmStop`) [T].
59. `A11Y_STATE` on VoiceOver changes. The a11y reader treats EAGAIN as idle, not EOF; the socket is generation-owned. Enforced: `Integration/A11yBridge.swift:157` (`pump`), state sent through `IOSCDClient.sendA11yState`.

## Packaging and environment

60. `UIApplicationSupportsIndirectInputEvents=YES`. Enforced: `project.yml:63`.
61. Narrow entitlements: get-task-allow (compositor uses task_for_pid for the Mach rendezvous), IOKit GPU user clients, broker mach-lookup, tmp read-write. Enforced: `entitlements.plist` (unchanged).
62. Ships as the com.max.xios deb; bump MARKETING_VERSION every release. Enforced: `project.yml` (0.2.0; nothing at that name on Blob as of 2026-10-06).
63. Test with a home-screen tap, not `uiopen` (FrontBoard relaunch throttle). Process rule, in the device test plan.
64. Trust xios-status.txt, not xios-debug.txt (on-demand only). Enforced: `Diagnostics/StatusWriter.swift` (status is written on every change, debug only from Settings).
