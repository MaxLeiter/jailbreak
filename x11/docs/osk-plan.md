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
   socket (`iosc-input.sock` for classic, `iosc-native-input.sock` for native)
   to every connected host:
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
user-dismiss latch keys off dismiss-key resigns (no chrome button, no
toggle method), and because TRAITS are not window-scoped yet (XIOS_IN_BIND still
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
- GNOME Shell flavor: BOTH mechanisms are wired now. The shell's own OSK
  (`js/ui/keyboard.js`) is force-enabled via
  `org.gnome.desktop.a11y.applications screen-keyboard-enabled=true`, and
  mutter also broadcasts TRAITS: patches/mutter/meta-wayland-text-input-osk-ios.patch
  hooks meta-wayland-text-input.c and is applied unconditionally by
  integrate-ios-backend.sh. That supersedes gnome-touch-ux.md Phase 3's
  "recommendation: no"; if the two OSKs do fight on device, drop the
  gsetting rather than the patch (mutter is the root compositor there and
  owns the input socket, so the TRAITS half is the cheap one to keep).
- KDE Plasma flavors: nothing today, and the mutter patch does NOT port.
  See "KDE flavor" below for why and for the bridge that does work.

## KDE flavor: a zwp_input_method_v1 bridge (landed in source, cross-built)

Investigated 2026-07-29 by reading the kwin 6.1.5 sources (the version
recipes/kf6-common.mk pins), not from memory. Every claim below has a
file:line in that tarball. Status: all three pieces are implemented and
build clean for arm64 (build-iosc.sh, 0 errors); NOT yet device-tested, so
treat the end-to-end behaviour as unproven. What that test looks like is in
"Open items".

### Why the mutter patch does not port

- Topology: kwin_wayland runs NESTED as an iosc client (run-kde-plasma.sh
  header; kwin-ios-fixes.sh only builds the `wayland` + `fakeinput`
  backends). iosc stays the root compositor and owns the Xios input socket.
- `input_clients_send_traits()` derives everything from
  `text_input_for_focus()`, which walks iosc's OWN text-input-v3 clients.
  iosc's client is kwin_wayland, and KWin's nested backend is not a
  text-input client (no text-input code in any KWin recipe). So `ti == NULL`
  forever, the broadcast is a constant {0,0,0}, and the app never auto-pops.
- Same root cause caps typing: `in_dispatch_text()` falls back to per-byte
  keysyms below 0x80 when `text_input_commit_text()` returns 0. Plasma apps
  get ASCII keys and none of the iOS input stack.
- KDE has no OSK of its own either: no `kwinrc` InputMethod key anywhere in
  the tree, no ios-inputd in run-kde-plasma.sh or xios-session-lib.sh, and
  plasma-mobile's virtual-keyboard-toggle dependency was demoted to
  OPTIONAL. So unlike GNOME there is no two-OSK fight to weigh; the iOS
  keyboard is the only candidate.

### What KWin 6.1.5 actually implements

| fact | where (kwin-6.1.5) |
|---|---|
| `input-method-unstable-v1` + `input-panel-v1`. NO input-method-v2, NO virtual-keyboard-v1 anywhere | src/wayland/CMakeLists.txt protocol list; inputmethod_v1.h:36; wayland_server.cpp:480 |
| both IM globals are filtered to the IM connection only | wayland_server.cpp:133 + allowInterface() :151 |
| that connection is a private socketpair passed to a KWin-spawned child as `WAYLAND_SOCKET` | inputmethod.cpp:880 (startInputMethod) |
| launch hooks: `kwin_wayland --inputmethod <cmd>`, or `kwinrc [Wayland] InputMethod=<desktop>` | main_wayland.cpp:388/636/203; :190 |
| `VirtualKeyboardEnabled` defaults TRUE, so no config gate | inputmethod.cpp:89 |
| activate/deactivate follow text-input focus with NO touch-mode gate; `shouldShowOnActive()` only gates showing a panel window | inputmethod.cpp:210 (setActive), :185 |
| panel-less input methods are an explicitly supported case | inputmethod.cpp:158 (show(), `!m_panel` branch) |
| content_type + surrounding_text sent on activation and re-sent on change; v1/v2/v3 all fold into one context | inputmethod.cpp:774 (adoptInputMethodContext), :321 |
| return path complete: commit_string, preedit_string, keysym, key, delete_surrounding_text | inputmethod_v1.cpp:86-144, forwarded at inputmethod.cpp:550/520/745/596 |

Consequences: **ios-inputd as written is dead on KWin.** It binds
`zwp_input_method_v2` + `zwp_virtual_keyboard_v1`, prints its two
"compositor has no ..." warnings and does nothing. (gnome-touch-ux.md used
to call those "wlroots/KWin protocols"; that is wlroots-only, corrected
there now.) The bridge must speak v1 and must be spawned by KWin. The
missing virtual-keyboard-v1 costs nothing: `context.keysym` covers
Backspace/Enter/arrows and `commit_string` covers full Unicode, which is
strictly better than today's ASCII keysym fallback.

### Shape of the bridge (as built)

1. ios-inputd grew a second mode. It now binds `zwp_input_method_v1` when the
   compositor advertises it and switches to PROXY mode; the old wlroots
   ROOT mode (input-method-v2 + virtual-keyboard-v1, listen on the input
   socket) is untouched and still selected when only v2 is present. KWin
   launches it (`--inputmethod` in run-kde-plasma.sh, gated on
   `KDE_AUTO_KEYBOARD=1` and the binary existing) and it inherits
   `WAYLAND_SOCKET`, which `wl_display_connect(NULL)` already honored.
   In PROXY mode it takes only TEXT from iosc: pointer/keyboard/touch already
   reach KWin through iosc's wl_seat, and injecting them again would double
   every keystroke.
2. An "IM proxy" role on iosc's input socket (`XIOS_IN_IMPROXY`, type 14),
   so traits reach the app without touching the frozen app-side contract.
   The proxy connects as a client and registers; from then on the reader
   excludes it from broadcasts, honors ONLY its inbound `XIOS_IN_TRAITS`
   (a display host cannot spoof the OSK), and iosc routes `XIOS_IN_TEXT` to
   it via `xios_input_socket_send_improxy()` instead of the local commit,
   falling back to the old path when no proxy is registered.
   `input_clients_send_traits()` prefers the latched proxy values.
   Xios/XScreen.swift and HostScreenView.swift needed ZERO changes.
   Two failure modes are handled explicitly: the proxy vanishing (KWin exit
   or crash) clears the latch and pushes one last disable, so a keyboard
   raised for a field that no longer exists still comes down
   (`xios_input_socket_has_improxy()`, polled after dispatch); and a wedged
   proxy is de-registered on write failure so text falls back locally
   instead of vanishing into a dead socket.
3. Enum translation in the bridge (`v1_purpose_to_v3` in ios-inputd.c),
   because KWin converts down to
   text-input-v1 numbering (inputmethod_v1.cpp sendContentType). Hint bits
   are numerically identical to v3 (0x1..0x200), except v1's 0x2 is
   `auto_correction` where v3 calls it `spellcheck`. Purposes agree 0-8 and
   then shift:

   | value | v1 | v3 (what XScreen.swift expects) |
   |---|---|---|
   | 9  | date     | **pin** |
   | 10 | time     | date |
   | 11 | datetime | time |
   | 12 | terminal | datetime |
   | 13 | -        | **terminal** |

   Map v1 -> v3 before packing TRAITS so the app's table stays frozen.
   PIN fidelity is lost for good: v1 has no `pin` purpose and KWin's switch
   has no `Pin` case, so a v3 PIN field arrives as `normal(0)`. The
   hidden_text/sensitive_data hints still arrive, so secure entry survives,
   just not the number pad.

Rejected alternatives: patching KWin's text-input path like mutter's (same
iosc change, one more patch on an already 27-deep stack, no typing fix);
building maliit or qtvirtualkeyboard as the KDE OSK (no wire work, but two
new Qt/QML ports and it gives up autocorrect/dictation and the native feel).

### Device run 2026-07-29: BOTH DIRECTIONS VERIFIED

Ran on MaxsiPad with the KDE preset (hand-run run-kde-plasma.sh with IOSC_BIN
and IOS_INPUTD_BIN pointed at a staged build in /var/jb/tmp/osk-test, so the
installed iosc package was never touched -- another session was working the
same device).

Traits direction:

- KWin really does hand its IM child zwp_input_method_v1: "ios-inputd:
  zwp_input_method_v1 present -> proxy mode" plus "registered as input-method
  proxy on .../iosc-input.sock".
- konsole taking text-input focus logged "ios-inputd: traits enable
  hint=0x0 purpose=0", iosc logged "TRAITS from improxy ... enabled=0/1", and
  the iOS keyboard rose (confirmed visually by Max).

Typing direction, end to end:

- `iosc: TEXT 55 bytes -> improxy=1 (0 = local fallback)`
- `ios-inputd: commit_string 55 bytes (serial 2)`
- the shell in konsole then wrote `héllo-ünïcode-😀` to a file, accents and
  emoji intact. That is only reachable through commit_string: the keysym
  fallback drops every byte >= 0x80.

MISDIAGNOSIS WORTH REMEMBERING: two earlier attempts at the typing test came
back ASCII-only ("hllo-ncode") and looked like the routing was falling back.
The cause was the test tool. `iosc-input-test`'s bare `text...` mode taps ONE
KEYSYM PER BYTE and cannot carry anything but ASCII; it never sent an
XIOS_IN_TEXT record at all, so iosc's routing was never exercised. Fixed by
adding `-T utf8...` to iosc-input-test, which sends the real record. (A
concurrent session downgrading the device to iosc 0.9.27 mid-test muddied the
water further, but it was not the cause.) Use `-T` for anything about text
input; the ASCII mode is for keyboard dispatch only.

Two bugs the run did find, both fixed:

- ios-inputd's ROOT mode unlinked and rebound the socket path it was given.
  Under KDE that path is iosc's own input socket, so a mode misdetection
  silently stole every pointer and keystroke in the session (the Xios app
  reconnects to the bridge instead of the compositor). Now: --proxy (implied
  by WAYLAND_SOCKET, i.e. by being launched as somebody's input method)
  refuses to fall back, and ROOT mode probes the path first and refuses to
  take over a live socket.
- KWin's kwinrc watcher calls setInputMethodCommand with whatever
  [Wayland] InputMethod holds; empty means STOP the input method and destroy
  the connection that is allowed to bind zwp_input_method_v1, which races the
  child KWin just launched and disables the auto keyboard for that session.
  run-kde-plasma.sh now publishes the identical command in kwinrc (plus a
  .desktop for it), so that callback is a no-op.

Host-side regression check for the socket role (registration, TRAITS honoured
only from the proxy, TEXT routing, broadcast exclusion, proxy-loss): compiles
and passes on macOS against xios_input_socket.c directly. NOTE for whoever
writes the next one: the reader registers a client on its kqueue during
accept, so that client's first records only arrive on a LATER dispatch call.
A single dispatch after connecting reads nothing, which reads exactly like a
broken feature.

### Open items

- Both directions are verified on device (see above). What is still open:
  a real user pass with the iOS keyboard itself rather than injected records
  (autocorrect replacements, dictation, the split/floating keyboard), and a
  check that the hide path behaves when focus leaves a field. ios-inputd logs
  to KWin's stderr, so the KDE session log carries "proxy mode" and
  "registered as input-method proxy"; `KDE_AUTO_KEYBOARD=0` turns the whole
  thing off for A/B.
- SHIPPING: iosc 0.9.30 is packaged (rebased on 0.9.29). run-kde-plasma.sh
  ships in the xios-session package, NOT iosc, so that package needs a bump
  too or KWin never launches the bridge on an installed system.
- Confirmed source-side that our kwin deb has the globals:
  src/wayland/CMakeLists.txt:284 lists inputmethod_v1.cpp unconditionally and
  kwin-ios-fixes.sh only appends to that file. Still worth one
  `WAYLAND_DEBUG=1` check on device.
- Occlusion is still the shared v2 gap: the iOS keyboard overlays the Metal
  layer and nothing pans the focused field, same as every other flavor.
- Upstream bug worth knowing (not ours to hit): adoptInputMethodContext()
  inputmethod.cpp:785 pairs `t1->contentHints()` with `t2->contentPurpose()`
  in the text-input-v1 branch. Qt and GTK use v2/v3, so it stays cold.

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
| GNOME TRAITS broadcast                  | linux-build/patches/mutter/meta-wayland-text-input-osk-ios.patch | landed (applied by integrate-ios-backend.sh) |
| KDE bridge, IM-proxy socket role        | wayland/xios_input_socket.{c,h} (XIOS_IN_IMPROXY, _send_improxy, _has_improxy) + xios-glue-stub.h twin | built clean, not device-tested |
| KDE bridge, iosc side                   | wayland/iosc.c (proxy traits latch, TEXT routing, disable-on-proxy-loss) | built clean, not device-tested |
| KDE bridge, input-method-v1 client      | wayland/ios-inputd.c proxy mode + protocols/input-method-unstable-v1.xml + build-iosc.sh | built clean, not device-tested |
| KDE bridge, launch hook                 | wayland/run-kde-plasma.sh (`--inputmethod`, KDE_AUTO_KEYBOARD) | not device-tested |
