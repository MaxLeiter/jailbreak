# xios-app — the Xios iOS app (Metal present + input + IOSurface adopt)

> The 0.2.0 Sileo depiction text (description + changelog) is in commit 8da1c171 of `claude/xios-v2`; repo/meta/com.max.xios.json keeps the published 0.1.12 text until 0.2.0 is staged.

## Ownership
The native iOS app that presents a Wayland/Mutter compositor's IOSurface on the iPad via Metal, streams UIKit touch/keyboard back over a unix socket, and hosts the in-app session picker. This is the MOST ACTIVE bug area.

## Key files (v2 layout, `x11/apps/Xios/Sources/`)
The app was rewritten for Xios v2 (see `x11/docs/xios-v2-design.md`, `x11/apps/Xios/INVARIANTS.md`).
`XScreen.swift` (5.3k lines) is gone; history below that mentions it describes the v1 app.
- `App/` — `AppDelegate`, `RootViewController` (launcher <-> desktop; the desktop view only lives
  in the hierarchy while a desktop is presented), `DesktopViewController` (holds the PresentView
  and the switcher sheet).
- `Core/` — `SessionRegistry` (discovers desktops: global `xios.json` + `xios-session-status.json`
  as slot `main`, `xios-displays.d/*.json` as slots; kqueue vnode watches + 2 s fallback poll,
  off main, torn reads retried; also watches a start request's status file for xios-session's
  refusal), `FileWatcher`, `SessionParsing` (pure), `Models` (SessionInfo, SessionState,
  presets), `PresetAvailability` (which flavors are installed), `IOSCDClient` + `IOSCDProtocol`
  (ioscd request lines, APPS_LIST),
  `Paths`, `Socket`, `Concurrency` (Epoch tokens).
- `Session/` — `SessionManager` (owns every connection, `present`/`goHome`, ioscd verbs),
  `SessionConnection` (one per desktop; holds surface/input/clipboard/sysint ONLY while
  presented; immediate reconnect on stream loss), `SurfaceLink` (XSurface wrapper, fences, one
  texture per IOSurface id, thumbnails), `InputLink`, `ClipboardLink`, `SysIntLink` (handle
  wrappers over the C clients).
- `Present/` — `PresentView` (CAMetalLayer, tick, status pill, owns input), `Renderer` (Metal
  pipeline, MetalFX, thumbnail pass), `FitTransform` (+ `ViewportState`, pure), `CursorPlane`,
  `FrameClock` (the one `setRange` pacing seam), `XiosUpscale`, `Shaders.metal`.
- `Input/` — `TouchRouter` (touches, Pencil, mouse buttons), `LaneTracker` (pure, per-gesture lane),
  `Gestures` (all recognizers), `KeyboardInput` (OSK policy, modifier row).
- `Integration/` — `SystemIntegration` (volume, brightness, appearance, rotation, haptics; one
  process-wide observer set, per-desktop wire), `A11yBridge`, `CameraBroker` (off unless flagged).
- `UI/` — `LauncherViewController` (card grid), `NewDesktopViewController` (+ change size),
  `SwitcherViewController`, `AppPickerViewController` (ioscd APPS_LIST only), `KeyPadViewController`,
  `SettingsViewController` (render scale, diagnostics, home screen apps, wallpaper, developer
  presets), `StatusPill`, `Form`.
- `Diagnostics/` — `StatusWriter` (every file write, background queue, on change only),
  `DebugReport`.
- `C/` — `XSurface.c` (DDX client, unchanged apart from `xsurface_surface_known` and ending the
  stream on a partial record write), `IoscInput.c`
  (the iosc-host handle version), `IoscClipboard.c`, `SysIntClient.c` (handle-based).
- `x11/apps/Xios/Tests/run.sh` — host-side checks (FitTransform, lane tracker, parsing, ioscd line
  formats, the real file registry with kqueue). `swiftc` only, no Xcode project.
- Wire contract: `x11/apps/shared/XiosProtocol.h`, `x11/wayland/xios_input_socket.h`.
- Build -> `x11/apps/Xios/build/Build/Products/Release-iphoneos/Xios.app`.
- Ships as a package, not a sideloaded app: `bin/package-app.sh x11/apps/Xios` wraps that
  bundle as `com.max.xios` (control at `x11/apps/Xios/packaging/control`, version from
  `project.yml`'s `MARKETING_VERSION`). `xios-core` depends on it, so the GNOME,
  KDE, and X11 fullscreen flavors pull it in. Native mode depends on
  `xios-runtime` and does not install this app.

## v2 M1 status (2026-10-25): ship-reviewed, built, NOT yet device-tested
Branch `claude/xios-v2` (the M1 commits rebased onto main after PR #13, plus a ship review),
`com.max.xios 0.2.0` (unpublished). Builds Release-iphoneos clean; host checks pass.
Waiting on the iPad: the device plan below. Known follow-ups for M2:
- (Resolved by M0: every slot has its own active marker, so `app` into a slot finds that slot's
  compositor.)
- APPS_LIST ids are `app_id` (StartupWMClass when set), while the `app` verb takes the desktop-FILE
  id. They match for most entries; ioscd should accept the app id or list the file id.
- Skipped on purpose: M1 review finding 12 (pre-existing in v1, not a regression); see the PR description.
- Hidden desktops are not paused yet (M2): switching away detaches the app, but the compositor
  keeps rendering.
- Proposed for ioscd (not done, ioscd.c had another owner): a read-only `PRESETS` verb that runs
  `xios-session presets` through `run_and_stream` (preset lines, then `APPS_END\t<status>`). The
  app already asks for it and uses it when it answers; once it ships, the app's file mirror of
  `xs_preset_check` (`Core/PresetAvailability.swift`) can go.

Ship review (2026-10-25), on top of the M1 report:
- Installed flavors only: New Desktop (and Settings > Developer) offer the presets
  `xs_preset_check` accepts; missing ones stay listed, disabled, with "Install xios-gnome" etc.
  Source order: ioscd `PRESETS`, else the app's mirror of `xs_preset_check` (pinned to the shell
  function by `Tests/run.sh` on fake roots), else unknown = offer everything. The answer is in
  `/var/jb/tmp/xios-presets.txt` (`source=ioscd|files|unknown installed=...`).
- xios-session refusals reach the user verbatim. ioscd answers SESSION_STARTED as soon as it
  forks, so the preflight's "GNOME is not installed: install xios-gnome" only ever reached the
  slot's `xios-session-<slot>.json` (a refused slot gets no xios-displays.d entry): the app said
  "Starting GNOME..." and then nothing, and blocked a retry for 60 s as "already starting". Every
  start, restart and resize now watches the request's status file and shows the message.
- Change size was broken for slots: `SESSION <preset> ... <slot>` on a running slot is refused
  by xios-session ("slot already running") and marked the live desktop failed. It now sends
  `SESSION resize ... <slot>`, which stops the slot and restarts its owner at the new size.
- A desktop that vanished from the registry while on screen kept a stale card after going home
  (the registry only publishes on change). Dropped on goHome now.
- Touch: a second finger landing and lifting mid-drag released the drag. The pointer now belongs
  to the finger that started the gesture.
- DDX socket: a partial write of a 32-byte record desynced the stream (listed for M3 in the
  design); it now ends the stream so the app reconnects.
- App picker: a refused launch is shown in the picker sheet itself (the toast was underneath).
- The display link no longer ticks at the launcher before the first desktop is shown.

Device test plan (run when the iPad is handed over; home-screen tap, not `uiopen`):
1. Launch: launcher shows Main (if a legacy session runs) plus any slots; thumbnails absent until
   a desktop has been left once. `xios-status.txt` has a `session slot=...` line.
2. Start KDE (+ card), watch the pill, tap in. Then start GNOME. Switch KDE <-> GNOME ten times via
   the three-finger tap and via the launcher; no black flash beyond a repaint; `footprint -p`
   Xios stays near 60 MB, no jetsam report.
3. Rotate 10 times in each desktop: the last frame holds, no black, reconnect within ~0.3 s
   (`iosc.log`: app client attached/dropped pairs, no dangling), taps still land after.
4. Touch matrix on KDE: single tap, drag, still hold = right click (no context menu), two-finger
   scroll/tap, pinch zoom, three-finger tap = switcher, top-edge pull = switcher; land a SECOND
   finger mid-drag and confirm the drag continues (the lane-flip fix, `xios-touch.log`).
5. Keyboard: swipe up from the bottom, OSK in a text field, Return/Tab, modifiers row; hardware
   keyboard chords; mouse/trackpad hover, buttons, scroll, pinch.
6. Clipboard both ways in each desktop after a switch (desktop wins if it replays).
7. Open an app into the hidden desktop from the launcher card menu (slot path), and from the
   switcher into the presented one.
8. Kill one desktop out of band over SSH: its card turns "Stopped unexpectedly" within ~4 s with
   Restart; killing the presented one returns home after ~3 s.
9. Background and foreground the app in a desktop and at the launcher; reconnects, no stale frame.
10. Settings: render scale chips, Debug copy/save, Home Screen Apps list + dry run, Shell wallpaper.
11. Installed flavors: with xios-gnome NOT installed, New Desktop lists GNOME under "Not Installed"
    with "Install xios-gnome" and cannot start it; `xios-presets.txt` says `source=files` (or
    `ioscd` once PRESETS ships) and matches `xios-session presets` run as root. Install it in
    Sileo, background and foreground Xios: GNOME moves up into the startable list.
12. Refusal text: with a KDE slot killed (step 8), `chmod -x` plasmashell over SSH, then tap
    Restart on its card (Restart does not consult the installed list): the toast shows
    xios-session's own words ("KDE Plasma is not installed: install xios-kde"), nothing is left
    "starting", and New Desktop now lists KDE under "Not Installed". Restore the bit after.
13. Change size on a running slot (launcher card menu and Custom...): the desktop restarts at the
    new size and stays presented if it was; no "slot already running" card.
14. Stop a presented desktop over SSH so its registry entry disappears: back home after ~3 s and
    its card is gone (not left as "Stopped").

## Recent commits / status notes
- 2026-07-29 display pacing + present-side MetalFX (device-tested; closes perf P0.4).
  `f09e4057` visibility channel, `56c9dc35` pacing, `7a5a61fc` MetalFX, `a46116e7` and
  the follow-ups below the bugs the device found.
  - Pacing is live and proven. `xios-status` on a healthy iosc session:
    ```
    Xios       pacing=vblank fps=30-60/60 interval=16.66ms
    Xios       upscale=off
    iosc       pacing=vblank fps=60 range=30-60 interval=16.66ms
    ```
    Both sides publish `pacing` under their own producer name, so "the app is
    offering a display clock" and "the compositor accepted one" are separately
    visible. The iosc log shows the transition
    `pacing=event-loop (no display clock from the app)` → `pacing=vblank ...` as the
    app attaches, which is the state machine working rather than a warning.
  - `preferredFramesPerSecond` is gone; the frame rate is a `CAFrameRateRange`
    applied through one `setPacingRange()` seam. **That seam is what the thermal
    track clamps — do not turn it back into a fixed number.**
  - The `presentedTime` ack moved from the command buffer's completed handler to
    `drawable.addPresentedHandler`. There is deliberately no second ack path: iosc's
    existing 100ms present-ack valve is the net for a drawable whose handler never
    runs, and adding a fallback handler would race it and lose the measurement
    (completion always fires first).

### Render Scale (present-side MetalFX upscaling) — OFF by default, and it should stay off
`MTLFXSpatialScalerDescriptor.supportsDevice` is **YES** on the A10 (temporal NO), so
the capability is real; the gate is that runtime call, never a GPU-family check, and
MetalFX is weak-linked behind an `NSClassFromString` probe.

The reason it is not the default is geometry, not confidence:

- iosc ships logical 1440x1080 at scale 2 → a **2880x2160** surface, which the app
  aspect-fits onto the **2160x1620** panel. That 0.75 downscale is *supersampling*:
  the present path already has more source detail than the panel can resolve.
- Routing that through a 1440x1080 intermediate first discards information and then
  reconstructs it. MetalFX cannot invent detail deleted a pass earlier, so at the
  shipping geometry the trade is **softer for a saving in the app's present pass
  only** — the compositor still draws all 6.2M pixels.
- This is exactly why `auto` declines here (device-confirmed: hint reached
  `xios.json` as `"upscale":"auto"`, app reported `upscale=off`). That refusal is the
  design, not a gap.

The win that actually pays needs the **compositor** to render fewer pixels — lower
`IOSC_LOGICAL`, or scale 1 — and *that* changes `wl_output` scale, which HiDPI clients
do observe. So it is a session-geometry decision, not a present-side toggle, and it
wants measurement before it becomes a default. Sequence it after the thermal track,
which will have real frame-time numbers to argue from.

Exposed three ways, most specific first: the in-app **Xios → Render Scale** chips
(persisted in `UserDefaults`, applies on the next frame — no session restart, because
nothing about the compositor's output changes), `XIOS_UPSCALE` in the app's own
environment, then `IOSC_UPSCALE` on the compositor (forwarded into `xios.json`, which
is the production path since FrontBoard gives the app no environment). The settings
summary reports the *live* `upscale=` value rather than what was requested, so "auto
declined" and "this GPU has no spatial scaler" are both visible in the UI.

- 2026-07-29 responsiveness release (`com.max.xios 0.1.4`, installed and device-tested):
  - `ff1ba0d9` moves every ioscd request off the UIKit thread, adds bounded socket
    read/write timeouts, and suppresses duplicate session requests.
  - `2ca048db` replaces the full-resolution CPU+Metal holding frame with a 1x1 black
    texture while the compositor is absent (about 49.8 MB avoided at 2880x2160).
  - `29f0b28b` pauses the display link and releases input, IOSurface, fence, and
    texture state while backgrounded; foregrounding reloads config and reconnects.
  The only 2026-07-29 Xios analytics report was bug type 509 (background termination
  watchdog), not a JetsamEvent: `memoryPressure=false`, resident memory about 97.7 MB,
  and the main stack pointed at the old synchronous ioscd response reader. After the
  fixes, iosc/KDE switching retained one Xios PID, held roughly 18-27 MB RSS, and
  produced no new Xios crash report.
- `828435f` in-app Desktop Session picker (⧉ button; current builds send `SESSION` over `/var/jb/tmp/ioscd.sock`).
- `74ecdfe` clip-fix: `resetZoom()` on fb-size change at adopt.
- `9948705` re-adopt watchdog: ~1.5s re-read of `/var/jb/tmp/xios.json`, re-adopt on socket/size change.
- `923e92f` crash-fix: per-tick bounds check on the test-pattern buffer (was overflowing on surface resize → the session-switch crash).
- `a7da822` **unconditional `resetZoom()` on EVERY adopt** + a touch diagnostic log (`/var/jb/tmp/xios-touch.log`).
- `8a94860` flavor-switch jetsam fix + live switch banner. Superset of a7da822 (picker + scale/touch fix already in history). App-only, no wire change, no co-deploy. On ddx socket EOF (drain -1, checked every frame) `teardownIOSurface(lost:)` releases the IOSurface+texture PROMPTLY → drops to a low-footprint test-pattern hold (no longer pins the dead ~30MB surface, so the app leaves the memory-spike window and is NOT jetsammed) → the %30 poll re-adopts the new compositor's surface (loadConfig bumps loadGeneration on socket/size change, so a DIFFERENT compositor at a new path is picked up). Plus a full-screen banner polling `/var/jb/tmp/xios-session-status.json` (0.5s) that shows the launcher's live message during a switch.
- Scroll/touch/tablet/clipboard app-side code has landed; clipboard is now compositor-wired too. Treat clipboard/scroll as app+iosc co-deploy work, not an app-only next wave.

## Current state
- 2026-08-02 "KDE taps are dead" — **the cause was app/compositor version skew,
  and taps are now device-confirmed working.** Symptom: `xios-status.txt` stuck
  at `holding-frame awaiting iosurface 2880x2160 [metal]` /
  `input-not-connected` while the `kde` session was `up` with `iosc`,
  `kwin_wayland --scale 2.75` and `plasmashell` all alive on the correct
  `/var/jb/tmp/iosc-{ddx,input}.sock`. With `input-not-connected` every UIKit
  path bails at `guard inputConnected`, so *no* tap reaches any compositor — and
  the desktop still looks live because the app holds its last frame.
  Root cause, from `iosc.log`: `xios: app client attached (typed fd=32 slot=0
  caps=0x1 total=1)` immediately followed by `xios: client fd=32 dropped`.
  `caps=0x1` is `XIOS_HELLO_CAP_STREAM_V2`; the device was running **iosc 0.9.43
  + ANGLE es3-15** against a stream-v2 app. That is exactly the pairing this file
  already required ("deployed only with ANGLE `es3-16` and `iosc 0.9.46`") — the
  entry was right, the device had simply drifted behind it.
  Fix on-device: install the published `iosc 0.9.46` + `angle …+es3-16` (hash-
  verified against the committed index), then restart the session so the new
  compositor binary is the running one. `iosc` then logs `output stream allocated
  3 buffers`, the app attaches and **stays** attached, and status flips to
  `iosurface-zerocopy 2880x2160 [metal]` / `input-connected iosc(wayland)`.
  Max confirmed taps work.
  **DIAGNOSTIC TRAP that cost most of this session: `xios-debug.txt` is written
  only on demand** (UI actions), so a stale copy reads like current state and its
  `ddx_socket=`/`iosc_input=` lines will name a long-dead slot's sockets. Trust
  `xios-status.txt` (written on every state change) and `iosc.log`; check the
  debug snapshot's mtime before believing it.
- 2026-08-02 dead-pin hardening (`com.max.xios 0.1.11`) — a real bug found while
  chasing the above, but **not** what broke taps: a pinned display whose slot
  dies could never release the pin. `userPinned`/`selectedConfigPath` were only
  ever dropped by the app's own Stop/Remove rows (`unpinIfShowing`, 2026-07-28),
  so a slot stopped over SSH or reaped after a crash left the pin bound to a
  deleted config forever, and every reload path (`tick`'s watchdog and
  holding-frame poll, `teardownIOSurface`) is gated on `!userPinned`. Only an app
  relaunch cleared it, since the pin is not persisted.
  `releasePinIfDisplayGone()` polls the pinned display on the same ~1.5s cadence
  and drops the pin once its config or DDX socket has been gone for 3 consecutive
  polls (a restarting slot is tolerated), then falls back to the live `xios.json`
  through `reloadRuntimeConfig()`. `xios-debug.txt` now also reports
  `config=<path> pinned=<bool>`. Release-iphoneos build, `bin/package-app.sh`,
  and the `bin/install-app.sh` sideload pass; the 0.1.11 build is what is running
  on-device in the confirmation above. The dead-pin path itself is not
  device-reproduced — it needs a pinned slot to be stopped out-of-band.
- 2026-08-01 host-only repository release (`com.max.xios 0.1.10`; published to
  staging and production, not installed on-device): `0.1.9` was packaged before
  the final stream-v2 C client sources,
  so the immutable successor was built from the actual final tree. Release
  iPhoneOS build, ldid entitlement inspection, local symbol inspection, package
  assembly, and the rootless target-package check pass. Package SHA256 is
  `79a0acbb85f4af3f0e3cd43ed4926371ba6dc0ea52a7e1378eca8d102083e071`;
  packaged Xios binary SHA256 is
  `e4bfb9f2d4a64e5ff2e1203ac3a81cf210ace227f28e73628a7c880f807ee4a5`.
  The public package bytes and signed index were independently verified against
  source/index commit `fc95ee3a` after production deployment.
  It must be deployed only with ANGLE `es3-16` and `iosc 0.9.46`, then pass the
  three-output rotation, direct/composited/direct, reconnect quarantine, and
  physical UIKit-tap matrix described in `iosc-compositor.md`. No new device
  result is claimed while the iPad is away.
- 2026-07-30 stream-v2 consumer (development deploy, direct-path device
  verified; final three-target rotation proof pending):
  XSurface negotiates up to three fixed output IOSurfaces plus dynamically
  exported direct-present surfaces, with legacy reconnect fallback. DIRTY now
  identifies the exact allocation and is consumed one frame at a time rather
  than coalesced because every ownership transfer needs a matching release.
  XScreen retains the currently displayed allocation for idle redraw/zoom,
  then, when it accepts the next DIRTY, submits an empty command buffer on the
  same Metal queue to signal the old sequence after all earlier samples and
  immediately sends RELEASED. The compositor can enqueue its wait without a CPU
  stall. Direct client surfaces can carry independent dimensions and a vertical
  flip flag while framebuffer/input geometry remains the compositor output.
  Release-iphoneos and the canonical `bin/install-app.sh x11/apps/Xios` flow
  passed; the installed binary SHA256 is
  `fa85c3be663919159b21e002d5ef76076a540f8c069aca2ec0d8ea7424212f29`.
  After a physical Home Screen launch, Xios negotiated
  `typed stream-v2 ... outputs=3`, stayed at
  `iosurface-zerocopy 2880x2160 [metal]`, and kept the slot input socket
  connected while KWin switched from its direct IOSurface to composited
  fallback and back. The isolated proof survived that forced fallback/capture
  with KWin/Plasma/iosc/Xios alive; the authoritative slot log is
  `artifacts/device-runs/kde-direct-context-pbuffer-20260730-0415/iosc-codex-gles.log`.
  A later default-session run deliberately killed and relaunched Xios while the
  packaged-candidate `iosc 0.9.44` compositor, KWin, and Plasma stayed live.
  The compositor accepted the new stream-v2 client and Xios returned to
  `iosurface-zerocopy 2880x2160 [metal]` with
  `input-connected iosc(wayland)`; the matching evidence bundle is
  `artifacts/device-runs/kde-stream-v2-disconnect-reconnect-fixed-20260730/`.
  A new physical tap is still required to close the UIKit-origin boundary.
  Network `idevicescreenshot` was unavailable, so the captures prove compositor
  contents while the app status/process/stream logs prove the UIKit consumer
  remained attached for the clean direct/fallback/direct cycle.
- 2026-07-29 device proof: `com.max.xios 0.1.4` and `xios-session 1.0.67`
  are installed. Xios PID `77756` survived repeated iosc → KDE → iosc → KDE
  transitions and concurrent client-launch pressure. Final state was
  `kde/up`, `iosurface-zerocopy 2880x2160 [metal]`, input connected, about
  26 MB RSS, no session lock, and no new analytics report. A nonblank KDE
  compositor capture and the status/log bundle are in
  `artifacts/device-runs/xios-responsiveness-final-20260729-kde/`.
- 2026-07-29 release-policy cleanup: Xios now requires explicit compositor-advertised
  input/clipboard sockets instead of inferring global paths, keeps the camera broker disabled
  unless a diagnostic Info.plist/environment opt-in is present, and imports iosc's output
  `MTLSharedEvent` through the package-owned XPC broker before Metal samples an IOSurface.
  A missing/invalid broker fence on an iosc frame tears down the surface instead of presenting
  unsynchronized pixels. The Release-iphoneos build and host signature checks pass; the matched
  app is installed, but normal FrontBoard foreground proof was blocked by screen state.
- 2026-07-19 desktop-input closure (host-verified, device proof pending): the classic app and
  native host share `apps/shared/XiosHardwareKeyboard.swift` and a pure HID-to-X keysym map.
  `GCKeyboard` now supplies real press/release transitions outside the UIKit text-input lifecycle,
  including simultaneous chords, key repeat, arrows/navigation, F1-F24, keypad/media keys,
  Command-as-Super, Caps Lock, and Num Lock. Disconnect/background/reconnect paths release held
  keys so modifiers cannot stick. UIKit text/OSK input remains a synthetic tap fallback and is
  de-duplicated from the raw hardware event.
- The same pass adds indirect-pointer hover, primary/secondary/middle/back/forward buttons,
  simultaneous button state, discrete mouse-wheel frames, and continuous two-axis Magic Keyboard
  trackpad frames with axis-stop. Both Release-iphoneos targets build successfully; the pure Swift
  HID mapping test passes. No physical-device claim is made while the iPad is offline.
- Deployed on iPad: local Release-iphoneos build from 2026-07-01 19:53 with `syncSurfaceGeometry(conn)` plus the gesture-only chrome cleanup (Xios binary 480848 bytes after ldid signing). Desktop displays, launches apps, keyboard+typing work. SSH `uiopen` is throttle-flaky; SpringBoard registered `com.max.xios`, so tap the icon to foreground after deploy.
- The unified scale bug: the app was presenting the current fb at a STALE effective scale (0.75 instead of 0.675) → desktop overflowed right ~10% off-glass AND touches offset. `a7da822` resets zoom unconditionally on adopt (the stale factor was `zoomScale≈1.11` surviving because the earlier reset only fired on a size delta and the adopt saw none). The touch diagnostic confirmed zoom=1.0 + correct fb mapping after the fix on iosc.
- Confirmed clean on-device: Max tapped on iosc after deploy and reported that scale/taps are working well. Fresh diagnostics showed current iosc framebuffer geometry, zoom=1.0, and no stale Mutter/old-scale transform.
- Local pickup: `XScreen.swift` now factors IOSurface geometry+texture refresh into `syncSurfaceGeometry(conn)` and calls it after every `xsurface_drain(conn)`. This closes the stale Swift `fbWidth/fbHeight` hole from typed in-band HELLO refreshes and resets zoom on live geometry changes. Verified with `xcodebuild` simulator and device-sdk Release builds; deployed to iPad and switched Mutter → iosc. The app stayed alive and re-adopted `/var/jb/tmp/iosc-ddx.sock`; `/var/jb/tmp/xios-status.txt` reported `iosurface-zerocopy 2880x2160 [metal]`, matching `/var/jb/tmp/xios.json`. Fresh tap diagnostic after the switch: `bounds=810x1080 fb=2880x2160 drawable=1620x2160 zoom=1.0 rect=(0,236,810,607) -> fb=(1955,63)`, so the app is mapping against the current iosc framebuffer, not stale Mutter geometry.
- New ⧉ display-size picker: the Desktop Session sheet now has Default/Landscape/Portrait/Compact Portrait plus Advanced custom logical width/height/DPI. Session requests carry `width`/`height`/`dpi`; ioscd exports `IOSC_LOGICAL=WxH` before invoking `xios-session`, so the next iosc session uses the selected dimensions.
- Local multi-display slot UI: the Displays & Sessions sheet now discovers `/var/jb/tmp/xios-displays.d/*.json` in addition to legacy X sockets/global `xios.json`. Selecting a slot pins the app to that slot's `xios-<slot>.json` until "Follow Current" clears the pin. The session sheet adds "New iosc", "New KDE", and "New GNOME" buttons that send the optional `SESSION` slot field to ioscd, creating a new namespaced display slot instead of replacing the active global session.
- 2026-07-01 gesture cleanup: persistent debug/chrome buttons were removed from the live desktop. Three-finger tap opens the X/Wayland display switcher (already-running displays). Four-finger tap opens the Desktop Session/display sheet (new/sized sessions). 3+ finger sequences are suppressed from the desktop input stream so app menu gestures do not leak wl_touch/pointer events. Pinch is now app zoom only and supports zooming back out to fit (`minZoomScale=1`); the old iosc ctrl+scroll pinch path and two-finger double-tap/button zoom helpers were removed. A one-finger upward swipe that begins in the lower ~28% of the screen reveals the iOS keyboard.
- 2026-07-01 later tap pass: Max tapped around the live iosc session again. Latest `/var/jb/tmp/xios-touch.log` still showed current geometry (`fb=2880x2160`, `drawable=1620x2160`, `zoom=1.0`, `pan=(0,0)`, `rect=(0,236,810,607)`, tap `p=(227,513) -> fb=(808,984)`). `/var/jb/tmp/iosc.log` showed shell-side reactions from the taps (overview layer surfaces created/focused), so app → iosc input is live and still not showing stale-scale mapping.
- 2026-07-03 a11y app-side smoke: Xios now includes `XiosA11yClient`, an unbound VoiceOver publisher for the desktop helper stream. Deployed the rebuilt Release-iphoneos app, re-signed with `apps/Xios/entitlements.plist`, created `/var/jb/tmp/xios-a11y-force`, launched `xios-session app kgx`, and foregrounded Xios on iosc. `/var/jb/tmp/xios-a11y-app.log` showed the app connecting to `/var/jb/tmp/xios-a11y.sock`, receiving `hello`/`reset`, and publishing 12 accessibility elements for one window. Evidence: `artifacts/device-runs/20260703-123824/xios-a11y-app.log`.
- 2026-07-03 VoiceOver state bridge: `XiosA11yClient` now sends `A11Y_STATE\t1|0` to `/var/jb/tmp/ioscd.sock` when `UIAccessibility.isVoiceOverRunning` changes. On-device foreground smoke with VoiceOver off logged `ioscd a11y state sent enabled=false`. The positive path was verified by sending `A11Y_STATE 1` to ioscd directly, which created `/var/jb/tmp/xios-a11y-enabled`; with no force file present, the next `xios-session app kgx` launch started `xios-a11yd` and the AT-SPI stack. Real physical VoiceOver gesture validation remains open.
- 2026-07-04 rotation/native-feel bridge: Xios.app is no longer landscape-locked for iosc. `XServerViewController` returns `.all` while `XScreenView` is using iosc, `SystemIntegration` sends OUTPUT on orientation changes, and the app now force-resends the current OUTPUT state after IOSurface adoption/layout so a compositor restart in the same portrait orientation still converges. Rebuilt/deployed Release `iphoneos`; final device state was clean `xios-session iosc`, Xios foregrounded, `/var/jb/tmp/xios-status.txt` `iosurface-zerocopy 2160x2880 [metal]`, input connected, and `/var/jb/tmp/xios-geom.txt` `bounds=810x1080 drawable=1620x2160 fb=2160x2880 orient=1`.
- 2026-07-30 KDE desktop tap policy: the earlier direct-touch policy prevented
  duplicate activations, but it also made Plasma Desktop depend entirely on
  single-finger `wl_touch` activation; the live scaled Desktop stopped acting
  on those taps even though deterministic iosc pointer and multitouch probes
  proved the compositor was not frozen. `com.max.xios 0.1.8` now routes one
  direct finger in the `kde` Desktop preset through the proven pointer lane and
  suppresses the parallel raw-touch record, so a tap remains exactly one
  activation. `kde-mobile` keeps native `wl_touch`, as do explicit future
  `touch_replaces_pointer` configurations; Pencil and indirect pointer paths
  are unchanged. Release-iphoneos build/package and device install passed;
  Xios is foregrounded with `iosurface-zerocopy 2880x2160 [metal]` and
  `input-connected iosc(wayland)`. Physical post-install tap confirmation is
  still required. Package SHA256:
  `d7ea2c108aa7101baa62394a424c6b97a8db9373ed24b61091b94fda3e153a7c`.
- 2026-07-05 app overlay auto-hide: the Swift-owned overlay showing the active desktop/session plus iOS time/battery now auto-hides after 5s, has a long-press menu action to dismiss immediately, and can be revealed temporarily by a one-finger pull down from the top edge. This is app-side only (`XScreen.swift`), no compositor protocol change. Release-iphoneos build passes and the rebuilt app was deployed to `/var/jb/Applications/Xios.app` with matching local/on-device binary SHA256 `b7d46a60fa2bbde2fdd0616f78b54b2353142402b00c49a3b4a48a4837c17d96`; Xios stayed foregrounded on `kde-desktop` with `iosurface-zerocopy 2880x2160 [metal]`. Evidence: `artifacts/device-runs/xios-overlay-autohide-20260705-1859/`. Physical top-edge/long-press gesture validation is still pending because the harness only captured a compositor screenshot, not a physical device screenshot.
- 2026-07-28 settings/display UI redo: the tabbed "Displays & Sessions" sheet + separate "Tools" sheet were replaced by one panel and one Advanced drawer. Panel = status card (plain English: `KDE Plasma / Running · 1440×1080 · touch and keyboard ready`), Desktop list (running one is highlighted, tap restarts), Screen Size (Default/Landscape/Portrait/Compact/Custom — resizes now if a desktop is up, otherwise applies to the next start), Open an App, then Stop Desktop / Advanced. Advanced = display list + Fit/Reload/Reconnect Input, extra display slots, Home Screen Apps, the Key & Click Pad, and the debug snapshot. Removed: the Displays/Sessions tabs, the duplicate "Apply Size to X" button, the three separate places that set display size, the "Maintenance" rows repeated on both tabs, the quick-launch app buttons (search covers them), and the auto-opening picker at launch when several displays are open (it now just sets the status message). The four-finger tap gesture is gone; three-finger tap opens the panel. `x11/apps/Xios/Sources/XScreen.swift` + `XiosShellOverlay.swift`; the legacy `xios-request.json` display-profile write survives as Advanced → X Server Size. Simulator build passes and all three sheets were rendered/checked in the Simulator; on-device validation is still open.

## Open items (priority order)
1. **Physical desktop-input matrix**: on the next device window, verify held/repeated keys and
   Ctrl/Alt/Shift/Super chords; navigation/F-keys/Caps/Num; hover; all five mouse buttons and
   button chords; discrete wheel; continuous two-axis trackpad scroll/stop; click-drag; pointer
   lock; confinement; and named/custom cursor hotspot behavior. Run it in direct iosc, nested KDE,
   Mutter/GNOME, and the native host. Also sanity-check Pencil and the KDE direct-touch policy.
2. **Portrait/full-height polish**: the app/compositor rotation path now resizes a default `1440x1080` iosc session into `1080x1440` logical (`2160x2880` framebuffer) when the iPad is portrait. Keep tuning shell layout/quick presets at this aspect; access is the Screen Size row in the Xios panel (three-finger tap, or the status bar button).
3. **DONE locally — bug-sweep Finding 1 (deeper root cause / robustness)**: the real staleness vector is `fbWidth`/`fbHeight` themselves (snapshotted only in `adoptIOSurface()` and `loadConfig()`, never refreshed while presenting). Implemented `syncSurfaceGeometry(conn)` in `XScreen.swift`; `adoptIOSurface()` and `tick()` now both use it, and texture-refresh failure tears down/reconnects.
4. **DONE locally — bug-sweep Finding 2 (simplification)**: `render()` and input now share one `FitTransform` in `XScreen.swift`. The transform owns the fit rect, framebuffer inverse mapping, and Metal clip-space vertices; scroll/pixel-perfect zoom also consume it.
5. **DONE locally — bug-sweep Finding 3 (verify/fix)**: `XSurface.c` no longer patches dimensions on post-connect typed HELLO. IOSurface geometry remains the single source of truth; a later HELLO with changed width/height/stride returns `-1` from drain, forcing teardown + full re-adopt/reconnect.
6. **DONE on device — session-switch/watchdog resilience**: ioscd work is asynchronous
   and time-bounded, Xios releases background/compositor state, the transition holding
   frame is 1x1, and the launcher preserves the app while serializing compositor
   switches. Repeated iosc/KDE transitions retained one app PID with no new crash or
   jetsam report; see `session-launcher.md` for the companion teardown fixes.
7. **DONE locally — Rotation/native-feel OUTPUT** (task #21): UIKit orientation/bounds changes update `drawableSize`, recompute fit, and force-send OUTPUT through `SystemIntegration`; adopt/layout also force-resend so compositor restarts in the same orientation do not letterbox. Co-deploy with `iosc 0.9.9` or newer.
8. **LANDED (9470335 and later iosc wiring)**: scroll (`iosc_input_axis`/`sendScroll` + `sendScrollStop`), the deferred-press/long-press right-click state machine, pinch app-zoom, the wheelPan trackpad recognizer, and the touch/Pencil senders (`iosc_input_touch`/`iosc_input_tablet`). Clipboard app-side also landed here: `serviceIoscClipboard` was rewritten to the multi-item API on the 32-byte 'XMS1' typed envelope (`XIOS_MSG_CLIPBOARD` 0x04), and `lastSentPasteboard` plus the transitional text-only wrappers were dropped. The compositor hooks have since landed, so the remaining rule is co-deploy/verify the matching Xios.app + iosc pair.

## Verified NOT the bug (don't re-chase)
- App→wire→compositor coordinate space is correct: app sends fb (physical output) pixels; iosc divides by `output_scale` once (`iosc.c:4922-4923`). No double-divide, no raw view-points on the wire. AXIS scroll pt→fb-px is consistent (but also keyed on the stale fb, fixed by #2).

## How to deploy + verify (see INDEX.md gotchas)

The app is a package now, so shipping it is a version bump plus a deb, not an scp:
```
edit x11/apps/Xios/project.yml MARKETING_VERSION   # else apt/dpkg sees no upgrade
bin/package-app.sh x11/apps/Xios                   # -> repo/debs/com.max.xios_<ver>_*.deb
scp the deb, then on device: dpkg -i <deb>         # postinst runs uicache -p
Max taps the Xios icon (screen awake).  # SSH uiopen is throttle-flaky
Read /var/jb/tmp/xios-geom.txt, xios-status.txt, xios-touch.log to verify.
```
`package-app.sh` ldid-signs with `entitlements.plist` before staging, so the deb carries the
GPU/IOSurface entitlements and correct perms — none of the bare-scp landmines apply to it.

For a fast local iteration loop `bin/install-app.sh x11/apps/Xios` still sideloads the same
bundle straight to `/var/jb/Applications`, and there the scp gotchas in INDEX.md do apply.
Anything Max is meant to install, or that a flavor depends on, goes out as the package.

## 2026-07-30 app-launch feedback repair — PRODUCTION, BACKEND DEVICE VERIFIED
- The in-app launcher treated only `/var/jb/tmp/wayland-0` as a live desktop,
  falsely labeling nested KDE as stopped even when
  `xios-kde-runtime/kwin-ios-test` was accepting clients.
- `com.max.xios 0.1.9` recognizes the KDE runtime sockets, does not start the
  desktop-transition status timer for additive app launches, and waits for the
  ioscd acknowledgment before dismissing the launcher. A rejection now stays
  visible in the sheet instead of disappearing behind the desktop.
- Release `iphoneos` compile, ldid signing, and package generation pass. The
  package SHA256 recorded during the host build is
  `0af7db533e17481b005c735c986b00db214dfcc0d0ac8819f9ed7a12ad670fc5`.
- `com.max.xios 0.1.9` is live in production and installed on the iPad; live
  payload fetch-back matched that SHA256. The KDE-private-socket launch path was
  exercised on-device by submitting KWrite: desktop status remained `kde/up`
  while the separate app record became `kwrite/submitted`. Physical UIKit
  tap-through remains open because the app foreground attempt stayed at
  `holding-frame awaiting iosurface` / `input-not-connected`.
