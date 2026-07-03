# polish — smaller feature tracks (one agent could own several)

These are the smaller, mostly-landed-or-parked tracks. Each has a wire type or a plan already; grouped here since none is a full-time domain. Split further if you want dedicated owners.

## Touch scroll + gestures (task #20)
- AXIS wire type 9 landed (iosc decode + Xios `sendScroll`, commit 3ebf085; also fixed BTN_LEFT right-click). Mutter half: `notify_scroll_continuous` + AXIS in virtual-input (build10).
- Wire (xios_input_socket.h): AXIS x,y = dx,dy in 1/256 output-px fixed point; code=source(0 finger/1 wheel); state bit0=axis_stop; mods=modifier mask (ctrl = pinch-zoom).
- Current Xios app uses the unified fit transform, so the old stale-fb warning is closed. Open: two-finger scroll feel, long-press right-click, pinch-zoom (ctrl+scroll) end-to-end on-device across iosc and Mutter. Handoff detail: `x11/docs/axis-gestures-handoff.md`.

## Clipboard sync Linux↔iOS (task #18)
- App side and compositor side have both landed on the 32-byte `XMS1` envelope (`XIOS_MSG_CLIPBOARD` 0x04); the old 8-byte clipboard bridge framing is obsolete. Treat this as co-deploy/verify work: Xios.app and iosc must be from the same wire generation. Memory: x11-clipboard-sync.
- Open: on-device bidirectional smoke (UIKit pasteboard -> wl-copy/GTK, wl-copy/GTK -> UIKit pasteboard), large payload behavior, and multi-item/type coverage beyond text.

## Rotation (task #21)
- XIOS_IN_OUTPUT wire type 10 registered (code = wl_output transform; x,y = requested logical WxH). Rotation = resize + present-reconnect.
- Held (per native-bundle) because iosc doesn't reconfigure its output IOSurface on rotation yet — allowing portrait today just letterboxes. Two halves: iosc reconfigure the output surface on rotate (iosc-compositor.md) + Xios update drawableSize/re-fit on orientation change (xios-app.md #6). Xios build is currently landscape-LOCKED (Info.plist). Unlock is coordinated across xios-app + iosc + native-bundle. Plan: `x11/docs/native-feel-plan.md`.

## Native-feel bundle (tasks #22, #23) — volume / dark-mode / haptics
- Wire types 10-13 (OUTPUT/HAPTIC/VOLUME/APPEARANCE) registered. VOLUME(12)+APPEARANCE(13) go to a separate `xios-sysintd` daemon (socket `/var/jb/tmp/xios-sysint.sock`, same framing) so the compositor stays out of audio/theme. `xios-sysintd`, Xios volume/appearance/output senders, and Xios haptic receiver code exist; `run-gnome-shell.sh` starts `xios-sysintd` when installed. Remaining compositor-side work: handle OUTPUT(10) in iosc for rotation/reconfigure and broadcast HAPTIC(11) to input clients. (A volume HUD was seen working on-device.) Plan: `x11/docs/native-feel-plan.md`. Memory: x11-native-feel-bundle.

## AT-SPI → VoiceOver a11y bridge
- Design committed `x11/docs/a11y-plan.md`; native-flavor half `x11/docs/native-ipados-a11y.md` (HostA11y.swift inert until an xios-a11yd). Wire schema is the authoritative NDJSON schema in that doc. qtbase bridge blocked on FEATURE_dbus (fold into a Qt round-2 with printsupport). GTK3 atk-bridge compiled out → rebuild needed. Memory: x11-a11y-voiceover-bridge.

## gsd plugins (tasks #15, #25, #26)
- #15 power: un-drop + Darwin backlight backend (brightness slider); gsd-power backlight is Darwin-ifdef'd-out → needs a 2-file backend, no udev/logind. Pairs with `packages/xios-fhs` xios-hwbridged (UPower D-Bus shim via IOKit IOPS — closes the battery indicator; synthetic /var/jb/sys backlight + BKS brightness). Memory: x11-fhs-hwbridge.
- #25 sound: event sounds + volume feedback via PA. #26 datetime: iOS timezone + simple NTP (low priority).

## Audio (deferred)
- Real PulseAudio 17 daemon w/ timer-clocked module-xios-sink built (17.0-1 debs) for gvc/GTK apps; PULSE_SERVER=unix:/var/jb/tmp/pulse/native. Not device-coherence-tested post-boot. Memory: x11-audio-on-device.
