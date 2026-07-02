# Accessibility plan: iOS VoiceOver into the Linux desktop

Status: design (nothing built yet). Owner of the Xios app changes: team lead. This doc
specifies the bridge; sections marked SPEC describe Xios-side work without touching it.

## Goal

A blind or low-vision user turns on iOS VoiceOver and can navigate the Linux desktop
(GTK, Qt, GNOME Shell, iosc-shell) the same way they navigate any iPad app: swipe
through elements, hear labels and roles, double-tap to activate, use the rotor and
adjustable gestures. The desktop is currently one opaque Metal view with zero
accessible elements; VoiceOver sees nothing.

The primary design is an AT-SPI2 to UIAccessibility bridge. An in-desktop screen
reader (Orca) is a complement for the X11-legacy flavor, not the primary path
(section "Orca option").

## What exists today

- at-spi2-core 2.52 is built for iOS (task #1 dep chain). Since 2.46 this single
  package contains everything server-side: `at-spi-bus-launcher` (owns `org.a11y.Bus`
  on the session bus, spawns the private a11y bus), `at-spi2-registryd` (the registry),
  `libatspi` (the AT client library Orca uses), and `libatk-bridge` (GTK3/ATK adaptor).
- GTK4 has a native AT-SPI backend (no ATK). Qt 6 has its own AT-SPI bridge in QtGui.
  GNOME Shell exposes its whole St/Clutter chrome over AT-SPI (Cally).
- ioscd exports `GTK_A11Y=none` (`apps/iosc-desktop/src/ioscd.c:274`), which
  hard-disables the GTK4 backend. This was a startup-cost optimization; it must
  become conditional (P0 below).
- The Xios app already has the screen-point to output-px mapping (`framebufferPoint`
  and inverse, used by the cursor overlay). Element frames reuse it.
- Xios already synthesizes Wayland pointer input from touches (tap+type path). The
  bridge's "synthetic tap" fallback reuses that path; no new compositor input work.

Verified against the at-spi2-core 2.52 source we build (paths relative to its tree):

- Bus discovery: `atspi_get_a11y_bus()` checks `AT_SPI_BUS_ADDRESS` env, then the X11
  root-window property, then calls `org.a11y.Bus.GetAddress` on the session bus
  (`atspi/atspi-misc.c:1852`). No X11 needed on our stack.
- Bulk tree fetch: `org.a11y.atspi.Cache.GetItems` at `/org/a11y/atspi/cache` returns
  the whole app tree in one call: `a((so)(so)(so)iiassusau)` = accessible ref, app ref,
  parent ref, index-in-parent, child count, interfaces, name, role, description,
  states (`xml/Cache.xml`). GTK4 implements it (noted in the interface doc itself);
  Qt still emits the pre-2015 signature and libatspi handles both. `AddAccessible` /
  `RemoveAccessible` signals keep it current.
- Geometry: `org.a11y.atspi.Component.GetExtents(coord_type)` with 0=screen, 1=window,
  2=parent; also `GetAccessibleAtPoint` and `GrabFocus` (`xml/Component.xml`).
- Actions: `org.a11y.atspi.Action` `NActions`, `GetActions` (name, localized name,
  keybinding), `DoAction(index)`.
- Values: `org.a11y.atspi.Value` `CurrentValue` (readwrite), `MinimumValue`,
  `MaximumValue`, `MinimumIncrement`, `Text`.
- Events: D-Bus signals on `org.a11y.atspi.Event.Object` (`StateChanged`,
  `ChildrenChanged`, `PropertyChange`, `BoundsChanged`, `TextChanged`,
  `TextCaretMoved`, `Announcement`, `ActiveDescendantChanged`, ...) and
  `org.a11y.atspi.Event.Window` (`Activate`, `Deactivate`, `Create`, `Destroy`, ...).
  Client-side strings: `object:state-changed:focused`, `window:activate`, etc.
  ATs register interest via `Registry.RegisterEvent`; the registry broadcasts
  `EventListenerRegistered` so toolkits only emit what someone listens for.
- App registration: apps call `org.a11y.atspi.Socket.Embed` on the registry; the
  registry's desktop object's children are the running applications.
- Enable switches: the bus launcher exposes `org.a11y.Status` properties `IsEnabled`
  and `ScreenReaderEnabled`, both writable over D-Bus, backed by the
  `org.gnome.desktop.interface toolkit-accessibility` gsetting
  (`bus/at-spi-bus-launcher.c:92`).
- Input synthesis is dead in our build: `GenerateMouseEvent` / `GenerateKeyboardEvent`
  in registryd dispatch through a platform vtable that only the X11 backend fills in
  (`registryd/deviceeventcontroller.c:228`, `registryd/meson.build`). Built without
  X11, they are silent no-ops. Reverse input must go through `Action.DoAction` or our
  own compositor-side injection. (Upstream Orca on Wayland has the same gap.)
- Wayland coordinate hole: Wayland has no global coordinate space, so toolkits report
  screen-relative extents with the window at (0,0). Window-relative extents
  (coord_type=1) are the only trustworthy ones. The compositor must supply window
  origins. This is the same problem GNOME's Newton project exists to solve.

## Architecture

```
 GTK4 app      Qt app      GNOME Shell     iosc-shell panel
    |             |             |            (new: tiny AT-SPI impl)
    +------ private a11y bus (unix socket, per session) ------+
    |   at-spi-bus-launcher + at-spi2-registryd (built)       |
    +---------------------------+-----------------------------+
                                |
                        xios-a11yd  (new, C + libatspi + GLib)
                          - mirrors trees via Cache.GetItems + events
                          - filters/flattens the focused window subtree
                          - merges window geometry from the compositor
                          - executes actions coming back from Xios
                                |
                 a11y snapshot protocol v1 (NDJSON over unix socket)
                                |
                Xios app (SPEC, lead owns)
                  - XiosA11yClient: socket reader
                  - XiosAccessibilityElement: UIAccessibilityElement per node
                  - Metal view publishes accessibilityElements
                  - VoiceOver gestures -> commands back to xios-a11yd
                  - fallback: synthetic tap through the existing touch path
```

Why a separate helper daemon instead of linking libatspi into Xios:

- libatspi wants a GLib main loop and D-Bus; keeping that out of the UIKit app avoids
  a GLib version lock and threading interplay with UIKit.
- Crash isolation: an a11y bug must not take down the display server app.
- Reuse: the native-iPadOS flavor runs one UIKit host per app; each host links the
  same small client and talks to the same helper with an app filter. One mirror, N
  publishers.
- The helper is per-flavor-agnostic: only its window-geometry source changes.

Process placement: xios-a11yd is a session component started by ioscd (or the
xios.session for the GNOME flavor) next to the bus launcher. It connects to the a11y
bus as a normal AT, exactly like Orca would.

## Bootstrap on the device (P0)

1. Session start runs `at-spi-bus-launcher --launch-immediately` inside the
   `dbus-run-session` environment. It claims `org.a11y.Bus`, starts the private bus,
   and registryd gets service-activated as `org.a11y.atspi.Registry`.
2. Remove the unconditional `GTK_A11Y=none` from ioscd. Gate it instead: set
   `GTK_A11Y=none` only when the bridge is disabled and no AT is expected. Escape
   hatch stays `NO_AT_BRIDGE=1` (honored by both GTK3's atk-bridge and GTK4).
3. xios-a11yd sets `IsEnabled=true` on `org.a11y.Bus` at startup and mirrors
   VoiceOver's state into `ScreenReaderEnabled` (Orca does the same). Do this as a
   D-Bus property write, not a gsettings write: with the memory gsettings backend the
   launcher's own view of `toolkit-accessibility` resets every session, and the
   property write also fires the launcher's listeners.
4. GTK3 apps: CONFIRMED compiled out. The gtk3 recipe stubs the bridge entirely
   (`linux-build/recipes/gtk+3.0.mk:20`: atk-bridge dep made optional, the
   `atk_bridge_adaptor_init` call in gtkaccessibility.c commented away) because
   at-spi2-core did not exist yet when GTK3 was built. GTK3 apps stay dark until a
   gtk3 rebuild against the libatk-bridge we now ship. Not a P0 blocker (GTK4/Qt
   are the priority targets) but queue the rebuild before P4 breadth.
5. Qt/KDE: qtbase must be configured with the AT-SPI bridge feature, and the
   current recipe cannot enable it with one flag: the bridge's cmake condition is
   accessibility + QtDBus + libatspi found via pkg-config, and today's recipe sets
   `-DFEATURE_dbus=OFF` (`linux-build/recipes/qtbase.mk:160`). Needed: flip
   `-DFEATURE_dbus=ON` (links the libdbus we already ship; KF6/Plasma needs QtDBus
   anyway, so this belongs in the same round-2 reconfigure as printsupport), put
   at-spi2-core dev headers in the qtbase sysroot, and add
   `-DFEATURE_accessibility_atspi_bridge=ON` so configure errors out instead of
   silently dropping the bridge. Do this in the round-2 rebuild at the latest;
   every Qt/KDE app built against a bridgeless qtbase is invisible to any AT.
6. Smoke test without any Apple-side work: a 50-line `atspi-dump` CLI (libatspi) that
   prints the tree of every registered app. If `atspi-dump` sees gnome-console's
   widgets, the Linux half works.

## Tree mirror in xios-a11yd

State: per application, a hash map keyed by (bus name, object path) holding role,
name, description, state set, interfaces, parent, children, and window-relative
extents. Populated by `Cache.GetItems` when an app registers or its window activates,
then maintained incrementally. libatspi already implements the cache handshake and
both GetItems signatures; the helper uses libatspi rather than raw D-Bus.

Event subscriptions (the full list; register nothing else so toolkits skip emitting
the rest):

| event string | mirror effect | pushed to Xios as |
|---|---|---|
| `window:activate` / `window:deactivate` | switch published window | `window` + `reset` |
| `window:create` / `window:destroy` | window list update | `window` / `remove` |
| `object:children-changed` | re-fetch children of source | `upsert` / `remove` |
| `object:state-changed:focused` | track focus | `focus` |
| `object:state-changed:checked` (also `selected`, `expanded`, `sensitive`, `showing`) | update node | `upsert` |
| `object:property-change:accessible-name` (also `-description`, `-value`) | update node | `upsert` |
| `object:bounds-changed` | update extents | `upsert` (frame only) |
| `object:text-changed` / `object:text-caret-moved` | update text nodes | `upsert` (focused editable only) |
| `object:announcement` | none | `announce` |

Publication policy (this is what keeps it fast):

- Only the focused toplevel window's subtree is published, plus the shell panel.
  Background windows exist only as window entries (VoiceOver reaches them through a
  custom rotor/action "next window", which activates them).
- Nodes are published only if states contain SHOWING and VISIBLE, extents intersect
  the window, and the role is not a pure layout container (filler, panel with no
  name, viewport, split pane). Containers that carry semantics (toolbars, tab lists,
  menus, tables) survive as grouping elements.
- Flatten to pre-order; VoiceOver's swipe order is the array order.
- Soft cap ~200 published elements per window; beyond that, collapse offscreen
  scroll-container content and fetch on demand when VoiceOver scrolls.
- Event coalescing: 50 ms debounce per window; one diff batch per tick, never a
  full rebuild. Full rebuild only on `window:activate` (single GetItems round trip).
- Nothing here is per-frame. Compositor frame rate is untouched; the a11y path only
  wakes on D-Bus traffic.

## Coordinates

Chain, per element:

1. `GetExtents(coord_type=1)` gives x,y,w,h relative to the toplevel window
   (trustworthy under Wayland; screen-relative is not).
2. xios-a11yd adds the window's origin in desktop pixels. Source per flavor:
   - iosc flavor: iosc knows every toplevel's placement. Add a one-way geometry feed
     (window id, app-id, title, x, y, w, h, focused, serial) from iosc to xios-a11yd.
     Cheapest transport: a private wayland global or the existing shell-side channel;
     iosc-shell's foreign-toplevel list has everything except x,y, so a small
     extension event carrying geometry is enough.
   - GNOME flavor: `org.gnome.Shell.Introspect.GetWindows` (position + size; the
     screencast portal uses it).
   - KDE flavor: KWin's D-Bus window list.
   - native-iPadOS flavor: not needed; one window per host, origin is (0,0).
3. Correlating an AT-SPI application window with a compositor toplevel: match by
   (application name or D-Bus name vs app-id) then title, tie-broken by activation
   order (the window that went active on both channels last). This heuristic is the
   acknowledged weak joint of every out-of-process Wayland AT (Newton's motivation);
   it is reliable in practice for single-window apps, which is the overwhelming case
   here. Multi-window mismatches degrade to wrong offsets, never crashes.
4. The element's desktop-px rect is pushed to Xios. Xios converts to view points with
   the existing inverse `framebufferPoint` transform, then
   `UIAccessibilityConvertFrameToScreenCoordinates`. Because the transform is applied
   lazily in the `accessibilityFrame` getter, zoom/pan/letterbox changes need no
   re-push and no event storm.

Known hole, deferred to P4: GTK menus and popovers are separate xdg_popup surfaces,
and their AT-SPI extents may be relative to the popup surface rather than the parent
window. Needs empirical testing on device; the fallback is to hit-test popups via the
compositor's popup geometry (iosc knows every popup's placement too).

## Focus and VoiceOver cursor sync

- AT-SPI focus moved (`object:state-changed:focused` true): push `focus {id}`; Xios
  posts `UIAccessibility.post(.layoutChanged, argument: element)` which moves the
  VoiceOver cursor. This covers Tab-key users and app-driven focus moves.
- VoiceOver browsing (swipe) does NOT call `GrabFocus`. Browsing must not steal
  keyboard focus from a text field mid-edit; this matches VoiceOver semantics on iOS.
- VoiceOver activate (double-tap): `activate {id}` -> helper tries, in order:
  `Action.DoAction(0)`; if no Action interface, `Component.GrabFocus` + synthetic tap
  request back to Xios (`tap {desktop-px}`) through the existing touch-injection path.
- Window switch: `window:activate` -> Xios posts `.screenChanged` with the first
  element of the new window.
- `object:announcement` -> `.announcement` notification (GTK 4.14+
  `gtk_accessible_announce`, libadwaita toasts land here).
- Modal dialogs: MODAL state -> `modal` in the container element's `traits` on
  the wire -> `accessibilityViewIsModal` on the published container, so VoiceOver
  stays inside the dialog.

## Role and state mapping

Traits (iOS 16 floor: no `.toggleButton`, it is iOS 17+; checked state goes in
accessibilityValue, which is how UIKit apps did it pre-17 anyway).

| AT-SPI role | UIAccessibility | notes |
|---|---|---|
| push_button | `.button` | |
| toggle_button | `.button` | value "on"/"off" |
| check_box, check_menu_item | `.button` | value "checked"/"not checked" |
| radio_button, radio_menu_item | `.button` | `.selected` when checked |
| link | `.link` | |
| label, static | `.staticText` | |
| heading | `.header` | rotor "Headings" works free |
| entry, editable text | none | value = text, hint "text field"; see text notes |
| password_text | none | value masked, hint "secure text field" |
| slider, spin_button, scroll_bar | `.adjustable` | increment/decrement below |
| progress_bar, level_bar | `.updatesFrequently` | value = percent |
| image, icon | `.image` | |
| combo_box | `.button` | value = current item |
| menu_item | `.button` | |
| menu, menu_bar | grouping element | children published when SHOWING |
| page_tab | `.button` + `.selected` | |
| page_tab_list | `.tabBar` | |
| list_item, tree_item | `.staticText` (+`.selected`) | tree: custom actions Expand/Collapse |
| table_cell | `.staticText` | row/column position in hint (P4) |
| tool_bar, status_bar | grouping / `.staticText` | status bar adds `.updatesFrequently` |
| terminal | `.staticText` + `.updatesFrequently` | value = visible text via Text iface, capped |
| frame, window, dialog | not elements | windows drive screenChanged; dialog modality above |
| alert, notification | announcement | plus published subtree while SHOWING |
| filler, panel, viewport, split_pane, separator | dropped | unless named |
| anything else | none | hint = `atspi_accessible_get_localized_role_name()` |

States:

| AT-SPI state | effect |
|---|---|
| SENSITIVE/ENABLED absent | `.notEnabled` |
| SELECTED | `.selected` |
| CHECKED | accessibilityValue |
| EXPANDED / EXPANDABLE | custom actions Expand/Collapse, value "expanded"/"collapsed" |
| SHOWING + VISIBLE | publication gate |
| FOCUSED | focus sync only, no trait |
| MODAL | `modal` trait string on the dialog's container element -> accessibilityViewIsModal |
| BUSY | `.updatesFrequently` |
| EDITABLE | text-field hint |

Actions beyond the default: `GetActions` names (localized) become
`accessibilityCustomActions`, executed via `action {id, index}`.

Adjustable: `accessibilityIncrement`/`Decrement` -> `adjust {id, +1|-1}` -> helper
writes `Value.CurrentValue` +/- `MinimumIncrement` (clamped to Minimum/Maximum).

Text editing: published value tracks `object:text-changed` for the focused editable.
Input itself rides the existing tap+type keyboard path (activate focuses the field,
the iOS keyboard types into it). Full UITextInput-grade editing (VoiceOver text rotor,
character echo) is explicitly out of scope for v1; `TextCaretMoved` to announcement
echo is a P3 stretch.

Escape gesture (2-finger Z): `accessibilityPerformEscape` -> synthesize Esc keypress
via the existing keyboard injection. Scroll gestures: `accessibilityScroll(direction)`
-> synthetic wheel/swipe at the container center through the touch path.

## SPEC: Xios app work (lead owns; do not build from this doc without him)

New files, roughly 600-900 lines of Swift total:

1. `XiosA11yClient`: connects to the helper socket, NDJSON decode on a utility queue,
   applies diffs to an element store, swaps the published array on the main queue.
   Reconnect with backoff; a `reset` message drops the store (helper restarts are
   invisible to the user beyond a screenChanged).
2. `XiosAccessibilityElement: UIAccessibilityElement`, one per published node.
   Holds node id, window id, desktop-px rect, role/trait/label/value/hint/custom
   actions. Overrides:
   - `accessibilityFrame` getter: desktop-px rect -> view points via the cursor
     overlay's inverse transform -> `UIAccessibilityConvertFrameToScreenCoordinates`.
   - `accessibilityActivate()` -> send `activate`, return true.
   - `accessibilityIncrement`/`accessibilityDecrement` -> `adjust`.
   - `accessibilityPerformEscape()` -> `escape`.
   - `accessibilityScroll(_:)` -> `scroll`.
   - `accessibilityElementDidBecomeFocused()` -> optional `vo-focus` (helper uses it
     only for logging/metrics in v1; no GrabFocus).
3. Metal view container: `isAccessibilityElement = false`,
   `accessibilityElements = store.orderedElements` (array swapped atomically on main).
4. Notifications: `.layoutChanged(element)` on `focus`, `.screenChanged(first)` on
   window switch/reset, `.announcement(text)` on `announce`.
5. Gating: start the client and tell the helper `enable {true}` only when
   `UIAccessibility.isVoiceOverRunning`; observe
   `voiceOverStatusDidChangeNotification`. When VoiceOver is off the entire pipeline
   (helper mirror included) is quiescent and costs nothing.
6. Synthetic tap service: `tap {x, y}` from the helper feeds the existing
   touch-to-pointer injection at desktop-px coordinates.

### Authoritative Wire Schema

Transport: NDJSON over the unix socket `/var/jb/tmp/xios-a11y.sock`, mode 0600.
Fixed path on purpose, same convention as `ioscd.sock`/`iosc-wm.sock`; do NOT
derive it from `$XDG_RUNTIME_DIR`, which ioscd points at per-app private bus dirs
(`ioscd.c:255`). ONE listener serves every client: the Xios desktop app and N
native per-app hosts concurrently. Each connection carries its own bind filter,
enable state, and generation counter. The native-flavor messages from
`native-ipados-a11y.md` are part of this single current schema.

Encoding: one JSON object per line, discriminator `t`. `id`/`win` are
helper-assigned uint32, unique within a generation. `frame` is `[x,y,w,h]` ints —
desktop-px on unbound (desktop) connections, window-relative px on bound ones.
`traits` draws from the fixed vocabulary `button link header static-text image
adjustable selected not-enabled updates-frequently tab-bar search-field
keyboard-key modal` — thirteen strings. The vocabulary is ours, not literally
UIAccessibilityTraits: `modal` maps to the `accessibilityViewIsModal` property
on the dialog's container element (the grouping element published for the
dialog), not to a trait bit; it is how AT-SPI's MODAL state rides the wire.
`actions` is an array of localized action-name strings whose index is the
AT-SPI action index.

helper -> app:

- `{"t":"hello","gen":G}`
- `{"t":"window","id":W,"appid":S,"title":S,"frame":F,"focused":B}`
- `{"t":"upsert","id":N,"win":W,"parent":P,"idx":I,"role":S,"label":S,"value":S,"hint":S,"traits":[...],"actions":[...],"frame":F}` (`parent:0` = window root)
- `{"t":"remove","id":N}` (removes the subtree; children go with it)
- `{"t":"focus","id":N}`
- `{"t":"announce","text":S}`
- `{"t":"tap","x":X,"y":Y}` (bound connections add `"win":W` and the coordinates
  are window-relative; the host injects locally through its own IoscInput
  connection, no compositor round trip)
- `{"t":"reset","gen":G}` (drop the store; helper restarted, window switched, or
  bound app relaunched)

app -> helper:

- `{"t":"bind","appid":S}` — first message after connect; scopes the connection
  to one AT-SPI application. Unbound connection = desktop semantics, unchanged.
- `{"t":"enable","on":B}`
- `{"t":"activate","id":N}`, `{"t":"action","id":N,"idx":I}`
- `{"t":"adjust","id":N,"dir":D}` with D = 1 or -1
- `{"t":"escape","id":N}`, `{"t":"scroll","id":N,"dir":"up|down|left|right"}`
- `{"t":"attach","win":W}` / `{"t":"detach","win":W}` — advisory scene
  visibility from native hosts; in the schema from day one so hosts can send
  them unconditionally, but the helper may ignore them until it implements
  traffic muting (P4)
- `{"t":"vo-focus","id":N}` (logging/metrics only)

Bound-connection semantics: `bind` is a persistent filter. If the AT-SPI app has
not registered yet (cold launch), the helper holds the filter and starts
publishing when the app's `Socket.Embed` arrives; on app exit it sends `reset`
and re-publishes on relaunch. Bound connections receive ALL mapped toplevels of
the app, not focused-only (iPadOS can Split View two scenes of one app); the
per-window caps, filters, and debounce above apply unchanged per window.
App-to-appid correlation is deterministic: ioscd streams
`spawn{appid,pid}`/`exit{appid,pid}` records to the helper (ioscd starts the
helper, so a pipe or the runtime-dir socket both work), joined against
`org.freedesktop.DBus.GetConnectionUnixProcessID` on the a11y bus. Name-matching
survives only as the helper-restart race fallback.

NDJSON is deliberate: trees are small after filtering and it is debuggable with
`nc`. Revisit binary framing only if profiling says so.

## Per-flavor notes

- GNOME: richest tree. GNOME Shell itself registers on the a11y bus, so the top bar,
  overview, and notifications come free through the same bridge. Geometry via
  Shell.Introspect. Orca is also installable here later, but see below.
- KDE: Qt apps arrive via Qt's bridge once qtbase is built with the atspi feature.
  Plasma chrome is Qt, so it is covered too. Geometry via KWin D-Bus. Verify the Qt
  cache old-signature path against libatspi on device (expected fine, it is handled
  in atspi-misc.c).
- native-iPadOS flavor: the best fit of all. Each Linux app has its own UIKit host,
  so elements live in the app's own accessibility context: window origin is (0,0)
  (no correlation heuristics), VoiceOver's app switcher separates Linux apps
  natively, and per-app element counts are small. The same helper serves each host
  filtered by app. Recommend making this flavor the a11y showcase. Spec'd in
  detail in `native-ipados-a11y.md` (host-side prototype exists in
  `apps/iosc-host/Sources/HostA11y.swift`); its protocol additions are folded
  into the schema above.
- iosc-shell: our panel/launcher are bare cairo, invisible to AT-SPI. Two options:
  (a) implement a minimal AT-SPI server in the panel (Socket.Embed + Accessible +
  Component + Action over raw libdbus; the panel has a dozen static elements, this
  is a few hundred lines), or (b) sidestep the bus and have the shell push its
  elements to xios-a11yd over its existing channel. Choose (a): it also makes the
  shell readable by Orca and by atspi-dump, and it keeps xios-a11yd single-protocol.

## Orca option (complement, not primary)

Stack: espeak-ng + dotconf + speech-dispatcher + Orca (Python, needs pygobject and
on-device typelibs, both of which we already have). Audio goes out through the PA 17
daemon. Estimated 4 new debs, no known iOS-hostile code (espeak-ng and speechd are
portable C; Orca is pure Python over gi).

Why it is not the primary path: Orca is keyboard-driven (flat review, modifier
chords) and assumes a hardware keyboard; VoiceOver owns the touch gestures and the
two would double-speak the GNOME flavor. It makes sense (a) as the a11y story for
the X11-legacy flavor where the bridge does not reach, (b) for users who dock a
keyboard and want the full desktop screen-reader model, and (c) during bridge
development as a reference consumer: if Orca reads a tree correctly and the bridge
does not, the bug is ours. Ship it as an optional deb set, off by default, with a
"mutes VoiceOver bridge speech" note.

## Prior art

- AccessKit (accesskit_ios 0.1.1, June 2026): Rust adapters that publish a toolkit-
  agnostic tree via UIAccessibility (accessibilityElements + hit test), exactly the
  publication layer we are speccing. Too young to depend on and Rust-in-Xios is a
  cost, but its role/trait mapping and its Adapter API shape are worth borrowing,
  and GTK upstream is moving toward AccessKit, which would eventually let us swap
  the AT-SPI mirror for an AccessKit tree without touching the Xios side.
- GNOME Newton (LWN: Modernizing accessibility for desktop Linux): push-based tree
  updates through the compositor, motivated by the same Wayland coordinate and
  round-trip problems we hit; it explicitly lists accessible remote-desktop sessions
  (our situation, with the "remote" being local) as a target. Validates the
  mirror-and-push design over per-gesture round trips.
- Flutter iOS: SemanticsObject bridges the engine's semantics tree to
  UIAccessibilityElements with frame transforms and incremental updates; the closest
  shipped analog of "foreign tree published on a single rendering view".
- Negative prior art: XQuartz never bridged X11 apps to NSAccessibility; X11 apps
  are simply invisible to macOS VoiceOver. Nobody has shipped AT-SPI to
  UIAccessibility before, as far as searching shows.

## Build and dependency cost

| item | status | cost |
|---|---|---|
| at-spi2-core (launcher, registryd, libatspi, atk-bridge) | built | 0 |
| GTK4/Shell AT-SPI backends | in toolkits | config only (drop the GTK_A11Y=none gate) |
| Qt AT-SPI bridge | in qtbase, disabled | qtbase round-2 reconfigure: FEATURE_dbus=ON + atspi headers in sysroot + bridge feature (P0 item 5) |
| GTK3 atk-bridge | compiled out (`gtk+3.0.mk:20`) | gtk3 rebuild against the shipped libatk-bridge, before P4 |
| atspi-dump CLI | new | trivial |
| xios-a11yd | new | ~1.5-2k lines C, links libatspi+glib (both shipped) |
| iosc geometry feed | new | small compositor + shell-channel addition |
| Xios app side | SPEC above | 600-900 lines Swift, no new deps |
| iosc-shell AT-SPI objects | new | few hundred lines, libdbus (shipped) |
| Orca stack (optional) | new | 4 debs: espeak-ng, dotconf, speech-dispatcher, orca |

## Phases

- P0 plumbing: launcher in session, GTK_A11Y gate removed, IsEnabled property write,
  qtbase round-2 flags queued (item 5 above), atspi-dump. Accept: atspi-dump prints
  gnome-console's full widget tree on device.
- P1 read-only browse: xios-a11yd mirror + protocol + Xios elements for the focused
  window (labels, roles, frames). Accept: VoiceOver swipes through gnome-console and
  gtk4-demo controls with correct speech and touch exploration lands on the right
  frames. The native host (`native-ipados-a11y.md`) is the endorsed FIRST
  publisher here: it needs only bind + multi-connection, no geometry feed and no
  correlation heuristics, so it validates the helper and wire protocol end-to-end
  before the Xios desktop client lands. It supplements, not replaces, the desktop
  acceptance above.
- P2 interaction: activate, custom actions, adjustable, focus sync, screenChanged.
  Accept: VoiceOver double-tap toggles a gtk4-demo checkbox, adjusts a slider,
  activates panel buttons; Tab in a docked keyboard moves the VoiceOver cursor.
- P3 live updates: announcements, state/name changes, text value tracking on focused
  editable, modal dialogs. Accept: libadwaita toast is spoken; typing into a GTK
  entry updates its spoken value.
- P4 breadth: popups/menus (xdg_popup extents), background-window rotor, tables,
  terminal text, KDE flavor on-device pass, GNOME flavor geometry via
  Shell.Introspect, per-app hosts for the native flavor.
- P5 optional Orca deb set for X11-legacy and keyboard users.

## Risks and open questions

- Window correlation heuristics (section Coordinates) are the weakest link;
  single-window apps are safe, multi-window GIMP-style apps may mis-offset until we
  add a compositor-side disambiguator.
- GTK popup extents under Wayland need a device test before P4 design is final.
- gnome-shell publishes a very large chrome tree; the SHOWING/VISIBLE filter plus
  focused-window policy must be measured there, not just in single-window apps.
- Event storms on window open are handled by debounce, but a pathological app
  (terminal spew with a screen reader flag set) needs the text-event cap verified.
- ioscd's C-locale issue (already queued) also affects localized role names here.
- The a11y bus grants read and control of every app's UI to any local process; on a
  jailbroken single-user device this is acceptable, but keep the helper socket 0600
  and do not TCP-forward the a11y bus.
