<!-- Pending-landing patch bundle for task #20 (touch scroll + gestures).
     Owners: xios-app (section 1), mutter-ios-2 / task #27 (section 2).
     iosc section LANDED (3ebf085, incl. BTN_LEFT right-click fix + -s injector) and was removed.
     DELETE each section when its hunks land; delete the file when empty. -->

# Handoff: two-finger scroll + long-press right-click + pinch app-zoom (Xios app)

From: touch-gestures. Wire type `XIOS_IN_AXIS 9` is in the header twins
(commit 27dca03). Files: Sources/IoscInput.h, Sources/IoscInput.c,
Sources/XScreen.swift. Everything is additive except three rewritten
functions (sendScroll, handleTwoFingerPan, handlePinch) and the four
touches* overrides. Old iosc builds ignore unknown wire types, so shipping
the app first is safe.

## 1. IoscInput.h — after the iosc_input_tablet declaration

```c
/* Two-finger / wheel scroll. dx256/dy256 = deltas in 1/256 framebuffer-pixel
 * fixed point, wl_pointer sign (positive = content scrolls down/right).
 * source: 0 finger, 1 wheel. mods: 1 shift, 2 ctrl, 4 alt latched for the
 * frame (pinch-zoom sends ctrl). stop ends the gesture (clients then fling). */
void iosc_input_axis(int dx256, int dy256, unsigned source, unsigned mods, bool stop);
```

## 2. IoscInput.c — define after IOSC_IN_TABLET, function after iosc_input_tablet

```c
#define IOSC_IN_AXIS   9   // x,y = dx,dy 1/256 px; code = source; state bit0 = stop; mods latched
```
```c
void iosc_input_axis(int dx256, int dy256, unsigned source, unsigned mods, bool stop) {
    struct iosc_in_msg m = { .type = IOSC_IN_AXIS, .x = dx256, .y = dy256,
                             .code = source, .state = stop ? 1u : 0u, .mods = mods };
    send_msg(&m);
}
```

## 3. XScreen.swift — new state (next to the existing pan/zoom vars)

```swift
    // MARK: scroll + long-press gesture state
    /// Sub-1/256-px scroll remainder for the iosc AXIS path (wl_fixed units).
    private var axisRemainder = CGPoint.zero
    /// True once this two-finger pan has emitted AXIS records (needs a stop).
    private var axisActive = false
    /// Two-finger arbitration: the first gesture to cross its threshold claims
    /// the finger pair (scroll vs pinch app-zoom) for the rest of the session.
    private enum TwoFingerMode { case undecided, scroll, zoom }
    private var twoFingerMode = TwoFingerMode.undecided
    private var twoFingerActive = 0     // live pan/pinch recognizers (0..2)
    private var pinchLastScale: CGFloat = 1
    /// ~3 wheel notches of ctrl+scroll per pinch doubling (45 logical px at
    /// output scale 2, in 1/256 fixed point). Tune on device.
    private static let pinchZoomGain: CGFloat = 23040
    /// Deferred left press: a stationary single finger only commits to a left
    /// press when it moves (drag) or lifts (tap); held past the threshold it
    /// becomes a right click instead (touch-and-hold = context menu).
    private var pendingPress: (x: Int32, y: Int32)?
    private var pendingPressTimer: Timer?
    private var pendingPressViewPoint = CGPoint.zero
    private var leftPressSent = false
    private var longPressFired = false
    private static let longPressSeconds: TimeInterval = 0.55
    private static let longPressSlopPt: CGFloat = 12
```

## 4. sendScroll: replace the `if usingIosc { return }` early-out (XScreen.swift:996)

```swift
    /// dx/dy are view-point finger deltas. iosc gets AXIS records in 1/256
    /// framebuffer-pixel fixed point with wl_pointer's sign (natural scroll:
    /// fingers up = content scrolls down the page = positive); XTEST keeps
    /// the legacy wheel-click emulation.
    private func sendScroll(dx: CGFloat, dy: CGFloat) {
        guard inputConnected else { return }
        if usingIosc {
            let ptToFb = 256 / (fittedScale(in: bounds.size) * zoomScale)
            axisRemainder.x -= dx * ptToFb
            axisRemainder.y -= dy * ptToFb
            let sx = axisRemainder.x.rounded(.towardZero)
            let sy = axisRemainder.y.rounded(.towardZero)
            if sx != 0 || sy != 0 {
                axisRemainder.x -= sx
                axisRemainder.y -= sy
                iosc_input_axis(Int32(sx), Int32(sy), 0, 0, false)
                axisActive = true
            }
            return
        }
        // ... existing XTEST body (scrollRemainder / buttons 4-7) unchanged ...
    }

    /// Fingers left the glass: end the axis gesture so clients kinetic-fling.
    private func sendScrollStop() {
        axisRemainder = .zero
        guard axisActive else { return }
        axisActive = false
        if inputConnected && usingIosc { iosc_input_axis(0, 0, 0, 0, true) }
    }
```

## 5. handleTwoFingerPan: replace whole function (XScreen.swift:1042)

Scroll goes to the window under the FINGERS, not wherever the pointer last
was: on claiming the gesture we park the pointer at the gesture centroid
(one motion), then stream deltas. Trackpad scroll events arrive with zero
touches and skip the 12pt claim threshold.

```swift
    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let isWheel = g.numberOfTouches == 0   // trackpad/wheel scroll events
        switch g.state {
        case .began:
            twoFingerBegan()
            panStartOffset = panOffset
            panLastTranslation = .zero
            scrollRemainder = .zero
            axisRemainder = .zero
        case .changed:
            let t = g.translation(in: self)
            if zoomScale > 1.01 {
                panOffset = clampedPanOffset(
                    CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y),
                    zoom: zoomScale)
                needsPresent = true
            } else {
                if twoFingerMode == .undecided, isWheel || abs(t.x) + abs(t.y) > 12 {
                    twoFingerMode = .scroll
                    if let (x, y) = framebufferPoint(from: g.location(in: self)) {
                        lastTouchPt = (x, y)
                        sendMotion(x, y)   // focus the surface under the fingers
                    }
                }
                if twoFingerMode == .scroll {
                    sendScroll(dx: t.x - panLastTranslation.x,
                               dy: t.y - panLastTranslation.y)
                }
            }
            panLastTranslation = t
        default:
            sendScrollStop()
            panLastTranslation = .zero
            scrollRemainder = .zero
            twoFingerEnded()
        }
    }

    private func twoFingerBegan() {
        twoFingerActive += 1
        if twoFingerActive == 1 { twoFingerMode = .undecided }
        cancelPendingPress()   // two fingers on glass: never a click or hold
    }

    private func twoFingerEnded() {
        twoFingerActive = max(0, twoFingerActive - 1)
        if twoFingerActive == 0 { twoFingerMode = .undecided }
    }
```

## 6. handlePinch: replace whole function (XScreen.swift:1020)

UX decision (veto if you disagree): on iosc at base zoom, pinch is APP zoom
(ctrl+scroll, the GTK/Qt convention) instead of view magnification. View
zoom stays reachable via the chrome +/- buttons and the two-finger
double-tap, and pinch still drives view zoom whenever already zoomed in
(zoomScale > 1.01) and always on the XTEST path.

```swift
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            twoFingerBegan()
            pinchLastScale = g.scale
            pinchStartZoom = zoomScale
            pinchAnchorFramebuffer = framebufferFloatPoint(from: g.location(in: self))
        case .changed:
            if usingIosc && zoomScale <= 1.01 {
                if twoFingerMode == .undecided && abs(g.scale - 1) > 0.08 {
                    twoFingerMode = .zoom
                    if let (x, y) = framebufferPoint(from: g.location(in: self)) {
                        lastTouchPt = (x, y)
                        sendMotion(x, y)   // zoom the window under the fingers
                    }
                }
                guard twoFingerMode == .zoom, inputConnected else { return }
                let ratio = g.scale / max(pinchLastScale, 0.01)
                pinchLastScale = g.scale
                // ctrl+scroll-up zooms in, so pinch-out = negative axis
                let dy256 = -log2(ratio) * Self.pinchZoomGain
                iosc_input_axis(0, Int32(dy256.rounded()), 0, 2, false)
                return
            }
            let location = g.location(in: self)
            setZoom(pinchStartZoom * g.scale, around: location)
            if let fp = pinchAnchorFramebuffer {
                let rect = contentRect()
                panOffset.x = location.x - bounds.midX + rect.width * (0.5 - fp.x / CGFloat(fbWidth))
                panOffset.y = location.y - bounds.midY + rect.height * (0.5 - fp.y / CGFloat(fbHeight))
                panOffset = clampedPanOffset(panOffset, zoom: zoomScale)
                needsPresent = true
            }
        case .ended, .cancelled, .failed:
            if twoFingerMode == .zoom && usingIosc && inputConnected {
                iosc_input_axis(0, 0, 0, 2, true)
            }
            pinchAnchorFramebuffer = nil
            twoFingerEnded()
        default:
            break
        }
    }
```

## 7. Deferred press + long-press right-click: replace the four touches*
## overrides (XScreen.swift:1167-1190) and add the helpers

Behavior change on purpose: a quick tap now delivers press+release at
finger-UP instead of press-at-down (that is what makes tap / drag / hold
distinguishable). Drags still press at the ORIGINAL point once movement
exceeds the slop, so drag semantics are unchanged. Also fixes today's
phantom left-click before every two-finger scroll (press went out at
touchesBegan, then the recognizer's cancel released it = a stray click).
Pencil and trackpad (.indirectPointer) keep the immediate-press path: hold
must not become right-click for a pen (drawing) or a physical button.

```swift
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if forwardIoscAll(touches, phase: 1, event: event) && Self.ioscTouchReplacesPointer { return }
        guard (event?.allTouches?.count ?? touches.count) == 1 else {
            cancelPendingPress()   // a second finger means gesture, not click
            return
        }
        guard inputConnected, let t = touches.first,
              let (x, y) = framebufferPoint(from: t.location(in: self)) else { return }
        lastTouchPt = (x, y)
        longPressFired = false
        if t.type == .direct {
            // Finger: defer the press so a still hold can become a right click.
            pendingPress = (x, y)
            pendingPressViewPoint = t.location(in: self)
            pendingPressTimer?.invalidate()
            pendingPressTimer = Timer.scheduledTimer(withTimeInterval: Self.longPressSeconds,
                                                     repeats: false) { [weak self] _ in
                self?.fireLongPress()
            }
        } else {
            // Pencil / trackpad: press immediately, no long-press synthesis.
            sendMotion(x, y); sendButton(1, true, at: (x, y))
            leftPressSent = true
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if forwardIoscAll(touches, phase: 2, event: event) && Self.ioscTouchReplacesPointer { return }
        guard (event?.allTouches?.count ?? touches.count) == 1,
              inputConnected, let t = touches.first,
              let (x, y) = framebufferPoint(from: t.location(in: self)) else { return }
        if longPressFired { return }          // the hold became a right click
        if pendingPress != nil {
            let l = t.location(in: self)
            if hypot(l.x - pendingPressViewPoint.x,
                     l.y - pendingPressViewPoint.y) < Self.longPressSlopPt { return }
            flushPendingPress()               // it moved: press at the origin
        }
        lastTouchPt = (x, y)
        sendMotion(x, y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if forwardIoscAll(touches, phase: 0, event: event) && Self.ioscTouchReplacesPointer { return }
        guard inputConnected else { cancelPendingPress(); longPressFired = false; return }
        if longPressFired { longPressFired = false; return }
        if pendingPress != nil { flushPendingPress() }   // stationary tap = click
        if leftPressSent {
            sendButton(1, false, at: lastTouchPt)
            leftPressSent = false
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if forwardIoscAll(touches, phase: 3, event: event) && Self.ioscTouchReplacesPointer { return }
        cancelPendingPress()
        longPressFired = false
        if inputConnected && leftPressSent {
            sendButton(1, false, at: lastTouchPt)
            leftPressSent = false
        }
    }

    // MARK: deferred press helpers

    private func cancelPendingPress() {
        pendingPressTimer?.invalidate()
        pendingPressTimer = nil
        pendingPress = nil
    }

    /// Commit the deferred left press at its original point (drag start / tap).
    private func flushPendingPress() {
        guard let p = pendingPress else { return }
        cancelPendingPress()
        sendMotion(p.x, p.y)
        sendButton(1, true, at: (p.x, p.y))
        leftPressSent = true
    }

    private func fireLongPress() {
        guard let p = pendingPress, inputConnected else { cancelPendingPress(); return }
        cancelPendingPress()
        longPressFired = true
        // Physical confirmation the hold promoted (no-op without a Taptic
        // Engine, e.g. iPad 7). Needs native-bundle's committed
        // Sources/SystemIntegration.swift in the target; drop if you don't.
        SystemIntegration.shared.rightClickHaptic()
        // Touch-and-hold = secondary click; GNOME/GTK open their context menus.
        sendMotion(p.x, p.y)
        sendButton(3, true, at: (p.x, p.y))
        sendButton(3, false, at: (p.x, p.y))
    }
```

## 8. Recognizer setup: add after the twoFingerPan block (~XScreen.swift:1330)

```swift
        // Trackpad / Magic-Keyboard two-finger scrolling arrives as scroll
        // events (no touches), which the two-touch pan above never sees; a
        // dedicated recognizer feeds the same handler.
        let wheelPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        wheelPan.allowedScrollTypesMask = .continuous
        wheelPan.allowedTouchTypes = []
        wheelPan.maximumNumberOfTouches = 0
        addGestureRecognizer(wheelPan)
```

## Known interactions / device-validation list

- iosc must land the AXIS decode + the handle_button right-click fix
  (handed to iosc-protocols) before any of this is visible on-device; app
  can ship first (old iosc ignores type 9).
- Kinetic fling is the CLIENT's job (GTK/Qt fling on axis_source=finger +
  axis_stop); the app deliberately does not synthesize momentum deltas, so
  do not add decay timers here or flings double.
- The type-6 wl_touch fan-out is untouched (still additive). GTK apps that
  implement touch long-press menus may show a menu from BOTH paths — same
  pre-existing double-delivery wart as tap (ioscTouchReplacesPointer=false);
  if it bites, that flag is the existing fix, not this patch.
- Validate on device: trackpad scroll direction (translation from scroll
  events honors the system natural-scroll setting; if inverted, flip sign
  only when g.numberOfTouches == 0), wheelPan recognizer actually receiving
  scroll events with allowedTouchTypes = [], pinchZoomGain feel, and the
  0.55s/12pt long-press thresholds.
- handleTwoFingerTap (two-finger tap right-click) is unchanged and now
  actually produces BTN_RIGHT once iosc's handle_button fix lands.

---

# Bonus hunk: AXIS decode for the GNOME flavor (MetaBackendIOS)

gnome-touch-ux Phase 2 item 3. For whoever owns meta-input-ios.c /
meta-virtual-input-device-ios.c (compile-check with build-backend-check.sh;
uses the same private Clutter constructors the file already uses).

## meta-virtual-input-device-ios.c

New vfunc next to notify_button:

```c
static void
meta_virtual_input_device_ios_notify_scroll_continuous (ClutterVirtualInputDevice *virtual_device,
                                                        uint64_t                   time_us,
                                                        double                     dx,
                                                        double                     dy,
                                                        ClutterScrollSource        scroll_source,
                                                        ClutterScrollFinishFlags   finish_flags)
{
  ClutterSeat *seat = clutter_virtual_input_device_get_seat (virtual_device);
  ClutterInputDevice *pointer = clutter_seat_get_pointer (seat);
  graphene_point_t coords = GRAPHENE_POINT_INIT (0.f, 0.f);
  graphene_point_t delta = GRAPHENE_POINT_INIT ((float) dx, (float) dy);
  ClutterModifierType modifiers = 0;
  ClutterEvent *event;

  clutter_seat_query_state (seat, pointer, NULL, &coords, &modifiers);

  event = clutter_event_scroll_smooth_new (CLUTTER_EVENT_NONE, resolve_time (time_us),
                                           pointer, NULL, modifiers, coords,
                                           delta, scroll_source, finish_flags);
  _clutter_event_push (event, FALSE);
}
```

Wire it in class_init (and delete the "scroll ... left unset" comment):

```c
  virtual_input_device_class->notify_scroll_continuous =
    meta_virtual_input_device_ios_notify_scroll_continuous;
```

Check the exact clutter_event_scroll_smooth_new signature against the
mutter 46 tree (clutter/clutter/clutter-event.c) — written from the same
pattern as the motion/button constructors already in this file.

## meta-input-ios.c — new case in on_input_msg (after XIOS_IN_KEY)

```c
    case XIOS_IN_AXIS:
      {
        /* Deltas are 1/256 output px (wl_fixed units); the stage wants logical
         * px. state bit0 = fingers left the glass -> finish flags so Clutter
         * kinetic scrolling flings. mods bit1 = latch ctrl around the frame
         * (pinch app-zoom). */
        double scale = xios_output_scale ();
        ClutterScrollFinishFlags finish = (m->state & 1)
          ? (CLUTTER_SCROLL_FINISHED_HORIZONTAL | CLUTTER_SCROLL_FINISHED_VERTICAL)
          : CLUTTER_SCROLL_FINISHED_NONE;

        if (scale <= 0.0)
          scale = 1.0;
        if (m->mods & 2)
          clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                      CLUTTER_CURRENT_TIME,
                                                      0xffe3 /* XK_Control_L */,
                                                      CLUTTER_KEY_STATE_PRESSED);
        clutter_virtual_input_device_notify_scroll_continuous (
          input->pointer, CLUTTER_CURRENT_TIME,
          m->x / (256.0 * scale), m->y / (256.0 * scale),
          m->code == 1 ? CLUTTER_SCROLL_SOURCE_WHEEL
                       : CLUTTER_SCROLL_SOURCE_FINGER,
          finish);
        if (m->mods & 2)
          clutter_virtual_input_device_notify_keyval (input->keyboard,
                                                      CLUTTER_CURRENT_TIME,
                                                      0xffe3 /* XK_Control_L */,
                                                      CLUTTER_KEY_STATE_RELEASED);
        break;
      }
```
