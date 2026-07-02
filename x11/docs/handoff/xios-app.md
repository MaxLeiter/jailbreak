# xios-app — the Xios iOS app (Metal present + input + IOSurface adopt)

## Ownership
The native iOS app that presents a Wayland/Mutter compositor's IOSurface on the iPad via Metal, streams UIKit touch/keyboard back over a unix socket, and hosts the in-app session picker. This is the MOST ACTIVE bug area.

## Key files
- `x11/apps/Xios/Sources/XScreen.swift` — the main view: present (`render()`), input/touch mapping (`fitTransform()`/`contentRect()`/`framebufferFloatPoint()`), surface adopt (`adoptIOSurface()`), config (`loadConfig()`), the ~1.5s watchdog (`ddxConfigChanged()` in `tick()`), gesture-only session picker.
- `x11/apps/Xios/Sources/XSurface.c` — the DDX client: IOSurface mach-port handoff, typed HELLO/DIRTY framing, `drain_typed`.
- `x11/apps/Xios/Sources/IoscInput.c` — input wire sender (fb-pixel coords).
- `x11/apps/Xios/Sources/Shaders.metal`, `NativeClient.c` (native-flavor).
- Wire contract: `x11/wayland/xios_input_socket.h` (24-byte record; MOTION/TOUCH x,y = absolute OUTPUT-pixel position 0..fbW × 0..fbH).
- Build → `x11/apps/Xios/build/Build/Products/Release-iphoneos/Xios.app`.

## Recent commits (on 9d88681 batch base, EXCLUDING scroll/clipboard which are deploy-coupled to a next wave)
- `828435f` in-app Desktop Session picker (⧉ button, writes `/var/jb/tmp/xios-request.json`).
- `74ecdfe` clip-fix: `resetZoom()` on fb-size change at adopt.
- `9948705` re-adopt watchdog: ~1.5s re-read of `/var/jb/tmp/xios.json`, re-adopt on socket/size change.
- `923e92f` crash-fix: per-tick bounds check on the test-pattern buffer (was overflowing on surface resize → the session-switch crash).
- `a7da822` **unconditional `resetZoom()` on EVERY adopt** + a touch diagnostic log (`/var/jb/tmp/xios-touch.log`).
- `8a94860` **(LATEST — deploy this)** flavor-switch jetsam fix + live switch banner. Superset of a7da822 (picker + scale/touch fix already in history). App-only, no wire change, no co-deploy. On ddx socket EOF (drain -1, checked every frame) `teardownIOSurface(lost:)` releases the IOSurface+texture PROMPTLY → drops to a low-footprint test-pattern hold (no longer pins the dead ~30MB surface, so the app leaves the memory-spike window and is NOT jetsammed) → the %30 poll re-adopts the new compositor's surface (loadConfig bumps loadGeneration on socket/size change, so a DIFFERENT compositor at a new path is picked up). Plus a full-screen banner polling `/var/jb/tmp/xios-session-status.json` (0.5s) that shows the launcher's live message during a switch.

## Current state
- Deployed on iPad: local Release-iphoneos build from 2026-07-01 19:53 with `syncSurfaceGeometry(conn)` plus the gesture-only chrome cleanup (Xios binary 480848 bytes after ldid signing). Desktop displays, launches apps, keyboard+typing work. SSH `uiopen` is throttle-flaky; SpringBoard registered `com.max.xios`, so tap the icon to foreground after deploy.
- The unified scale bug: the app was presenting the current fb at a STALE effective scale (0.75 instead of 0.675) → desktop overflowed right ~10% off-glass AND touches offset. `a7da822` resets zoom unconditionally on adopt (the stale factor was `zoomScale≈1.11` surviving because the earlier reset only fired on a size delta and the adopt saw none). The touch diagnostic confirmed zoom=1.0 + correct fb mapping after the fix on iosc.
- Confirmed clean on-device: Max tapped on iosc after deploy and reported that scale/taps are working well. Fresh diagnostics showed current iosc framebuffer geometry, zoom=1.0, and no stale Mutter/old-scale transform.
- Local pickup: `XScreen.swift` now factors IOSurface geometry+texture refresh into `syncSurfaceGeometry(conn)` and calls it after every `xsurface_drain(conn)`. This closes the stale Swift `fbWidth/fbHeight` hole from typed in-band HELLO refreshes and resets zoom on live geometry changes. Verified with `xcodebuild` simulator and device-sdk Release builds; deployed to iPad and switched Mutter → iosc. The app stayed alive and re-adopted `/var/jb/tmp/iosc-ddx.sock`; `/var/jb/tmp/xios-status.txt` reported `iosurface-zerocopy 2880x2160 [metal]`, matching `/var/jb/tmp/xios.json`. Fresh tap diagnostic after the switch: `bounds=810x1080 fb=2880x2160 drawable=1620x2160 zoom=1.0 rect=(0,236,810,607) -> fb=(1955,63)`, so the app is mapping against the current iosc framebuffer, not stale Mutter geometry.
- New ⧉ display-size picker: the Desktop Session sheet now has Default/Landscape/Portrait/Compact Portrait plus Advanced custom logical width/height/DPI. Session requests carry `width`/`height`/`dpi`; the updated on-device `xios-sessiond` exports `IOSC_LOGICAL=WxH`. Verified via daemon request `width=1080 height=1440 dpi=176`: device launched `iosc -logical 1080x1440`, and `/var/jb/tmp/xios.json` reported `2160x2880`, which is full-height portrait aspect on the iPad (`xios-geom.txt`: `bounds=810x1080 ... fb=2160x2880 ... ios=true`).
- 2026-07-01 gesture cleanup: persistent debug/chrome buttons were removed from the live desktop. Three-finger tap opens the X/Wayland display switcher (already-running displays). Four-finger tap opens the Desktop Session/display sheet (new/sized sessions). 3+ finger sequences are suppressed from the desktop input stream so app menu gestures do not leak wl_touch/pointer events. Pinch is now app zoom only and supports zooming back out to fit (`minZoomScale=1`); the old iosc ctrl+scroll pinch path and two-finger double-tap/button zoom helpers were removed. A one-finger upward swipe that begins in the lower ~28% of the screen reveals the iOS keyboard.
- 2026-07-01 later tap pass: Max tapped around the live iosc session again. Latest `/var/jb/tmp/xios-touch.log` still showed current geometry (`fb=2880x2160`, `drawable=1620x2160`, `zoom=1.0`, `pan=(0,0)`, `rect=(0,236,810,607)`, tap `p=(227,513) -> fb=(808,984)`). `/var/jb/tmp/iosc.log` showed shell-side reactions from the taps (overview layer surfaces created/focused), so app → iosc input is live and still not showing stale-scale mapping.

## Open items (priority order)
1. **Portrait/full-height polish**: the new session display picker can launch iosc at `1080x1440` logical (`2160x2880` framebuffer), which fills portrait height. Verify the shell layout feels good at this aspect and tune the quick presets if needed. Access is now four-finger tap, not visible chrome; three-finger tap is reserved for switching existing X/Wayland displays.
2. **DONE locally — bug-sweep Finding 1 (deeper root cause / robustness)**: the real staleness vector is `fbWidth`/`fbHeight` themselves (snapshotted only in `adoptIOSurface()` and `loadConfig()`, never refreshed while presenting). Implemented `syncSurfaceGeometry(conn)` in `XScreen.swift`; `adoptIOSurface()` and `tick()` now both use it, and texture-refresh failure tears down/reconnects.
3. **DONE locally — bug-sweep Finding 2 (simplification)**: `render()` and input now share one `FitTransform` in `XScreen.swift`. The transform owns the fit rect, framebuffer inverse mapping, and Metal clip-space vertices; scroll/pixel-perfect zoom also consume it.
4. **DONE locally — bug-sweep Finding 3 (verify/fix)**: `XSurface.c` no longer patches dimensions on post-connect typed HELLO. IOSurface geometry remains the single source of truth; a later HELLO with changed width/height/stride returns `-1` from drain, forcing teardown + full re-adopt/reconnect.
5. **Session-switch jetsam resilience**: switching flavors jetsams the app (memory peak from 2 compositors + re-adopt). App-side: survive the surface teardown / auto-relaunch; the picker status line should show launching progress (see session-launcher.md).
6. **Rotation** (task #21): on UIKit orientation/bounds change, update `drawableSize` + recompute the fit; landscape-lock is currently on (Info.plist LandscapeLeft/Right + UIRequiresFullScreen) — true device-rotation is coordinated with native-bundle (polish.md).
7. Next wave (staged separately): scroll (`iosc_input_axis`/`sendScroll`) + clipboard — deploy-coupled with iosc + Xios co-deploy, held out of the current picker build.

## Verified NOT the bug (don't re-chase)
- App→wire→compositor coordinate space is correct: app sends fb (physical output) pixels; iosc divides by `output_scale` once (`iosc.c:4922-4923`). No double-divide, no raw view-points on the wire. AXIS scroll pt→fb-px is consistent (but also keyed on the stale fb, fixed by #2).

## How to deploy + verify (see INDEX.md gotchas)
```
rm -rf on device: /var/jb/Applications/Xios.app  (avoid scp nesting)
scp -r -O Xios.app root@ipad:/var/jb/Applications/
ssh: chmod +x /var/jb/Applications/Xios.app/Xios
     ldid -e .../Xios > /tmp/ents; ldid -S/tmp/ents .../Xios   # keep GPU ents
     uicache -p /var/jb/Applications/Xios.app
Max taps the Xios icon (screen awake).  # SSH uiopen is throttle-flaky
Read /var/jb/tmp/xios-geom.txt, xios-status.txt, xios-touch.log to verify.
```
