# xios-app: the Xios iOS app (Metal present, input, IOSurface adopt)

The app that puts a compositor's output IOSurface on the iPad through Metal,
streams UIKit touch, Pencil, keyboard and pointer input back over a unix socket,
and hosts the in-app panel (desktop picker, screen size, app launcher). The
per-window native host is a separate app (`apps/iosc-host`, see
`native-ipados.md`).

## Current state (2026-10-25)

- **Published:** `com.max.xios 0.1.12` (indexed 2026-10-05 with the 2026-10-01
  audit rebuild wave). It is a package, pulled in by `xios-core`, so every
  fullscreen flavor (GNOME, KDE, X11, plain iosc) installs it. `xios-native` does
  not.
- **Unpackaged source change:** `86cd0b7f` (2026-10-25) makes the panel say why an
  ioscd request failed (ioscd not running, unreachable, timed out, no reply)
  instead of calling everything a timeout. `project.yml` is still at
  `MARKETING_VERSION 0.1.12`, so it needs a bump before it can ship. The real fix
  for issue #11 was packaging (`xios-core 0.1.12+` depends on
  `xios-launcher-tools` again); see `session-launcher.md`.
- **Works on device:** zero-copy present at `iosurface-zerocopy 2880x2160 [metal]`,
  stream-v2 (three fixed output surfaces plus direct client surfaces), taps and
  typing on iosc, KDE and GNOME, rotation through OUTPUT, desktop switching that
  keeps one app PID, display pacing on vblank, brightness requests applied with
  `UIScreen.brightness` (relayed by `xios-sysintd`).
- **Not proven on device yet:** the full hardware keyboard / mouse / trackpad
  matrix (see open items), the dead-pin release path, physical VoiceOver
  gestures, and the UIKit half of clipboard sync.

### UI as it stands
- Three-finger tap opens the one Xios panel: status card, desktop list, Screen
  Size (Default, Landscape, Portrait, Compact, Custom), Open an App, Stop Desktop,
  Advanced. Advanced holds the display list, Fit/Reload/Reconnect Input, extra
  display slots, Home Screen Apps (ioscd `APPS_*` verbs), the key and click pad,
  and the debug snapshot. There is no four-finger gesture any more.
- Pinch zooms the app view (back out to fit), a one-finger swipe up from the
  lower ~28% raises the iOS keyboard, a pull down from the top edge shows the
  overlay (desktop name, time, battery), which auto-hides after 5s.
- Render Scale (present-side MetalFX) is in the panel and is off by default; see
  below.

## Key files
- `apps/Xios/Sources/XScreen.swift`: the main view. Present (`render()`), one
  shared `FitTransform` for drawing and input, surface adopt and
  `syncSurfaceGeometry(conn)`, config reload (`loadConfig()`), the ~1.5s watchdog
  in `tick()`, the panel, and the ioscd client.
- `XiosShellOverlay.swift`, `XiosDisplayModels.swift`, `XiosSocket.swift`,
  `XiosRuntimePaths.swift`, `XiosUpscale.swift`: panel UI, display/slot models,
  ioscd socket, path helpers, MetalFX.
- `XSurface.c`: the surface client (mach-port IOSurface hand-off, HELLO/DIRTY,
  stream-v2 RELEASED acks).
- `IoscInput.c`, `IoscClipboard.c`, `SysIntClient.c` + `SystemIntegration.swift`:
  input, clipboard, and volume/appearance/brightness/haptics.
- `XiosA11y.swift`: VoiceOver publisher for `xios-a11yd` snapshots.
- `apps/shared/`: `XiosProtocol.h` (the one wire registry: 32-byte `xios_msg`,
  exact v1 HELLO, `XIOS_IN_*` from 0x100, unknown types are fatal),
  `XiosHardwareKeyboard.swift` + `XiosHardwareKeymap.swift` (GCKeyboard HID to
  keysym, shared with iosc-host), `XiosMetalEventBroker` (fence import).
- Build output: `apps/Xios/build/Build/Products/Release-iphoneos/Xios.app`.
  Packaging control: `apps/Xios/packaging/control`.

## Gotchas and landmines

- **App and compositor must be the same wire generation.** The 2026-08-02 "KDE
  taps are dead" hunt was version skew: a stream-v2 app (`caps=0x1`) against
  `iosc 0.9.43` + ANGLE `es3-15`. iosc logged `app client attached ... caps=0x1`
  then `client ... dropped`; the app sat at `holding-frame awaiting iosurface` /
  `input-not-connected` while the desktop looked alive (it holds its last frame,
  and every input path bails at `guard inputConnected`). Fix was installing the
  matching iosc and ANGLE and restarting the session. Check `xios-status.txt` for
  `input-connected` before chasing input bugs.
- **`xios-debug.txt` is written only on demand** (UI actions), so a stale copy
  names dead sockets. Trust `xios-status.txt` (written on every state change) and
  `iosc.log`, and check the debug snapshot's mtime.
- **The scale/tap-offset bug** was a stale zoom factor (about 1.11) surviving an
  adopt that saw no size change, so the desktop overflowed and taps were offset.
  The app now resets zoom on every adopt and refreshes `fbWidth`/`fbHeight` after
  every drain (`syncSurfaceGeometry`). A second HELLO with new geometry is fatal
  and forces a full re-adopt. The coordinate space itself was always right: the
  app sends output-pixel coordinates and iosc divides by `output_scale` once.
- **Session switch and jetsam.** On surface-socket EOF the app releases the old
  IOSurface right away and holds a 1x1 black frame, so it is not pinning ~30 MB
  while the next compositor allocates its own. ioscd requests run off the main
  thread with bounded timeouts (a 2026-07-29 crash was a background-termination
  watchdog on the old synchronous reader, not jetsam). Backgrounding pauses the
  display link and drops surface state; foregrounding reconnects.
- **Pins must die with their display.** A pinned slot that was stopped
  out-of-band used to keep the pin forever. `releasePinIfDisplayGone()` drops it
  after 3 failed polls of the config or socket (`com.max.xios 0.1.11`).
- **Pacing.** The frame rate is a `CAFrameRateRange` set through one
  `setPacingRange()` seam. Keep it a range; that is what a thermal clamp would
  use. The `presentedTime` ack comes from `drawable.addPresentedHandler`, with no
  second ack path: iosc's 100ms present-ack valve covers a handler that never
  runs, and a fallback would race it.
- **Render Scale stays off by default.** `MTLFXSpatialScaler` is supported on the
  A10 (temporal is not), gated by the runtime `supportsDevice` call. At the
  shipping geometry (logical 1440x1080 at scale 2, a 2880x2160 surface
  aspect-fitted onto a 2160x1620 panel) the present pass is already
  supersampling, so upscaling from a smaller intermediate only makes it softer;
  `auto` declines for that reason. The real saving needs the compositor to render
  fewer pixels (lower `IOSC_LOGICAL` or scale 1), which changes `wl_output` scale
  and wants measurement first. Overrides, most specific first: panel chips
  (`UserDefaults`), `XIOS_UPSCALE`, then `IOSC_UPSCALE` forwarded through
  `xios.json` (FrontBoard gives the app no environment).
- **KDE Plasma Desktop taps** go through the pointer lane: in the `kde` preset one
  direct finger is sent as a pointer and the parallel raw touch is suppressed, so
  a tap is one activation (`com.max.xios 0.1.8`). `kde-mobile` and configs with
  `touch_replaces_pointer` keep `wl_touch`.
- **Fences.** iosc frames carry a broker-imported `MTLSharedEvent`; a missing or
  invalid fence tears the surface down instead of presenting unsynchronized
  pixels. The camera broker stays off unless a diagnostic opt-in is present.
- **FrontBoard.** Fast kill/relaunch loops trip a relaunch throttle (no process,
  no crash log); `sbreload` clears it. The app needs the screen awake and
  foreground for Metal. A Home Screen tap is more reliable than `uiopen`.

## Open items
1. **Physical input matrix**: held and repeated keys, Ctrl/Alt/Shift/Super chords,
   navigation and F-keys, Caps/Num Lock, hover, five mouse buttons, wheel,
   continuous trackpad scroll with axis stop, click-drag, pointer lock and
   confinement, cursor hotspots. Run it on iosc, KDE, GNOME and the native host,
   plus Pencil and the KDE tap policy. The code is in both apps since 2026-07-19.
2. **Clipboard UIKit leg**: iOS Notes to `wl-paste` and back, PNG, large payloads
   (test recipe in `../clipboard-plan.md`). The Wayland side is proven with
   `wl-copy`/`wl-paste`.
3. **Portrait polish**: rotation resizes a 1440x1080 iosc session to 1080x1440
   logical; shell layout at that aspect still needs tuning.
4. Undecided (from the 2026-10-01 audit): what the display picker should do with a
   slot that is not ready, and whether to pause the 20 Hz pump in the background.

## Deploy and verify

```
edit apps/Xios/project.yml MARKETING_VERSION   # else apt sees no upgrade
bin/package-app.sh x11/apps/Xios               # signs with entitlements.plist, builds the deb
copy the deb over, dpkg -i it                  # postinst runs uicache -p
tap the X11 icon (screen awake)
read /var/jb/tmp/xios-status.txt, xios-geom.txt, xios-touch.log
```

`bin/install-app.sh x11/apps/Xios` is the fast sideload loop. It copies the bundle
straight to `/var/jb/Applications`, so the scp landmines apply there: `scp -r`
drops the exec bit and `_CodeSignature` (re-sign with `ldid -S` using the bundle's
own entitlements), copying into an existing bundle nests it (remove the
destination first), and run `uicache -p` after. Anything a flavor depends on ships
as the package.

## History (short)
- 2026-07-01: gesture-only chrome, the stale-zoom fix, first device sessions.
- 2026-07-04: rotation through OUTPUT; the app allows all orientations on iosc.
- 2026-07-28: the tabbed sheets became one panel with an Advanced drawer.
- 2026-07-29: responsiveness release (0.1.4), display pacing, MetalFX option,
  fence broker, UIScreen brightness route.
- 2026-07-30: stream-v2 consumer, KDE tap policy (0.1.8), app-launch feedback
  (0.1.9).
- 2026-08-02: version-skew diagnosis, dead-pin release (0.1.11), Return and Tab
  sent as keys.
- 2026-10-01: audit fixes (off-main-thread clipboard and fence import, input
  queueing instead of disconnecting, launches by desktop-file id), shipped as
  0.1.12.
