# GNOME touch UX on the iPad: from "boots" to "usable"

Target: stock GNOME Shell 46 on Mutter 46 + MetaBackendIOS, usable as a
touch + trackpad hybrid desktop on the iPad 7 (A10, 2160x1620). Not a phone
shell; the native-iPadOS flavor is the touch-first path
(docs/native-ipados-plan.md). This doc ranks the minimal work, reusing the
input plumbing the iosc flavor already validated on-device.

Related: docs/mutter-on-iosc.md (backend), docs/gnome-session-plan.md
(session), memory notes `wayland-m1-compositor`, `x11-distribution-chooser`.

## 1. What GNOME 46 already does on a touchscreen (verified upstream)

All of this ships in stock gnome-shell/mutter 46 and needs no patches, only
real touch events reaching Clutter:

- **3-finger touch swipes** (`js/ui/swipeTracker.js`, `GESTURE_FINGER_COUNT = 3`):
  vertical swipe enters/leaves the overview and app grid, horizontal swipe
  switches workspaces. Kinetic, interruptible, with touch-specific
  deceleration constants (`DECELERATION_TOUCH`, `VELOCITY_THRESHOLD_TOUCH = 0.3`).
- **Single-finger touch** everywhere in the shell chrome: tap activates,
  drag moves windows/scrolls the app grid pages, long-press on app icons
  opens their menu. GTK4 apps get kinetic scrolling, long-press context
  menus, and touch text-selection handles from `wl_touch` alone.
- **On-screen keyboard** (`js/ui/keyboard.js`): auto-opens when a text field
  gains focus, chooses layout from the field's `content-purpose`
  (digits/number/phone/email/URL/terminal), and a bottom-edge drag summons
  it. Enable condition (exact 46 logic):

  ```js
  let enableKeyboard = a11yApplicationsSettings.get_boolean('screen-keyboard-enabled');
  let autoEnabled = this._seat.get_touch_mode() && this._lastDeviceIsTouchscreen();
  let enabled = enableKeyboard || autoEnabled;
  ```

  Text is delivered by `Main.inputMethod.commit()` (mutter text-input-v3 to
  Wayland clients, full Unicode) with a virtual-keyboard keyval fallback.
  The OSK is entirely internal to the shell; it does NOT use
  `zwp_input_method_v2` / `zwp_virtual_keyboard_v1`.
- **Stylus**: mutter 46 implements `zwp_tablet_v2` toward clients; GTK4 apps
  read pressure/tilt via `GtkGestureStylus`. The shell treats the pen as a
  pointer for its own chrome.
- **HiDPI**: we already advertise the output at scale 2
  (meta-monitor-manager-ios.c), so the logical desktop is 1080x810 and
  default GNOME touch targets are already iPad-sized. This is the single
  biggest free win; do not regress it.

Two upstream facts that bound the design:

- `ClutterSeat` virtual devices in mutter 46 support POINTER, KEYBOARD and
  TOUCHSCREEN (`clutter_virtual_input_device_notify_touch_down/motion/up`,
  the remote-desktop path). There is **no virtual tablet device**; stylus
  needs in-tree event synthesis (Phase 4).
- `ClutterSeat:touch-mode` defaults to FALSE; the seat subclass overrides the
  property getter. MetaSeatNative returns TRUE when a touchscreen is present
  and no external keyboard forces it off. MetaSeatIOS must do its own
  override (Phase 1).

## 2. The gap: what our GNOME flavor drops today

The wire from the Xios app already carries everything
(x11/wayland/xios_input_socket.h): MOTION(1) BUTTON(2) KEY(3) TEXT(4)
TRAITS(5, server to app, OSK traits) TOUCH(6) TABLET(7). The app fans out
every UITouch, Pencil as type 7 with pressure/tilt, fingers as type 6 with
slots (XScreen.swift:1006). iosc consumes all of it, on-device validated.

The Mutter backend consumes only half of it:

| Piece | State | Where |
|---|---|---|
| Pointer + keyboard into Clutter | works | meta-input-ios.c:74-105 |
| TOUCH(6) records | **dropped** (default case) | meta-input-ios.c:122 |
| TABLET(7) records | **dropped** | meta-input-ios.c:122 |
| TEXT(4) | ASCII-only keyval clicks | meta-input-ios.c:107-120 |
| Seat touch capability / touch-mode | absent (pointer+keyboard only, touch-mode FALSE) | meta-seat-ios.c:148-170 |
| Virtual touchscreen device type | not offered | meta-seat-ios.c:151-152 |
| Scroll | **absent end-to-end**: no wire type, app suppresses it on iosc (`if usingIosc { return }`, XScreen.swift:879), no notify_scroll in the virtual device | XScreen.swift:877, meta-virtual-input-device-ios.c |
| TRAITS(5) emission | iosc-only (iosc.c:4736); mutter never sends it | n/a |

Consequences in a booted gnome-shell today: taps work (as mouse clicks),
typing works (ASCII), but no 3-finger gestures, no kinetic scrolling, no
OSK auto-show (touch-mode FALSE and last device is never a touchscreen),
no two-finger trackpad scroll, Pencil is just a mouse.

**Do not wire ios-inputd into this flavor.** ios-inputd
(x11/wayland/ios-inputd.c) binds `zwp_input_method_v2` +
`zwp_virtual_keyboard_v1`, which mutter does not implement. The GNOME path
is meta-input-ios feeding ClutterVirtualInputDevices, full stop.

Correction (2026-07-29, verified against the kwin 6.1.5 sources): those two
are **wlroots** protocols, not "wlroots/KWin". KWin 6.1.5 implements
`input-method-unstable-v1` + `input-panel-v1` and neither of ios-inputd's
globals, so ios-inputd is dead on KDE too until its Wayland half is
rewritten for v1. Details and the bridge design are in osk-plan.md, section
"KDE flavor".

## 3. Recommended plan, ranked by effort

### Phase 0: config only, no code (hours)

gsettings applied by the session launcher (GSETTINGS_BACKEND is dconf once
the session layer lands; `gsettings set` from the launch script):

| Setting | Value | Effect |
|---|---|---|
| `org.gnome.desktop.a11y.applications screen-keyboard-enabled` | `true` | Force-enables the OSK now, independent of touch-mode. It auto-opens on text focus and its keys work with plain pointer taps, so this makes typing usable before Phase 1 lands. |
| `org.gnome.desktop.interface text-scaling-factor` | `1.0` first; `1.15-1.25` if targets still feel small at scale 2 | Large Text lever; scales GTK and shell text plus header-bar heights. |
| `org.gnome.desktop.interface cursor-size` | `32` (default 24) | Optional; finger-friendly cursor. |
| `org.gnome.desktop.wm.preferences resize-with-right-button` | `true` | Trackpad two-finger-click drag resize anywhere in the window, avoids hunting 1-2 px edges. |
| `org.gnome.mutter workspaces-only-on-primary` | default fine (single output) | listed to say: no change needed. |

Keep monitor scale 2. Nothing else in Phase 0.

### Phase 1: touch into Mutter (the unlock, 1-2 days)

Small, all in files we own, modeled exactly on mutter's remote-desktop touch
path:

1. **meta-seat-ios.c**: add a third core device
   (`CLUTTER_TOUCHSCREEN_DEVICE`, `CLUTTER_INPUT_CAPABILITY_TOUCH`); add
   `CLUTTER_VIRTUAL_DEVICE_TYPE_TOUCHSCREEN` to
   `get_supported_virtual_device_types`; override the `touch-mode` property
   getter to return TRUE (env-gateable, `XIOS_TOUCH_MODE=0` for debugging).
2. **meta-virtual-input-device-ios.c**: implement
   `notify_touch_down/motion/up` vfuncs (queue ClutterEvents on the stage,
   same shape as the existing button path; slot = wire touch id).
3. **meta-input-ios.c**: create the virtual touchscreen next to
   pointer/keyboard; handle `XIOS_IN_TOUCH`: phase 1=down, 2=motion, 0=up,
   3=cancel (deliver as up; Clutter virtual devices have no cancel). Divide
   by `xios_output_scale()` like MOTION does.
4. **App side, one flag**: XScreen.swift currently fires BOTH the legacy
   pointer emulation and type-6 touch for every finger
   (`ioscTouchReplacesPointer = false`, XScreen.swift:987). Against
   gnome-shell that produces a pointer click plus a touch tap for each tap.
   For the GNOME flavor launch config flip it to true, but route by
   `UITouch.type`: `.direct` to TOUCH, `.pencil` to TABLET (already done,
   XScreen.swift:1008), `.indirectPointer` (trackpad) stays on the
   MOTION/BUTTON path. Without the type split, flipping the flag would kill
   the trackpad.

Payoff (all stock shell behavior, nothing to configure): 3-finger overview
and workspace swipes, kinetic scrolling in every GTK app, long-press context
menus, touch window drag, OSK auto-show on text focus (both
`touch_mode` and `_lastDeviceIsTouchscreen()` become true), bottom-edge
swipe summons the OSK.

Validation: injector `iosc-input-test -t` equivalents against the mutter
socket; then on-screen: 3-finger swipe up = overview, tap a GTK text field =
OSK appears, flick-scroll kgx output.

### Phase 2: scroll (trackpad two-finger, small wire addition, ~1 day)

Core hybrid-desktop UX; currently dead on this path.

1. **Wire**: add `XIOS_IN_AXIS 9` to xios_input_socket.h and its
   keep-identical twin xios-glue-stub.h (additive; the shared reader passes
   unknown fixed records through, same pattern as types 6/7). 9, not 8: the
   native-ipadOS host already had `XIOS_IN_BIND 8` on-wire
   (apps/iosc-host/Sources/IoscInput.c) before this landed. Encoding: x,y =
   dx,dy in 1/256 px fixed-point, state bit0 = fingers-off (axis_stop),
   code = source (0 finger/1 wheel), mods = modifier mask to latch during
   delivery (pinch-zoom sends ctrl). DONE in the header twins.
2. **App**: XScreen.swift `sendScroll` drops the `usingIosc` early-return and
   emits AXIS records (it already accumulates deltas for the XTEST path).
3. **Mutter backend**: meta-virtual-input-device-ios implements
   `notify_scroll_continuous` (+ `notify_discrete_scroll`); meta-input-ios
   maps AXIS to it.
4. **iosc too**: handle AXIS in iosc.c as `wl_pointer.axis` +
   `axis_source(finger)` + `axis_stop`, so the iosc flavor gets real smooth
   scrolling from the same app build (today it has none either).

Payoff: two-finger trackpad scroll in GTK apps and shell (overview workspace
scrub, app-grid paging), pinch-ish momentum via UIKit's pan recognizer.

### Phase 3: text entry polish (0 days now, optional bridge later)

Ship the **shell OSK** as the GNOME flavor's keyboard. It already delivers
full Unicode via `Main.inputMethod.commit()`, honors content-purpose
layouts, and needs nothing from us once Phases 0-1 land. The iOS system
keyboard (TRAITS path) stays the iosc-flavor mechanism.

Known limitation to accept for now: the hardware/floating iOS keyboard path
into gnome-shell (XIOS_IN_TEXT) is ASCII-only keyval clicks
(meta-input-ios.c:107). Two upgrade options if it matters later, in order:

- map non-ASCII codepoints to Unicode keysyms (`codepoint | 0x01000000`) in
  the TEXT loop; works for most input without touching the shell;
- a real IM bridge: from meta-input-ios, resolve
  `clutter_backend_get_input_method()` (the shell registers its InputMethod
  there) and commit through the focused `ClutterInputFocus`. Needs a small
  in-tree helper; investigate only if a hardware keyboard with dead
  keys/CJK becomes a real use case.

Also decide whether mutter should broadcast TRAITS on text-input focus
(mirroring iosc.c:4736) so the app can raise the iOS keyboard in the GNOME
flavor too. Recommendation: no. Two OSKs fighting (shell OSK resizes the
stage, iOS keyboard overlays the Metal layer and covers the focused field
with no way to scroll it into view) is worse than one consistent shell OSK.

SUPERSEDED (2026-07-29): the broadcast landed anyway.
patches/mutter/meta-wayland-text-input-osk-ios.patch hooks
meta-wayland-text-input.c and is applied unconditionally by
integrate-ios-backend.sh, so a booted GNOME flavor has both the shell OSK
(if the gsetting is on) and the iOS keyboard. If they do fight on device,
turn off `screen-keyboard-enabled` rather than dropping the patch: mutter is
the root compositor here and owns the input socket, which makes the TRAITS
half the cheap one to keep. Flavor matrix lives in osk-plan.md.

### Phase 4: Apple Pencil as a real stylus (2-4 days, after 1-2)

No virtual tablet device exists in mutter 46, but MetaBackendIOS is compiled
in-tree, so it can use private Clutter event constructors like the native
backend does:

1. MetaSeatIOS grows a `CLUTTER_TABLET_DEVICE` ClutterInputDevice ("Apple
   Pencil") plus one `ClutterInputDeviceTool` of type PEN.
2. meta-input-ios decodes `XIOS_IN_TABLET` (code = pressure 0..65535,
   mods = packed tilt, state = phase with proximity in/out, the exact
   encoding iosc already consumes) and synthesizes
   PROXIMITY_IN/BUTTON_PRESS/MOTION/BUTTON_RELEASE/PROXIMITY_OUT events with
   pressure and tilt axes on that device.
3. Mutter's existing meta-wayland-tablet-* code picks the device up from the
   seat and speaks `zwp_tablet_v2` to clients; nothing to add there.

Payoff: pressure/tilt drawing in GTK apps (GtkGestureStylus; e.g. a future
Xournal++ or Drawing build), hover-free stroke model identical to the
validated iosc tablet path. Until then the Pencil keeps working as a
pointer, which is fine for shell chrome.

### Phase 5: optional polish (cherry-pick as annoyances surface)

- **OSK extension** for terminal work: stock OSK lacks Esc/Tab/Ctrl/arrows
  outside the terminal layout. "Improved OSK" (extensions.gnome.org 4413) or
  "GJS OSK" (5949, supports 42-48) add them; both are plain gjs extensions,
  no new native deps. Check the 46 `shell-version` in metadata before
  packaging; pick ONE (they conflict conceptually).
- Terminal content-purpose: kgx sets purpose TERMINAL, which already flips
  the stock OSK to the layout with Esc/Tab/Ctrl/arrows; test before assuming
  the extension is needed.
- "Touch X" (6156) adds a touch ripple indicator if visual feedback feels
  lacking; cosmetic only.
- If shell chrome still feels cramped: `text-scaling-factor 1.25` plus icon
  size tweaks beats any panel-resize extension.

## 4. gnome-shell-mobile: assessed, not recommended

The postmarketOS fork (currently 48.mobile, paired gnome-shell AND mutter
patch sets) is phone-first: portrait panel split top/bottom, adaptive app
grid for narrow screens, a replaced OSK, and 2D one-finger navigation
gestures tuned for 6" screens. Adopting it would mean rebasing its mutter
patches onto our already heavily patched Mutter 46 (MetaBackendIOS, X11-off,
weak-link surgery) and its shell patches onto our EDS-patched shell, to get
a UX aimed at the wrong form factor: on a 10.2" landscape iPad with a
trackpad, stock GNOME's desktop layout is the better fit, and GNOME's own
direction is adaptive-stock rather than a long-lived fork. Skip it. If its
OSK behavior patches (release-on-second-press, hide-on-scroll) ever get
upstreamed or apply cleanly, cherry-pick them then.

## 5. Effort summary

| Phase | What | Effort | Unlocks |
|---|---|---|---|
| 0 | gsettings (OSK force-on, text scale, resize-with-right-button) | hours | typing + resize usable immediately |
| 1 | touch into Mutter (seat + virtual touchscreen + TOUCH decode + app flag) | 1-2 days | gestures, kinetic scroll, OSK auto-show, long-press |
| 2 | AXIS wire type + app + backend + iosc | ~1 day | trackpad two-finger scroll everywhere |
| 3 | ship shell OSK (nothing); optional Unicode TEXT upgrade | 0 (+1 day optional) | full-Unicode typing |
| 4 | Pencil tablet events in-tree | 2-4 days | pressure/tilt in apps via zwp_tablet_v2 |
| 5 | one OSK extension + cosmetics | hours | terminal keys on OSK |

Order: 0 and 1 together (1 is the real unlock), then 2, then 4; 3 and 5 are
cheap and slot in whenever. Everything reuses the validated wire protocol
and the app's existing touch/Pencil fan-out; no new daemons, no protocol
work in iosc except the shared AXIS addition, and no shell forks.
