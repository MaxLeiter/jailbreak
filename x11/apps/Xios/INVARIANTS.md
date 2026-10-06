# Xios app invariants

Every non-obvious behavior the app must keep, collected 2026-10-06 from the handoff docs, code
comments and fix commits, for the v2 rewrite (`x11/docs/xios-v2-design.md`). Line references
are to the pre-rewrite `Sources/XScreen.swift` (XS) unless another file is named. Each item in
the rewrite needs a test, a code comment at the place that enforces it, or a device check.

## Present and frame ownership

1. Ack `presentedTime` only from `drawable.addPresentedHandler`, with no second ack path. iosc's 100 ms present-ack valve is the net; a fallback races it and loses the measurement. An ack with presentedTime==0 still acks, without a timestamp. (XS:1541-1569)
2. Send ages as deltas (`CACurrentMediaTime()-at`), never timestamps; pacing as `targetTimestamp - now`. The two sides use different clocks. (XS:1397-1417, 1564)
3. Send PACING at the top of every tick, before the drain. (XS:1253)
4. Set frame rate only through one `setPacingRange` seam with `CAFrameRateRange`, never `preferredFramesPerSecond`. The thermal track clamps that seam. (XS:203-216, 482)
5. Stream-v2 DIRTY is an ownership transfer: consume exactly one frame per drain, never coalesce. (XSurface.c:451-455)
6. On accepting the next DIRTY, release the previously held allocation: empty command buffer on the same queue, `encodeSignalEvent(release, seq)`, commit, then `xsurface_released`. No CPU wait. Keep the current frame held for idle redraw and zoom. (XS:1288-1299, 662-680)
7. While a frame's fence import is outstanding: no drain, no RELEASE, no unfenced sample. (XS:1285, 1318)
8. Never sample before the first DIRTY (seq==0). (XS:1307-1314)
9. A missing or invalid fence on a frame means teardown(lost), never an unfenced present. (XS:1319-1323)
10. A failed release-fence import fails the adopt. A legacy connection with no token is OK (mutter/Xorg fixed one-surface producers). (XS:643-659)
11. Broker imports run off main with a 2 s timeout; results for superseded tokens are dropped; the release event is cached across reconnects by token.
12. The broker return is `NS_RETURNS_RETAINED`, otherwise every import leaks an event.
13. SURFACE_DROP of the displayed surface is retired and freed only after a later DIRTY switches away. (XSurface.c:533-546)
14. FLIP_Y swaps V only. Framebuffer and input geometry stay the compositor output, not the client surface dimensions. (XS:1501-1507)
15. Geometry source of truth is the IOSurface. A post-connect HELLO with different geometry means -1 and a full re-adopt. (XSurface.c:281-290)
16. Re-sync surface geometry after every drain so Swift's fb dims never go stale. (XS:1301)
17. `resetZoom` on every adopt and geometry change (a stale zoom caused overflow plus offset taps). (XS:615-621)
18. Shaders force alpha to 1. (Shaders.metal:16-18)
19. MetalFX: default off; `auto` declines at the shipping geometry by design; gate on `supportsDevice` at runtime with a weak link; relax `framebufferOnly` only while on; `syncUpscaler` idempotent, run after Metal exists and on every foreground; the upscale hint must not trigger a re-adopt.

## Lifecycle, memory, jetsam

20. On drain EOF, release the IOSurface and texture promptly and drop to the holding frame; do not reconnect to the dead socket. This is what avoids flavor-switch jetsam. (XS:1202-1248)
21. The holding frame is a 1x1 black texture, not full size (~50 MB saved).
22. While backgrounded: pause the display link, bump the load generation, release input, surface, fences, texture and upscaler. On foreground, reload and reconnect.
23. `MTLCreateSystemDefaultDevice()` returns nil when backgrounded; retry start on active. (XS:373-377)
24. Connect retries bail on a generation change or background. (XS:516-528)
25. FrontBoard gives the app no environment. Production knobs come from config files only; env vars are debug-only.
26. SO_NOSIGPIPE on every socket. PACING to a dead compositor otherwise kills the app.
27. All ioscd I/O off main with bounded timeouts. SESSION replies are read up to the first newline.
28. A presented session whose config or DDX socket is gone for 3 consecutive checks is treated as gone (was the dead-pin fix; in v2 the registry owns this).
29. `iosc_status_set_producer("Xios")` resolves eagerly and unlinks the predecessor's sidecar, because the app is killed rather than exiting.
30. Status sidecar writes use O_EXCL|O_NOFOLLOW.
31. Never `CGContext(data:)` over Swift storage. Copy cursor pixels before the next drain; they belong to the connection. (XSurface.h:95-102)

## Input

32. Wire coordinates are absolute framebuffer (output) pixels; iosc divides by scale once. Verified, do not re-chase.
33. AXIS: 1/256 fb-px fixed point, wl_pointer sign, keep the sub-unit remainder, axis_stop at lift, never synthesize momentum (clients fling). Source 0 finger/continuous, 1 wheel. (XS:2493-2519)
34. Trackpad pinch/rotate become one pointer gesture: first recognizer to start opens it, last to end closes it; scale and rotation absolute since begin. Finger pinch stays app zoom (1...6). (XS:2603-2717)
35. Indirect pointer: the touch phase is authoritative, `buttonMask` only refines it. Hover with buttons held and no touch self-heals with a release. (XS:2571-2584)
36. With a mouse attached, hide our cursor overlay and dress the system pointer via UIPointerInteraction. Shape 0 = hidden. Invalidate only on a category flip. Our overlay draws only on mutter or when a client cursor image exists. (XS:698-724, 856-930)
37. KDE desktop preset: one direct finger goes through the pointer lane and the parallel wl_touch is suppressed. kde-mobile and explicit touch_replaces_pointer keep wl_touch. Pencil and indirect input unchanged. (XS:1823-1851, 2915-2923) Known bug to fix in v2: the second finger flips the lane mid-gesture so the first finger's moves/up go to wl_touch with no down.
38. Finger press is deferred: commits on 12 pt movement or lift; a 0.55 s still hold is right click plus haptic. (XS:141-142, 2932-2940, 3038-3050)
39. 3+ fingers cancel all wl_touch and suppress until all lift. Two fingers cancel the pending press. (XS:2898-2914)
40. Touch slots are stable 0..9; always send up/cancel, even off-framebuffer. (XS:2820-2871)
41. Pencil sends coalesced touches (240 Hz) with force, tilt, azimuth. No file I/O on the motion path.
42. Reset input latches on every drop, reopen or close: keys, trackpad buttons, emulated left press, pending press, touch slots. Releases go out only if the outgoing connection is still open.
43. Hardware keyboard: release ordinary keys before modifiers on disconnect, resign-active and keyboard disconnect; suppress a UIKit echo within 120 ms of a GC transition; Command = Super. (apps/shared/XiosHardwareKeyboard.swift)
44. Input queues under backpressure (64 KiB) instead of disconnecting. TEXT is cut on code point boundaries into 4096-byte records. Poll traits every tick to flush.
45. Return and Tab from the OSK go as KEY taps, not TEXT.
46. OSK policy: the auto hook runs on every TRAITS record before the change guard; a keyboard the user opened or dismissed stays user-owned; 200 ms debounced hide covers focus hops; secure entry when hidden, sensitive, or purpose 8/9. (osk-plan.md:75-95)
47. Never infer input or clipboard sockets from a global default; a missing endpoint is a reported config error. (XS:1143-1159)

## Clipboard

48. Connect off main, adopt on main, epoch-guarded. After connect wait ~30 ticks: the desktop wins if it replays, otherwise push iOS. An empty pasteboard on connect does not clear the desktop.
49. Image encode and writes on a serial clipboard queue with a dup'd fd; echo guards live on that queue; a failed write shuts the socket and main reconnects.
50. A single http(s) URI becomes `public.url`; file:// goes as text only.

## SysInt

51. Hop volume KVO to main; the C links are unsynchronized.
52. Keep only the newest volume request, with bounded retry.
53. Drain brightness and volume every tick (shared one-slot stash).
54. Brightness goes through `UIScreen.brightness` in the app (BKS is inert outside SpringBoard).
55. OUTPUT: force a resend after every adopt and layout; 0,0 means iosc swaps; both landscapes are transform 0. Known bug to fix in v2: iosc drops app clients on OUTPUT and the app treats it as lost, ~1.5 s black per rotation.
56. Audio session stays `.ambient` + `.mixWithOthers` so PulseAudio playback is never interrupted.

## ioscd contract

57. ioscd honors destructive SESSION only from root or a peer whose path is `*/Xios.app/Xios` (or comm `Xios`). Keep the bundle and executable name. Slots and `app` are non-destructive. `app` sends a desktop-file id, never Exec text.
58. Unqualified `stop` stops everything. Slot stops must carry the slot.
59. `A11Y_STATE` on VoiceOver changes. The a11y reader treats EAGAIN as idle, not EOF; the socket is generation-owned.

## Packaging and environment

60. `UIApplicationSupportsIndirectInputEvents=YES`.
61. Narrow entitlements: get-task-allow (compositor uses task_for_pid for the Mach rendezvous), IOKit GPU user clients, broker mach-lookup, tmp read-write.
62. Ships as the com.max.xios deb; bump MARKETING_VERSION every release.
63. Test with a home-screen tap, not `uiopen` (FrontBoard relaunch throttle).
64. Trust xios-status.txt, not xios-debug.txt (on-demand only).
