# ipadctl phase 0: feasibility probe

Question: can one standalone root binary on the iPad (no SpringBoard tweak, no
respring) capture the screen fast enough and inject input that apps actually
receive? Yes. Everything below was measured on iPad7,12, iPadOS 17.6.1,
Dopamine rootless, 2026-10-01, with the probe run as root from SSH.

## Results

| Check | Result |
|---|---|
| Capture from a standalone process | pass |
| Capture + scale + rotate + JPEG, median of 30 | 15.8 ms (max 20 ms); target was 300 ms |
| tap | pass (Settings rows, Back button, search field, Cancel) |
| swipe | pass (scrolled the Settings sidebar; paged the home screen both ways) |
| type | pass (`wifi` into Settings search) |
| key | pass (`cmd+a`, `backspace`, `escape`) |
| button home | pass (Settings -> home screen) |
| frontmost app | pass (`com.apple.Preferences` in Settings, `com.apple.springboard` on home) |
| orientation mapping | pass for landscapeRight, the only orientation the device was in. The other three are derived, not observed. |
| longpress, volup, voldown | implemented, not exercised on device |
| lock / power | deliberately not implemented |

Typical timing breakdown, in ms: capture 2.6, scale 4.9 (hardware), rotate 1.0,
JPEG encode 7.2. Output is 1080x810 at about 120 to 150 KB at quality 0.7.
Without the hardware scaler (`--no-accel`, vImage), the median is 21 ms.

## Build, deploy, run

```sh
ipadctl/probe/build.sh --deploy      # build on the Mac, scp, ldid -S on the iPad
ssh root@MaxsiPad.local /var/jb/var/root/ipadctl/ipadctl-probe info
ipadctl-probe shot /tmp/s.jpg --bench 20
ipadctl-probe tap 115 417
ipadctl-probe swipe 187 200 187 700 400
ipadctl-probe longpress X Y [ms]
ipadctl-probe type "wifi"
ipadctl-probe key cmd+a
ipadctl-probe button home            # also volup / voldown
```

Every command prints one JSON object. Coordinates are points in the current
orientation, which is the same space as the `shot` output.

## How it works

**Capture** (`src/capture.m`), following TrollVNC's ScreenCapturer:
1. `CARenderServerRenderDisplay(0, "LCD", surface, 0, 0)` into a BGRA IOSurface
   sized to the panel in pixels (1620x2160, portrait, because that is the
   panel's native orientation).
2. `IOSurfaceAcceleratorTransferSurface` into a surface sized to the panel in
   points (810x1080). This is the hardware scaler. It falls back to
   `vImageScale` when the accelerator is unavailable.
3. `vImageRotate90` from panel space to view space.
4. ImageIO JPEG.

The earlier probe's NULL or empty frames were an entitlement problem.
`UICreateScreenImage` is not used at all.

**Input** (`src/hid.m`): build IOHIDEvents and send them with
`IOHIDEventSystemClientDispatchEvent` from a plain `IOHIDEventSystemClientCreate`
client.
- Touch is a "hand" digitizer parent (IsBuiltIn=1, IsDisplayIntegrated=1) with
  one finger child.
- Finger coordinates are normalized 0..1 in panel space.
- Down events use mask touch|identity|range, moves use position|attribute, and
  up events use touch|identity with range and touch cleared. This is the shape
  WebKit's HIDEventGenerator documents and TrollVNC uses.
- Keys use page 0x07 keyboard events. Shifted characters are wrapped in
  LeftShift, and modifiers are pressed in order and released in reverse.
- Home is consumer page 0x0C, usage 0x40 (Menu). Volume up and down are 0xE9
  and 0xEA.
- Every event is stamped with sender ID `0x8000000817319371` (TrollVNC's
  value). A made-up built-in-looking ID is accepted. ZXTouch's alternative is
  sniffing the real digitizer's sender ID from a live touch, which needs a human
  touch once per boot. That was not needed.

**info** (`src/display.m`):
- Geometry: `UIScreen.nativeBounds` and `nativeScale`.
- Orientation: `FBSOrientationObserver.activeInterfaceOrientation`.
- Frontmost app: `SBSCopyFrontmostApplicationDisplayIdentifier`. NULL means no
  app scene is up, which is reported as `com.apple.springboard`.
- Lock and screen state: `notify_get_state` on `com.apple.springboard.lockstate`
  and `com.apple.springboard.hasBlankedScreen`.

## Orientation mapping

Panel space is the native portrait panel in points (W=810, H=1080), with the
origin at the top-left and the home button at the bottom. View space is what the
user sees. `rot_q` is the number of clockwise quarter turns that take the panel
image to the view.

| UIInterfaceOrientation | home button | rot_q | view (x,y) -> panel (px,py) |
|---|---|---|---|
| portrait (1) | bottom | 0 | (x, y) |
| landscapeLeft (4) | left | 1 | (y, H - x) |
| portraitUpsideDown (2) | top | 2 | (W - x, H - y) |
| landscapeRight (3) | right | 3 | (W - y, x) |

The digitizer gets `(px/W, py/H)`. The screenshot is rotated with the same
`rot_q`, so the image and the touch mapping share one code path and cannot drift
apart. On device, landscapeRight was confirmed by the screenshot being upright
and by taps landing on the intended rows. For example, view (115,417) mapped to
panel unit (0.485,0.106) and hit "General".

Touch commands refuse to run if the orientation can't be read rather than guess.

## Entitlements (proven by ablation)

Each variant was signed on the device and re-run. The capture test was the
`blank` flag plus the image. The touch test was paging the home screen and
reading the page dots. With the final minimal set, the full Settings and home
sequence was re-run and passed.

Required:

| Entitlement | What breaks without it |
|---|---|
| `com.apple.QuartzCore.global-capture` | `CARenderServerRenderDisplay` silently renders an all-black frame. This is the previous probe's failure. |
| `com.apple.private.hid.client.event-dispatch` | Events are silently dropped. Dispatch has no return value. |
| iokit-user-client-class `IOSurfaceRootUserClient` | `IOSurfaceCreate` returns NULL |
| iokit-user-client-class `IOSurfaceAcceleratorClient` | Not fatal: no hardware scaler, and the vImage fallback is about 7 ms slower |

Tested unnecessary for root from SSH:
- `platform-application`
- `com.apple.private.security.no-container`
- `com.apple.QuartzCore.secure-capture`. On its own it still gives black.
  Possibly needed for secure layers such as DRM video; not investigated.
- `com.apple.private.hid.client.service-protected`
- `com.apple.private.hid.manager.client`
- `com.apple.backboard.client`
- `com.apple.frontboard.launchapplications`
- `com.apple.springboard.launchapplications`
- the IOKit user-client classes `IOHIDLibUserClient`,
  `IOHIDEventServiceFastPathUserClient`, `AGXDeviceUserClient` and
  `AppleJPEGDriverUserClient`

`info` (frontmost app, orientation, lock state) needs no entitlements at all.

TrollVNC's entitlement file has about 200 keys, almost all unrelated (storage,
CommCenter, notifications and so on).

## Gotchas for ipadctld

- **Both failure modes are silent.** Capture without the entitlement gives a
  valid black frame. HID without it returns nothing and does nothing. The
  daemon needs a startup self-test:
  - capture: non-blank while `hasBlankedScreen == 0`
  - input: verify an injected action by screenshot diff
  
  Don't trust "no error".
- **Sign on the device.** `build.sh --deploy` does this. Host-signed private
  entitlements are a known AMFI landmine here.
- **Black can be legitimate.** A black frame is also what you get with the
  display off. Pair the `blank` flag with `screen_on` before calling capture
  broken.
- **Geometry is cached per capturer.** Surfaces and rotation are set at
  creation. A long-lived daemon should subscribe to `FBSOrientationObserver`'s
  handler and rebuild on rotation, not poll.
- **Frontmost is one bundle ID.** `SBSCopyFrontmostApplicationDisplayIdentifier`
  says nothing about Split View, Slide Over, Control Center, the app switcher or
  alerts. It returns NULL on the home screen and very likely on the lock screen
  too, so check `locked` alongside it. The values while locked and while the
  Xios/iosc desktop is frontmost were not observed, because the device couldn't
  be put in those states safely.
- **Settings uses a split view in landscape.** There is no Back button at a
  pane's root. Row positions move with sidebar scroll and with what was open
  last. Always screenshot before choosing coordinates.
- **HID keys don't switch iOS to hardware-keyboard mode.** The software keyboard
  stayed on screen while typing, so a typed character can't be mistaken for a
  hardware keyboard being attached.
- **The render looks synchronous.** `CARenderServerRenderDisplay` returns in 2
  to 4 ms, and every single-shot run (fresh surfaces, so no stale frame to hide
  behind) produced a complete image. So the render is synchronous or fenced
  before the accelerator reads it.
- **Screenshots can be sensitive.** One test screenshot (About) showed the
  device serial. The MCP layer should treat frames as sensitive and not
  persist or log them by default.
- **`type` handles ASCII only.** Non-ASCII text will need the pasteboard or a
  text-input path in the daemon.

## Test screenshots (scratchpad, not committed)

`/private/tmp/claude-501/-Users-max-Documents-jailbreak--claude-worktrees-security-sweep-de8157/97d70e70-7a2b-4993-89a8-de48792782c4/scratchpad/`:

- Initial state: `s0.jpg` (home screen)
- (a) tap and back: `a0-settings.jpg` -> `a1-general.jpg` -> `a2-about.jpg`
  (shows the serial) -> `a3-back.jpg`
- (b) swipe, type and key: `b0-swipe.jpg`, `b1-focused.jpg`, `b2-typed.jpg`,
  `b3-selectall.jpg`, `b4-cleared.jpg`, `b5-cancel.jpg`
- (c) home: `c1-home.jpg`
- Entitlement ablation: `h-empty.jpg` (unentitled swipe, no effect),
  `h-hidonly.jpg` (page 4), `h-back.jpg`
- Re-run with the minimal entitlements: `m-a0.jpg` through `m-c1-home.jpg`

## References and licenses

- TrollVNC, https://github.com/owngoal-dev/TrollVNC: **GPL-2.0**
  (82Flex and contributors). The source of the capture recipe, the sender ID
  and the hand/finger event shape. No code was copied; the probe was written
  from scratch after reading `src/ScreenCapturer.mm`, `src/STHIDEventGenerator.mm`
  and `src/trollvncserver.mm`.
- ZXTouch Rootless, https://github.com/epic0001/zxtouchrootless: **GPL-3.0**.
  Read for its digitizer field values (`0xb0019`, `0xb0014`/`0xb0015`, `0x4`)
  and the sender-ID sniffing approach, which was not needed. No code was copied.
- The hand/finger event layout originates in WebKit's `HIDEventGenerator`
  (BSD-2-Clause, Apple), which TrollVNC's generator derives from.
