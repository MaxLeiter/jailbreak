# Auto keyboard: Wayland text-input-v3 to the iOS keyboard

Goal: tap a text field in any Linux app and the iPad keyboard slides up,
already in the right layout (number pad for a PIN field, URL keyboard in a
browser bar, secure entry for passwords). Tap elsewhere and it slides down.
Typing lands in the focused field with full UTF-8 (autocorrect, emoji,
dictation). Status 2026-07-01: the signal chain and the typing path are live;
the missing piece is the responder policy that actually raises and lowers the
keyboard, specified here.

## Signal chain (already built, commits 2a03a5c + b818503)

1. The toolkit focuses an editable: GTK/Qt send `zwp_text_input_v3.enable` +
   `set_content_type(hint, purpose)` + `commit`. iosc implements
   text-input-manager-v3 (iosc.c, "text input" section).
2. iosc tracks per-client text-input state. Every `text_input.commit` and
   every keyboard-focus change calls `input_clients_send_traits()`
   (iosc.c:4763), which broadcasts one fixed 24-byte record on the app input
   socket (`iosc-input.sock`) to every connected host:
   `XIOS_IN_TRAITS { code = content_hint, state = content_purpose,
   mods = enabled }`. New connections get a snapshot on connect.
3. The host app polls the socket every display-link tick.
   - Xios (shared-desktop flavors): `XScreen.swift
     serviceIoscInputTraits()` -> `applyIoscInputTraits()`.
   - iosc-host (native per-window flavor): `HostScreenView.swift
     serviceTraits()` -> `applyTraits()` on its per-window connection.
   Both map the traits onto `UITextInputTraits`:

   | content_purpose        | UIKeyboardType            | extra                    |
   |------------------------|---------------------------|--------------------------|
   | digits(2), pin(9)      | .numberPad                | pin also secure          |
   | number(3)              | .numbersAndPunctuation    |                          |
   | phone(4)               | .phonePad                 |                          |
   | url(5)                 | .URL                      | returnKey .go            |
   | email(6)               | .emailAddress             |                          |
   | password(8)            | .asciiCapable             | isSecureTextEntry        |
   | terminal(13)           | .asciiCapable             | no autocorrect/spelling  |
   | others                 | .default                  |                          |

   Hint bits drive autocorrection (0x1), spellchecking (0x2), the three
   capitalization modes (0x4/0x10/0x20), secure entry (0x40 hidden_text,
   0x80 sensitive_data) and returnKey (0x200 multiline).
4. Return path (typing): the view is a `UIKeyInput` responder.
   `insertText` -> `XIOS_IN_TEXT` -> iosc `text_input_commit_text()` ->
   `commit_string` into the focused field. `deleteBackward` -> XK_BackSpace
   as a KEY record. Because text goes through text-input rather than
   synthesized keysyms, the full iOS input stack works: autocorrect
   replacements, emoji, dictation. `virtual-keyboard-v1` is NOT part of this
   path; it stays for external IM daemons (ios-inputd) and terminals get
   ASCII fallback via keysyms when a client has no text-input.

Design decision, record framing: no new KEYBOARD record on the typed
app-socket framing (`iosc_native_proto.h` HELLO/DIRTY/CURSOR). The show/hide
signal already rides the input socket as TRAITS, both hosts already parse it,
and the input socket is the one channel every flavor host keeps open. The
typed app socket stays presentation-only. iosc.c needs no changes for v1.

## The gap: nobody raises the keyboard

`applyIoscInputTraits`/`applyTraits` reconfigure the traits but only call
`reloadInputViews()` if the view is ALREADY first responder. The keyboard
only ever appears through the manual toggle button. Two changes close this.

### 1. Per-record TRAITS poll (IoscInput.c, both copies) [DONE]

`iosc_input_poll_traits()` used to drain the socket and return only the
newest values. A focus hop between two fields is a disable broadcast followed
by an enable broadcast; when both landed in one tick the disable vanished,
and with it the transition the responder policy keys off. Worse, a
disable+enable pair with identical traits coalesced into "no change at all".
Fixed: the poll returns after each complete TRAITS record (1 = one record
filled, call again; 0 = nothing pending; -1 = disconnected).

### 2. Responder policy (XScreen.swift; HostScreenView.swift follow-up)

Rules, in order of intent:

- TRAITS enable raises the keyboard; TRAITS disable lowers it.
- The manual toggle stays user-owned: a keyboard the USER opened is never
  auto-hidden, and a keyboard the user dismissed (toggle or the iPad
  dismiss key) is not re-raised until focus leaves that field and returns.
- Focus hops (field A -> field B: disable then enable back to back) must not
  bounce the keyboard, so the hide is debounced by 200 ms and an enable
  cancels a pending hide.

State: `oskAutoShown` (the auto path raised it), `oskUserDismissed` (user
hid it while the field was still enabled; cleared when the field disables or
the user reopens), `oskProgrammaticResign` (distinguishes our resign from the
user's inside the `resignFirstResponder` override), `oskHideTimer`.

The policy hook runs on EVERY received record, before the value-change guard
in `applyIoscInputTraits`: an identical re-broadcast (iosc broadcasts on
every text-input commit, e.g. a caret move in the same field) must still
cancel a pending hide.

Exact code for XScreen.swift (owner: xios-app, folds into the current
rebuild; also sent by message):

```swift
// state (next to lastIoscTrait*)
private var oskAutoShown = false          // the auto path raised the keyboard
private var oskUserDismissed = false      // user hid it while the field was still enabled
private var oskProgrammaticResign = false // our resign vs the user's
private var oskHideTimer: Timer?

private func serviceIoscInputTraits() {
    guard usingIosc, inputConnected, iosc_input_is_open() else {
        applyIoscInputTraits(hint: 0, purpose: 0, enabled: 0)
        return
    }
    // poll_traits now returns one record per call; drain them all so every
    // enable/disable transition reaches the responder policy.
    while true {
        var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
        let r = iosc_input_poll_traits(&hint, &purpose, &enabled)
        if r < 0 { inputConnected = false; writeStatus(); return }
        if r == 0 { return }
        applyIoscInputTraits(hint: hint, purpose: purpose, enabled: enabled)
    }
}

private func applyIoscInputTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
    updateAutoKeyboard(enabled: enabled != 0)   // before the guard: see osk-plan.md
    guard hint != lastIoscTraitHint || purpose != lastIoscTraitPurpose ||
          enabled != lastIoscTraitEnabled else { return }
    // ... rest unchanged ...
}

// The responder half of the auto keyboard (design: x11/docs/osk-plan.md).
private func updateAutoKeyboard(enabled: Bool) {
    if enabled {
        oskHideTimer?.invalidate()
        oskHideTimer = nil
        if !isFirstResponder && !oskUserDismissed {
            if becomeFirstResponder() { oskAutoShown = true }
        }
    } else {
        oskUserDismissed = false   // focus left the field; the next enable may raise again
        guard oskAutoShown, oskHideTimer == nil else { return }
        // Debounce: a focus hop between two fields is disable then enable
        // back to back; don't slide the keyboard down for the gap.
        oskHideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.oskHideTimer = nil
            guard self.oskAutoShown else { return }
            self.oskProgrammaticResign = true
            _ = self.resignFirstResponder()
            self.oskProgrammaticResign = false
            self.oskAutoShown = false
        }
    }
}

override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok {
        keyboardButton?.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.7)
        oskUserDismissed = false
    }
    return ok
}
override func resignFirstResponder() -> Bool {
    let ok = super.resignFirstResponder()
    if ok {
        keyboardButton?.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        if !oskProgrammaticResign {
            // The user hid the keyboard (toggle or dismiss key) while the field
            // may still be focused: don't fight them on the next broadcast.
            if lastIoscTraitEnabled != 0 { oskUserDismissed = true }
            oskAutoShown = false
        }
    }
    return ok
}
```

HostScreenView.swift carries the same policy against its `applyTraits`
(landed, built clean via build-host.sh), with two host-specific twists: the
user-dismiss latch keys off toggleKeyboard/dismiss-key resigns (no chrome
button), and because TRAITS are not window-scoped yet (XIOS_IN_BIND still
proposed), every scene hears every broadcast, so the auto-pop is gated on
`window?.isKeyWindow` and only the scene the user is in raises the
keyboard. When BIND lands in iosc's reader, drop the gate in favor of
per-window routing.

## Server-side contract (for the iosc maintainer)

Frozen, the app relies on it:

- TRAITS broadcast on every `text_input.commit` and every keyboard-focus
  change, INCLUDING when the values did not change. Do not dedupe
  server-side: repeat broadcasts are what cancel a pending hide during
  same-field commits, and the caret-move commits are the future v2 signal.
- Field packing stays `code = content_hint, state = content_purpose,
  mods = enabled(0/1)`.
- Snapshot to every new input-socket client (already done via the
  client-count check in `input_sock_readable`).

## v2: keyboard occlusion (deferred)

When the keyboard is up it covers the bottom half of the output and can
cover the focused field itself. The pieces already exist:

- Clients send `set_cursor_rectangle`; iosc stores it (`ti->rect_*`) and
  today forwards it only to input-method popups. Broadcast note: those
  rects are surface-local LOGICAL coords; iosc converts to physical output
  px (x output_scale, + surface dx/dy, same as the cursor-overlay coords)
  before sending. The iosc maintainer offered to wire that half when v2
  starts (confirmed 2026-07-01; server contract pinned in 23d70ef).
- v1.5 (app-only, no protocol change): the Xios app already has pan/zoom
  machinery (`panOffset`/`zoomScale`). On keyboardWillShow, if the last
  known caret rect is under the keyboard frame, pan the view up; restore on
  hide. Needs iosc to broadcast the caret rect: one new record
  `XIOS_IN_CARET { x, y, code=w, state=h }` in output pixels, sent on the
  same commits as TRAITS. Additive, old apps ignore unknown types.
  Numbering note: this is the INPUT socket's XIOS_IN_* space (24-byte
  records; next free type is 8), NOT the typed app-socket xios_msg core
  range (32-byte records, where CLIPBOARD took 0x04 and 0x05-0x0f remain;
  see clipboard-plan.md). iosc-protocols owns allocations in both spaces.
- v2 (compositor-assisted): report the keyboard's occluded height to iosc
  (new app->server record) and let iosc scroll/resize the focused toplevel
  like a layer-shell exclusive zone. Better for the shell flavor; do it
  when the iosc shell panel work needs the same plumbing.

Do not build either until first-pixels UX shows which one the desktop needs.

## Flavor matrix (who shows which keyboard)

- iosc shell + native iPadOS flavor: THIS bridge; the iOS keyboard is the
  only OSK. Best tablet UX (autocorrect, emoji, dictation, split/floating).
- GNOME Shell flavor: the shell's own OSK (`js/ui/keyboard.js`), decision
  and reasons in gnome-touch-ux.md Phase 3: the shell OSK resizes the stage
  and scrolls the focused field into view, while the iOS keyboard would
  overlay the Metal layer with no scroll-into-view; two OSKs fighting is
  worse than one consistent one. Force-enable it via
  `org.gnome.desktop.a11y.applications screen-keyboard-enabled=true`.
  Revisit only after v2 occlusion handling exists.
- KDE Plasma Mobile flavor: decide when it boots; candidates are maliit
  (Plasma's own OSK, heavy) or mirroring the TRAITS broadcast from kwin.

## Landing map

| piece                                   | file(s)                                   | status |
|-----------------------------------------|-------------------------------------------|--------|
| text-input-v3 + TRAITS broadcast        | wayland/iosc.c                            | landed (b818503); no v1 changes needed |
| traits -> UITextInputTraits mapping     | apps/Xios/Sources/XScreen.swift, apps/iosc-host/Sources/HostScreenView.swift | landed |
| typing return path (UIKeyInput -> TEXT) | apps/Xios/Sources/XScreen.swift           | landed |
| per-record TRAITS poll                  | apps/Xios/Sources/IoscInput.c, apps/iosc-host/Sources/IoscInput.c | landed (b80cd60) |
| responder policy (auto pop/hide)        | apps/Xios/Sources/XScreen.swift           | landed (6f51c1e, xios-app); staged, awaiting batched redeploy |
| responder policy, native host           | apps/iosc-host/Sources/HostScreenView.swift | landed (key-window gated); builds clean |
| server contract pinned in code          | wayland/iosc.c input_clients_send_traits  | landed (23d70ef, comment-only) |
| caret rect / occlusion                  | iosc.c + app                              | deferred (v2) |
