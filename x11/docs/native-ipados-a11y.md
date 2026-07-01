# Native-flavor accessibility: per-app hosts publishing UIAccessibility trees

Status: spec + host-side prototype (compile-clean, inert until xios-a11yd exists).
This is the native-iPadOS half of `a11y-plan.md`, which owns the bridge design and
the helper (`xios-a11yd`). Everything here is ADDITIVE to that plan's protocol v1;
the additions are marked PROPOSED until the a11y owner acks them. Host-side code
lives in `apps/iosc-host/Sources/HostA11y.swift` (native-ipados owns it).

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

Delta for the helper: protocol v1 assumed ONE client (the Xios app). Native needs
N concurrent connections, each carrying its own filter, `enable` state, and
generation counter. Everything else (mirror, event subscriptions, debounce,
publication filters) is shared machinery.

## Connection contract

1. Host connects to the helper socket (same socket as the Xios client; the
   listener is in the ioscd runtime dir, mode 0600).
2. Host sends `bind{appid}` (PROPOSED, app->helper) immediately after connect.
   An unbound connection = desktop semantics (Xios app, unchanged).
3. Host sends `enable{true}` only while `UIAccessibility.isVoiceOverRunning`;
   on VoiceOver off it sends `enable{false}` and the helper drops the mirror
   work for this connection. Whole pipeline is quiescent without VoiceOver.
4. Helper publishes, for the bound app only: `window` entries for its toplevels
   and `upsert`/`remove`/`focus`/`announce` for their subtrees. Frames are
   window-relative pixels, untranslated.

## Correlation (deterministic, two hops)

Binding `appid` to an AT-SPI application:

- ioscd spawned the Linux process for that appid (`ioscd_send_launch`), so it
  knows (appid, pid). PROPOSED: ioscd streams spawn/exit records to xios-a11yd
  (it also starts the helper, so a pipe or the runtime-dir socket both work):
  `spawn{appid,pid}` / `exit{appid,pid}`.
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
`detach{win}` (PROPOSED, app->helper) so backgrounded-but-mapped windows do not
generate event traffic.

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
| helper fallback `tap{win,x,y}` | LOCAL: `iosc_input_motion`+`button` on the window's own input connection (no compositor round trip; `win` field is PROPOSED — desktop tap has no window) |
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

NDJSON field names follow protocol v1's message names with a `t` discriminator
(`{"t":"upsert",...}`). PROVISIONAL until the a11y owner publishes the schema;
the decoder is one small file to adjust.

## PROPOSED protocol additions (summary for the a11y owner)

| addition | direction | why |
|---|---|---|
| `bind{appid}` | app->helper | scope a connection to one AT-SPI app |
| multi-connection + per-conn enable/generation | helper | N hosts |
| publish all toplevels of bound app (not focused-only) | helper | same-app Split View |
| `attach{win}` / `detach{win}` | app->helper | mute unscened windows |
| `tap{win,x,y}` window field | helper->app | native taps are window-relative |
| ioscd->helper `spawn{appid,pid}` feed + GetConnectionUnixProcessID join | ioscd+helper | deterministic app correlation |

Nothing in v1 changes shape for the Xios client; every addition is a new message
or a new field with a safe default.

## Phasing (hooks into a11y-plan.md phases)

- P1 (read-only browse): the native host can be the FIRST publisher, not P4 —
  it needs only `bind` + multi-connection from the additions above (correlation
  can start on the name-match fallback; the spawn feed hardens it in P2).
  Accept: VoiceOver swipes through gnome-console running in its own host scene.
- P2 (interaction): activate/adjust/custom actions + the spawn feed.
- P4: attach/detach traffic muting, local wheel synth, same-app Split View test,
  popup (xdg_popup) extents once the desktop flavors solve them.

## Open questions for the a11y owner

1. NDJSON schema: field names + `t` discriminator — publish the authoritative
   schema (or a C header of struct-tags) so the host decoder locks down.
2. Socket path: one listener for both desktop and native clients, or a second
   socket? (Host assumes one, in the ioscd runtime dir; constant is provisional.)
3. `bind` race: if the host binds before the Linux app registers on the a11y
   bus (cold launch), helper should hold the filter and start publishing on
   registration — confirm that is the intended semantics.
4. Does the helper want scene visibility (`attach`/`detach`) in P1, or is
   all-toplevels traffic acceptable until P4?
