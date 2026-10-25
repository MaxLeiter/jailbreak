# polish: the smaller integration tracks

Small tracks that do not need a full-time owner. Most have landed; what is left is
mostly physical checks a human has to do on the iPad. All input and
system-integration records are the 32-byte `xios_msg` from
`apps/shared/XiosProtocol.h` (`XIOS_IN_*` from 0x100). The old small type numbers
(AXIS 9, OUTPUT 10, HAPTIC 11, ...) and the 24-byte record are gone.

## Status at a glance (2026-10-25)

| Track | State | Still open |
|---|---|---|
| Scroll and gestures | landed in Xios, iosc-host, iosc and Mutter | physical feel of two-finger scroll, long-press right-click |
| Clipboard | landed both sides, per-slot socket | UIKit pasteboard round trip on device |
| Rotation | landed and device-checked | portrait shell layout |
| Volume, dark mode | landed (`xios-sysintd`) | none known |
| Brightness | landed, device-checked through powerdevil | Plasma brightness applet still excluded |
| Haptics | landed (broadcast plus UIKit feedback) | nobody has felt it (the iPad 7 has no Taptic Engine) |
| AT-SPI to VoiceOver | `xios-a11y-tools 0.2.17` | physical VoiceOver gestures, GTK widget trees |
| Desktop audio and mic | `xios-audio-server 0.1.2`, `xios-media-server 0.1.1`, PulseAudio 17 | camera for GNOME apps |
| gsd power/sound/datetime | still dropped from `gnome-settings-daemon` | low priority |

## Scroll and gestures
- `XIOS_IN_AXIS`: dx/dy in 1/256 output-pixel fixed point, source finger or wheel,
  an axis-stop bit for kinetic scrolling. iosc turns it into `wl_pointer.axis`;
  Mutter uses `notify_scroll_continuous`. The Xios app and iosc-host both send
  continuous trackpad frames and discrete wheel frames.
- Pinch is app zoom only (the old ctrl+scroll pinch path is gone).

## Clipboard
- Compositor half: `wayland/iosc-clipboard-bridge.c`, built into iosc, on a
  dedicated per-slot socket the compositor advertises in its config
  (`clipboard_socket`). Mutter has its own strict v1 bridge
  (`wayland/meta-clipboard-ios.c`). `wlr-data-control` feeds the same selection
  store, so `wl-copy`/`wl-paste` work without focus.
- App half: `apps/Xios/Sources/IoscClipboard.c` plus the pasteboard logic in
  `XScreen.swift`, all off the main thread since 2026-10-01.
- The Wayland side is proven (`wl-copy --foreground` then `wl-paste` returned the
  text). The iOS pasteboard leg has no recorded device run. Design, wire and test
  recipe: `../clipboard-plan.md`.

## Rotation
- The app allows all orientations on iosc and sends `XIOS_IN_OUTPUT` on
  orientation, layout and adopt changes, and again after a compositor reconnect.
  iosc reallocates the output IOSurface, rebinds GL, resends `wl_output` and
  `xdg_output`, and the app re-adopts. Device check: default 1440x1080 logical
  became 1080x1440 logical, a 2160x2880 surface.

## Volume, appearance, brightness, haptics
- `xios-sysintd` (`wayland/xios-sysintd.c`, shipped in `xios-session-stubs`) takes
  VOLUME and APPEARANCE so the compositor stays out of audio and theme. App volume
  sets the `xios` sink; desktop volume goes back to the app, which sets iOS
  hardware volume. Appearance sets `color-scheme` (and the GTK3 theme unless
  `XIOS_SYSINT_NO_GTK3=1`).
- **Brightness:** `BKSDisplayBrightnessSet` is inert on iPadOS 17.6.1 outside
  SpringBoard (symbols resolve, the transaction creates, the entitlement is there,
  and `GetCurrent` never moves). Only an app's `UIScreen.brightness` works, so a
  write to the synthetic backlight node goes `xios-hwbridged` to `xios-sysintd`
  (`XIOS_IN_BRIGHTNESS`) to the Xios app (`a6a821b6`, 2026-07-29). Verified
  through powerdevil's D-Bus interface: 400, 850, 250 and 1000 each reached the
  panel and stuck. Reads still come from `GetCurrent`. The Plasma brightness
  applet is still left out of `plasma-workspace`, and the comment in
  `linux-build/recipes/plasma-workspace-ios-fixes.sh` still says the panel hop is
  missing; that is now out of date.
- Second landmine on the same path: `g_file_monitor_directory()` on iOS returns a
  monitor that never reports, so `xios-hwbridged` polls the node at 2 Hz and
  treats any value it did not write as a request (`xios-fhs 1.0.3`).
- HAPTIC: pointer or touch down on shell/layer UI broadcasts a record to input
  clients and the app fires UIKit feedback.
- Helpers (`xios-hwbridged`, `xios-sensord`, `xios-sysintd`) start per session
  bus; see `session-launcher.md` for who starts them.

## AT-SPI to VoiceOver
- Xios sends `A11Y_STATE\t1|0` to ioscd when VoiceOver changes; ioscd owns
  `/var/jb/tmp/xios-a11y-enabled`. Launchers enable AT-SPI when that file,
  `/var/jb/tmp/xios-a11y-force`, or `XIOS_ENABLE_A11Y=1` is present; otherwise apps
  run with `GTK_A11Y=none`.
- `xios-a11yd` publishes diff-suppressed NDJSON snapshots on
  `/var/jb/tmp/xios-a11y.sock` (mobile 0660) and routes activate, adjust, scroll
  and `vo-focus` back through AT-SPI. Both the desktop app (`XiosA11y.swift`) and
  the native host (`HostA11y.swift`) publish the elements.
- Device smokes saw the trees and published elements. Qt (Okular) exposes a rich
  tree; GTK4 apps expose mostly frames and panels. Real VoiceOver gestures are not
  validated. Design and the authoritative wire schema: `../a11y-plan.md`.

## Desktop audio and media
- PulseAudio 17 with sink `xios` (`module-xios-sink` to `xios-audiod`) and source
  `xios_mic` (`module-xios-source` to `xios-mediad`); device smoke saw both as
  defaults and recorded from the mic.
- `xios-audio-server 0.1.2` keeps the output open only while something plays (the
  old always-open output kept the iPad from sleeping). `xios-media-server 0.1.1`
  opens the mic only while a client is connected.
- Camera: the raw broker path exists, but AVFoundation refused both cameras from
  the daemon in the 2026-07-04 smoke, and there is no PipeWire, GStreamer or
  xdg-desktop-portal on the device. The next real step is app-brokered frames
  exported as a portal camera or a GStreamer source. Details:
  `../audio-desktop-plan.md`.

## gsd plugins
- `gnome-settings-daemon 46.0+ios1` is a minimal build (a11y-settings,
  housekeeping, keyboard, screensaver-proxy). GNOME's battery indicator reads
  UPower from `xios-hwbridged`, so power works without gsd-power. Sound (event
  sounds) and datetime are low priority and not started.
