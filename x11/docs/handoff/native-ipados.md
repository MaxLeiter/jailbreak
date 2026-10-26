# native-ipados: the per-window iPad flavor

Each Linux app is its own iPadOS window (its own Home Screen icon, app switcher
entry, Split View and Slide Over), instead of one fullscreen desktop canvas. The
flavor package is `xios-native`: `xios-runtime` + `xios-launcher-tools` +
`com.max.xiosprefs`, with no fullscreen app or shell.

## Current state (2026-10-25)

- **Published:** `xios-native 0.1.8`, `xios-launcher-tools 0.1.12`,
  `com.max.xiosprefs 0.1.0`, `xios-runtime 0.1.4`.
- **Device-proven (2026-07-29/30):** launch by app id as `mobile`, generated
  per-app bundles opening as native windows, wrapper cleanup when the last window
  goes away, GIMP's splash-to-main-window hand-off, coexistence with a running
  fullscreen GNOME session.
- **Shipped but with no recorded device run:**
  - `0.1.10`: per-app raw touch opt-in (below).
  - `0.1.11`: ioscd execs through libiosexec, so `#!/bin/sh` `Exec` targets
    (crispy-doom, openttd, imv, systemsettings wrappers) launch instead of
    exiting 127. Startup log says `ioscd: exec via libiosexec ...` when it is
    live and `WARNING libiosexec not loaded` when not.
  - `0.1.12`: depends on `xios-session-stubs` (ioscd starts `xios-sysintd` on its
    app bus) and starts helpers per bus. That change is written up once in
    [session-launcher.md](session-launcher.md).
- **Known gap:** in native mode the session-lock surface has no canvas, so a lock
  screen is invisible (open item from the 2026-10-01 audit).

## How it works
- **Compositor:** one iosc binary. Native mode is runtime-gated (`LAUNCH_NATIVE`
  through ioscd, or `IOSC_NATIVE=1` / `-native`). It maps each `xdg_toplevel` to
  its own canvas IOSurface and serves `iosc-native.sock`
  (`wayland/xios_canvas.{c,h}`). Native uses `wayland-native-0`,
  `iosc-native-input.sock` and `xios-native.json`; classic uses `wayland-0` and
  `iosc-input.sock`, so both run at once.
- **Host:** `apps/iosc-host/` builds `IOSCHost`, copied into every generated
  bundle. A bundle's `Info.plist` carries only `IOSCAppID` and `IOSCName` (plus
  the optional `IOSCRawTouch`).
- **Wire:** protocol v1 from `apps/shared/XiosProtocol.h` (mirrored by
  `apps/iosc-host/Sources/iosc_native_proto.h`). BIND needs an exact HELLO
  version match; every `XIOS_MSG_NATIVE_FRAME` carries one broker token and a
  non-zero 64-bit `MTLSharedEvent` value, and the host waits on it before
  sampling. `XIOS_IN_BIND` scopes an input connection to one window id. Spec:
  `../native-ipados-protocol.md`.
- **Launch:** the host sends only `LAUNCH_NATIVE\t<app_id>`. ioscd authorizes
  root/mobile peers, resolves a non-writable root-owned desktop entry, turns its
  `Exec` into argv without a shell, and drops the app and its session bus to
  `mobile`. Device checks: an extra field is `ERR malformed`, `../bin/sh` and a
  mode-0666 entry are refused, `org.gnome.dspy` ran as UID 501.
- **Wrapper lifecycle:** `IOSCHost` exits one second after its last scene is
  discarded, 30 seconds after its last compositor window goes away, or 30 seconds
  after a launch that never produced a window; an ioscd rejection retires it after
  one second. `WINDOW_NEW` cancels pending exits (jetsam/reconnect replay, splash
  windows).
- **Raw touch:** `X-Xios-RawTouch=true` in a desktop entry makes
  `xios-launcher-sync` write `IOSCRawTouch` into that bundle. The host then installs
  none of the gesture recognizers that claim direct touches and sends no emulated
  pointer, so every finger arrives as `wl_touch`. It also defers screen-edge
  system gestures and hides the home indicator, so the way out is a second swipe.
  Crispy Doom is the first user. Existing bundles pick it up on the next
  `xios-launcher-sync --sync`.

## Home Screen app sync
- `xios-launcher-tools` ships `ioscd` (LaunchDaemon `com.max.ioscd`),
  `xios-icon-render` (theme icon to SpringBoard PNG sizes through gdk-pixbuf),
  `xios-launcher-sync`, `IOSCLaunch`, `IOSCHost`, `default.metallib` and the
  entitlements. Sources: `apps/iosc-desktop/src/`; package:
  `apps/iosc-desktop/package-launcher-tools.sh` (version in its `VER`).
- Postinst only fixes modes and re-bootstraps ioscd. It does not run a mass sync;
  bundles are created from Settings or the Xios panel, and `xios-launcher-sync`
  signs each bundle executable (`ldid -S` with the shipped entitlements).
- ioscd verbs on `/var/jb/tmp/ioscd.sock`: `APPS_LIST`,
  `APPS_SYNC\t<native|classic>\t<dry>`, `APP_ENABLE\t<id>`, `APP_DISABLE\t<id>`,
  streamed and ending with `APPS_END\t<status>`. Both the Xios panel (Advanced,
  Home Screen Apps) and the Settings pane (`tweaks/XiosPrefs`, package
  `com.max.xiosprefs`) drive them. The Settings pane bounds its socket reads so an
  incomplete reply cannot hang Settings.

## Gotchas
- Rootless has no `/bin/sh`. Anything that `execvp`s a script must go through
  libiosexec (`src/xios-iosexec.h`), or it fails with ENOENT and exits 127 with
  nothing in the log. ioscd weak-links it and only uses the exec entry points, so
  the drop to `mobile` still resolves through the system libinfo.
- Canvas port delivery (`task_for_pid` plus a timed `mach_msg`) runs on the reader
  thread, never the Wayland thread, so one suspended host cannot freeze every
  other native window. `WINDOW_GONE` is sent even if `WINDOW_NEW` is still in
  flight.
- The canvas socket is mobile-owned 0660 and never world-writable (app id is the
  flavor's only isolation).
- The first configure is sized to the scene BIND reported, so the first frame
  fills the window instead of reflowing.
- Build iosc with plain `wayland/build-iosc.sh`; on the Mac it re-execs in the
  cross image and host-signs `wayland/out/iosc`.

## Open items
1. Device run of the 0.1.10 to 0.1.12 changes: a `#!/bin/sh` app (crispy-doom),
   raw touch, and a Home Screen launch while a desktop is up.
2. Visual checks still not recorded: resize/focus/close of a native window,
   OSK rising in a native text field, host kill and relaunch replaying
   `WINDOW_NEW`, the Settings pane toggle and one controlled apply sync.
3. Give the session-lock surface a canvas in native mode.
4. Decide whether native mode should keep the single output IOSurface (tooling)
   or drop it to save memory.

## History (short)
- 2026-07-01: per-window host prototype and protocol; hardening (reader-thread
  port delivery, map/unmap race, socket mode, first-frame sizing).
- 2026-07-04: Home Screen sync tools, Settings pane, `xios-launcher-tools 0.1.0`.
- 2026-07-29: app-id-only launches as `mobile`, fenced protocol v1, package split
  into `xios-runtime` / `xios-core` / `xios-native`.
- 2026-07-30: wrapper lifecycle (0.1.9).
- 2026-10-01: raw touch (0.1.10), libiosexec exec (0.1.11).
- 2026-10-25: per-bus helpers, stubs dependency (0.1.12).
