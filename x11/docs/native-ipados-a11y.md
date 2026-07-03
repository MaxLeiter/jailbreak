# Native-flavor accessibility: per-app hosts publishing UIAccessibility trees

Status: spec ACKED + host-side prototype (compile-clean) + helper-side bound
snapshot support with unchanged-publish suppression and first action routing +
forced native-host smoke. This is the native-iPadOS half of
`a11y-plan.md`, which owns the bridge design and the helper (`xios-a11yd`).
Every addition below is folded into a11y-plan.md's authoritative wire schema;
this doc explains the native rationale. Host-side code lives in
`apps/iosc-host/Sources/HostA11y.swift`.

## Why native is the showcase

`a11y-plan.md` ("Per-flavor notes") already calls it: each Linux app runs in its
own UIKit host, so its elements live in a real per-app accessibility context.
Concretely, relative to the desktop flavors:

- No compositor geometry feed: AT-SPI window-relative extents (coord_type=1) are
  the final coordinates. The canvas IS the window; origin is (0,0).
- No app correlation heuristics on the publish side: a host binds to exactly one
  app_id, and ioscd knows which PID it spawned for it (see Correlation).
- VoiceOver's app switcher, per-app rotor settings, and focus restoration work
  natively because each Linux app IS an iPadOS app.
- Element counts stay small (one app's windows, not a desktop).
- Reverse input is local: the host already injects keyboard/touch for its window
  (IoscInput), so synthetic tap / Esc need no round trip through the helper.

## Topology

```
 Linux app (GTK4/Qt) -- private a11y bus -- xios-a11yd (one per session)
                                                |  N concurrent connections
                              +-----------------+------------------+
                              |                                    |
                    IOSCHost "kgx"                        IOSCHost "gedit"
                    (binds app_id, publishes                 (same, its own
                     its windows' subtrees                    scenes)
                     on its HostScreenViews)
```

Delta for the helper: native needs N concurrent connections, each carrying its
own filter, `enable` state, and generation counter. Everything else (mirror,
event subscriptions, debounce, publication filters) is shared machinery.

## Connection contract

1. Host connects to `/var/jb/tmp/xios-a11y.sock` (one listener serves the Xios
   client and all native hosts, owned `mobile:mobile` and mode 0660, fixed path
   — never derive from `$XDG_RUNTIME_DIR`, which ioscd points at per-app private
   bus dirs, ioscd.c:255).
2. Host sends `bind{appid,exec}` immediately after connect.
   An unbound connection = desktop semantics (Xios app, unchanged). bind is a
   persistent filter: on cold launch the helper holds it and starts publishing
   when the app's Socket.Embed arrives; on app exit it sends `reset` and
   re-publishes on relaunch. `exec` is optional in the schema but shipped by
   `HostA11yClient` because AT-SPI often reports executable names (`kgx`) rather
   than freedesktop app ids (`org.gnome.Console`).
3. Host sends `enable{true}` only while `UIAccessibility.isVoiceOverRunning`;
   on VoiceOver off it sends `enable{false}` and the helper drops the mirror
   work for this connection. Whole pipeline is quiescent without VoiceOver.
   Smoke tests can create `/var/jb/tmp/xios-a11y-force` before launching a native
   host; HostA11y treats that as an enable gate and ioscd enables the Linux-side
   AT-SPI launch prefix for the app.
4. Helper publishes, for the bound app only: `window` entries for its toplevels
   and `upsert`/`remove`/`focus`/`announce` for their subtrees. Frames are
   window-relative pixels, untranslated.

## Correlation (deterministic, two hops)

Binding `appid` to an AT-SPI application:

- Shipped first pass: helper matches the bound connection against AT-SPI
  application name/title using `appid`, `exec`, and their basenames. On-device
  smoke verified `bind{appid:"org.gnome.Console",exec:"kgx"}` publishes kgx and a
  non-matching bind publishes no windows.
- Intended hardening: ioscd spawned the Linux process for that appid
  (`ioscd_send_launch`), so it knows (appid, pid). ioscd streams spawn/exit
  records to xios-a11yd (it also starts the helper, so a pipe or the runtime-dir
  socket both work): `spawn{appid,pid}` / `exit{appid,pid}`.
- The helper resolves each registered AT-SPI application's connection to a PID
  via `org.freedesktop.DBus.GetConnectionUnixProcessID` on the a11y bus, and
  joins on PID. No /proc, no name heuristics, no title matching.
- Fallback (helper restart raced a spawn, or app spawned outside ioscd): match
  AT-SPI application name against the appid's exec basename, newest first. Same
  weak joint as the desktop flavors, but only reachable in the race window.

Matching an AT-SPI toplevel to a UIWindowScene (within the one app) is HOST-side:
match `window{title,frame}` against the scenes' titles and canvas sizes, tie-break
by creation order (WINDOW_NEW order and window:create order come from the same
map event). Single-window apps — the overwhelming case — are exact. A mismatch
in a multi-window app puts elements on the sibling scene of the same app and
self-corrects on the next title change; it cannot cross apps.

## Publication policy delta

Desktop flavors publish only the focused toplevel's subtree. A native host may
have TWO of its scenes on screen at once (iPadOS Split View of the same app), so
the helper publishes subtrees for ALL mapped toplevels of the bound app, and the
per-window caps from `a11y-plan.md` (SHOWING+VISIBLE gate, layout-container
filter, ~200 element soft cap, 50 ms debounce) apply per window. The host tells
the helper which windows are actually attached to scenes via `attach{win}` /
`detach{win}`. Hosts send them unconditionally from P1; the
helper may ignore them until it implements traffic muting (P4).

## Coordinates in the host

Chain per element (all in `HostA11y.swift`):

1. `upsert.frame` = window-relative px = canvas px (identical in native mode).
2. Canvas px -> view points via the inverse of `HostScreenView.canvasPoint`'s
   aspect-fit rect (identity at steady state; letterboxed only mid-resize).
3. `UIAccessibilityConvertFrameToScreenCoordinates(rect, view)`.

Applied lazily in the `accessibilityFrame` getter, so rotation/Split View drags
need no re-push (same trick as the Xios spec).

## Interaction routing

| VoiceOver gesture | route |
|---|---|
| double-tap (activate) | `activate{id}` -> helper: `Action.DoAction(0)` |
| custom action | `action{id,idx}` -> helper |
| adjustable inc/dec | `adjust{id,dir}` -> helper writes `Value.CurrentValue` |
| helper fallback `tap{win,x,y}` | LOCAL: `iosc_input_motion`+`button` on the window's own input connection (no compositor round trip; `win` is present on bound connections) |
| 2-finger Z (escape) | LOCAL: Esc keysym via the scene's IoscInput connection |
| scroll gestures | `scroll{id,dir}` -> helper (v1); LOCAL wheel synth is a P4 option |
| text entry | existing tap+type path; activate focuses the field, iOS keyboard types |

Focus sync, announcements, and modality are exactly the Xios spec: `focus` ->
`.layoutChanged`, `announce` -> `.announcement`, MODAL -> a container element
with `accessibilityViewIsModal` (scoped to that scene's view only).

## Host implementation (prototype, this repo)

`HostA11y.swift`, one `HostA11yClient` per host process (mirrors NativeManager's
shape: background reader thread, main-actor apply):

- Socket client: connect/retry, `bind` + `enable` handshake, NDJSON lines out,
  line-buffered JSON decode in. Gated by `voiceOverStatusDidChangeNotification`;
  when VoiceOver is off the socket is closed. Inert if the helper socket does
  not exist (silent retry with backoff) — safe to ship ahead of xios-a11yd.
  `/var/jb/tmp/xios-a11y-force` is a smoke-only override, and
  `/var/jb/tmp/iosc-a11y-host.log` records connect/bind/window/publish events.
- `HostA11yWindowStore`: nodes keyed by helper id, (parent, idx) tree, pre-order
  flatten on each applied batch, published as the bound view's
  `accessibilityElements`.
- `HostA11yElement: UIAccessibilityElement`: canvas-px rect + role/label/value/
  hint/traits/custom-actions; overrides activate/increment/decrement/escape/
  scroll per the table above.
- `HostScreenView` glue: `viewRect(fromCanvas:)` inverse transform,
  `a11yEscape()`, `a11ySynthTap(x:y:)`, store attach/detach on scene bind and
  teardown.
- Trait/role mapping tables are the host-side end of `a11y-plan.md`'s role map
  (helper sends resolved traits[] strings; host maps to UIAccessibilityTraits —
  iOS 16 floor, so checked state rides accessibilityValue, no .toggleButton).

The decoder conforms to the current schema: `t` discriminator, `parent:0` = window
root, `remove{id}` takes the whole subtree, `frame` as `[x,y,w,h]` ints, the
locked thirteen-string traits vocabulary (twelve trait bits + `modal`, which
maps to the `accessibilityViewIsModal` property), and unconditional
attach/detach.

## Protocol additions

| addition | direction | why |
|---|---|---|
| `bind{appid,exec?}` | app->helper | scope a connection to one AT-SPI app; `exec` covers app-id/name mismatches |
| multi-connection + per-conn bind/enable/generation | helper | N hosts |
| publish all toplevels of bound app (not focused-only) | helper | same-app Split View |
| `attach{win}` / `detach{win}` | app->helper | mute unscened windows |
| `tap{win,x,y}` window field | helper->app | native taps are window-relative |
| ioscd->helper `spawn{appid,pid}` feed + GetConnectionUnixProcessID join | ioscd+helper | deterministic app correlation |

Nothing in v1 changes shape for the Xios client; every addition is a new message
or a new field with a safe default.

## Phasing (hooks into a11y-plan.md phases)

- P1 (read-only browse): a11y-plan.md now ENDORSES the native host as the first
  P1 publisher. Helper-side `bind` + multi-connection exists, and
  `HostA11yClient` now sends both app id and exec. On-device forced smoke on
  2026-07-03: generated/deployed a native Console bundle, created
  `/var/jb/tmp/xios-a11y-force`, launched it, and saw HostA11y connect to
  `/var/jb/tmp/xios-a11y.sock`, bind `org.gnome.Console`/`kgx`, attach scene 3,
  and publish 12 elements onto the host view. A follow-up `xios-a11y-tools_0.2.4`
  smoke kept the same counts after an idle wait, confirming unchanged snapshot
  republishes are suppressed. `xios-a11y-tools_0.2.6` also routes the existing
  HostA11y `activate` and custom `action` messages back to AT-SPI Action.DoAction
  for currently published node ids, with a synthetic-tap fallback for activation
  when no AT-SPI action is available. On-device direct socket probe saw kgx node
  `1003` expose `actions:["overview.open"]`. A fresh native Calculator smoke
  connected and published 18 elements, but the tree still lacked useful labels
  and was mostly `panel`/`grouping`, so it does not close the full-widget GTK
  acceptance gate. `xios-a11y-tools_0.2.7` also routes HostA11y adjustable
  increment/decrement messages to AT-SPI Value.SetCurrentValue and publishes
  value text/current values in snapshots; the stable Console smoke had no
  value-bearing nodes, so this still needs a slider/spinbutton target. Real
  VoiceOver gesture validation is still pending. `atspi-dump` in
  `xios-a11y-tools_0.2.8` now prints actions and value ranges so future native
  smokes can identify suitable control targets quickly; the first `0.2.8` dump
  printed kgx frame/window actions and panel `overview.open`. `0.2.9` hardens
  the helper client parser to line-buffered NDJSON, so native hosts and test
  clients can split or batch commands without relying on socket read boundaries;
  split-write device smoke across `bind`/`enable` still published kgx. `0.2.10`
  also dispatches helper commands by exact `t` type instead of substring matches.
  `0.2.11` adds polling-based state mirroring: upserts include state-derived
  traits/values and snapshots append `focus` when AT-SPI exposes a focused node.
  `0.2.12` makes `atspi-dump` print high-signal states alongside actions/values.
  `0.2.13` registers common AT-SPI object/window/document event families and
  coalesces them into snapshots while keeping a periodic fallback.
  The spawn feed hardens correlation in P2. It supplements, not replaces, the
  desktop P1 acceptance.
  Gates: the Linux-side P0 items (at-spi-bus-launcher in session, GTK_A11Y=none
  gate removed from ioscd, IsEnabled property write, atspi-dump smoke test)
  gate this path exactly as they gate the desktop one. Accept: VoiceOver swipes
  through gnome-console (kgx) running in its own host scene. Use a GTK4 app for
  acceptance — GTK3 apps stay dark until the gtk3 atk-bridge rebuild.
- P2 (interaction): activate/adjust/custom actions + the spawn feed.
- P4: attach/detach traffic muting, local wheel synth, same-app Split View test,
  popup (xdg_popup) extents once the desktop flavors solve them.

## Resolved questions (answered by the a11y owner, 2026-07-01)

1. Schema: published as the authoritative wire schema in a11y-plan.md; the host
   decoder is conformant.
2. Socket: ONE listener for desktop + native, `/var/jb/tmp/xios-a11y.sock`.
3. bind race: filter is persistent through cold launch; publishing starts on
   Socket.Embed; reset on app exit, re-publish on relaunch.
4. attach/detach: wire messages from day one (hosts send unconditionally);
   helper behavior (traffic muting) lands in P4.

## Residual gap — RESOLVED (a11y owner, 2c4f90a)

Modal dialogs: the traits vocabulary is thirteen strings; the thirteenth is
`modal`, carried on the dialog's container element. The
vocabulary is ours, not literal UIAccessibilityTraits — `modal` maps to the
`accessibilityViewIsModal` property, not a trait bit, which is exactly what
the host's upsert path already does. No host changes were needed.
