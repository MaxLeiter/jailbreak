# native-ipados — the native per-window iPad flavor

## Ownership
The flavor where each Linux app is its own native iPad window (per-window presentation), instead of one full-desktop canvas. A macOS-style window manager feel on iPadOS. Task #28.

## Key files
- `x11/apps/iosc-host/` — HostApp.swift, HostScreenView.swift, NativeClient.c, Shaders.metal → builds to `out/IOSCHost` (protocol-conformant prototype).
- `x11/wayland/xios_canvas.{c,h}` — N-canvas registry + `iosc-native.sock` BIND server + `deliver_canvas_port`.
- `x11/wayland/iosc.c` — runtime-gated native mode (`LAUNCH_NATIVE` via ioscd, or low-level `IOSC_NATIVE=1`/`-native`) that maps each xdg_toplevel to its own canvas while keeping classic mode available in the same binary.
- Design: `x11/docs/native-ipados-plan.md` (§7b scopes per-window presentation), `x11/docs/native-ipados-protocol.md`.
- Wire: XIOS_IN_BIND=8 (scope a connection's input to one window id) — already reserved in xios_input_socket.h; IoscInput.c had 8 on-wire before the header did.

## Current state
- HostApp prototype builds + is protocol-conformant (engine verified earlier; awaiting a visual on-device confirm).
- The native host now replays the latest Wayland text-input TRAITS on scene activation/key-window activation and on tap, so the iPad keyboard can rise after the per-window host becomes the active UIKit scene.
- The native host now sends two-finger touch and continuous trackpad scrolling through the shared AXIS wire protocol, including an axis-stop frame for kinetic scrolling. The Release iPhoneOS host build passed on 2026-07-18; physical gesture validation is deferred while the device is offline.
- `xios_canvas.c` is implemented on the non-frozen side and retains enough window metadata to replay `WINDOW_NEW` + canvas ports when a host binds after a window already exists (jetsam/relaunch path).
- `iosc_gl_bind_target()` is factored out of `iosc_gl_resize()`; the compositor build includes `xios_canvas.c` so it stays compile-checked.
- `iosc.c` native mode now starts `iosc-native.sock`, creates/destroys per-window canvases on toplevel map/unmap, composites each toplevel into its own IOSurface, and handles host resize/activate/close requests on the Wayland event loop.
- `XIOS_IN_BIND` is honored by the shared input reader + iosc's bound-aware dispatch path: host scene input connections can now be scoped to a compositor window id, including native-mode keyboard TRAITS broadcasts for the focused window.
- Native launch is now explicit per request: iosc-host sends `LAUNCH_NATIVE`, and ioscd starts a native compositor namespace on `wayland-native-0` + `iosc-native-input.sock` + `xios-native.json`. Classic launchers keep `wayland-0` + `iosc-input.sock`, so native wrapped apps and the classic Xios desktop can coexist on the same device.
- Basic native launch has been reported working on-device. 2026-07-04 backend coexistence smoke through `ioscd` returned `LAUNCHED` for `LAUNCH_NATIVE\torg.gnome.Calculator\tgnome-calculator` while classic `wayland-0` stayed up. Device state showed `wayland-native-0`, `/var/jb/tmp/xios-native.json`, `iosc-native-input.sock`, `iosc-native.sock`, `iosc -native`, and `gnome-calculator` alive. Treat the remaining items below as physical host-window validation/polish, not as "core protocol missing" work.
- Build the compositor with just `x11/wayland/build-iosc.sh` (no docker flags): on the Mac it re-execs inside the cross-build image with the mounts wired, reads dev debs from `linux-build/out` then `repo/debs` as a fallback, and host-signs `wayland/out/iosc` (GPU/IOSurface/task_for_pid DER entitlements) so it is device-ready. `IOSC_NO_SIGN=1` skips signing; `IOSC_XBUILD_IMAGE=` overrides the image.

## On-device Home Screen app sync
- The old Mac-side `gen-launchers.sh --native` path remains useful for dev/test,
  but the device now has the pieces for on-device `.desktop` -> `.app` sync:
  `xios-icon-render` renders PNG/SVG theme icons through gdk-pixbuf into the iPad
  SpringBoard icon sizes, and `xios-launcher-sync` scans
  `/var/jb/usr/share/applications`, writes per-app `Info.plist` files, copies the
  shared `IOSCHost`/`default.metallib` payload, signs bundle executables, and can
  call `uicache`.
- Dev installer: `x11/apps/iosc-desktop/install-launcher-tools.sh`. It installs
  `/var/jb/usr/local/bin/xios-icon-render`, `/var/jb/usr/local/bin/xios-launcher-sync`,
  and shared payloads/entitlements under `/var/jb/usr/libexec/xios-launchers`.
- Package path: `x11/apps/iosc-desktop/package-launcher-tools.sh` reserves
  `xios-launcher-tools_0.1.1_iphoneos-arm64.deb` for the updated native host; 0.1.0
  remains published. The 0.1.1 payload built and staged on 2026-07-18, but final
  `xmkdeb` assembly is pending Docker recovery. The package ships `ioscd`,
  `xios-icon-render`, `xios-launcher-sync`, `IOSCLaunch`, `IOSCHost`,
  `default.metallib`, the entitlements, and
  `/var/jb/Library/LaunchDaemons/com.max.ioscd.plist`. Postinst re-signs the
  payloads best-effort and bootstraps `ioscd`; it does **not** run a mass
  `xios-launcher-sync --sync`, so Home Screen app creation remains settings- or
  user-triggered.
- `ioscd` exposes settings-pane-ready verbs on `/var/jb/tmp/ioscd.sock`:
  `APPS_LIST`, `APPS_SYNC\t<native|classic>\t<dry>`,
  `APP_ENABLE\t<app_id>`, and `APP_DISABLE\t<app_id>`. Responses are streamed
  and end with `APPS_END\t<status>`.
- Xios.app now exposes those verbs from the in-app Displays & Sessions sheet:
  **Home Screen Apps** lists launcher candidates from `APPS_LIST`, searches by
  name/exec/id, toggles enable/disable with `APP_ENABLE`/`APP_DISABLE`, and runs
  dry/apply sync for native or classic bundles with a streamed report. It is also
  reachable from the desktop context menu.
- Settings.app pane: `x11/../tweaks/XiosPrefs` builds
  `com.max.xiosprefs_0.1.0_iphoneos-arm64.deb`. It installs
  `/var/jb/Library/PreferenceBundles/XiosPrefs.bundle` plus
  `/var/jb/Library/PreferenceLoader/Preferences/Xios.plist`, depends on
  `xios-launcher-tools`, and exposes the same `ioscd` list/toggle/dry-run/apply
  controls in the native iOS Settings app. The controller sets explicit
  `PSButtonActionKey` values, handles button rows by stable ids as a fallback,
  and bounds `ioscd` socket reads so Settings cannot hang on an incomplete daemon
  reply. It also ships PreferenceLoader-sized `icon.png`, `icon@2x.png`, and
  `icon@3x.png` assets derived from Xios.app's icon; the registration plist uses
  `<key>icon</key><string>icon</string>` so the Settings sidebar shows the Xios
  icon instead of a blank row.
- On-device validation done: renderer compiled/runs on iPad and rendered
  `org.gnome.Console.svg`; staged sync generated a complete native `mpv.app` and
  `org.pwmt.zathura.app` under `/var/jb/tmp`; daemon verbs returned the 14 visible
  app candidates and toggled `footclient` enable/disable state. `foot-server` is
  currently disabled in prefs as a sanity example.
- Package validation done: `xios-launcher-tools 0.1.0` installed on-device via
  `dpkg -i`, restored `/var/jb/tmp/ioscd.sock` as `mobile:mobile` mode `660`,
  listed apps through the packaged `xios-launcher-sync`, rendered
  `org.gnome.Console.svg` into all three iPad icon PNG sizes, and returned
  `APPS_END\t0` for both `APPS_LIST` and `APPS_SYNC\tnative\tdry`.
- Settings-pane build/deploy done: Xios.app Release `iphoneos` build succeeded,
  deployed to `/var/jb/Applications/Xios.app`, relaunched, and adopted the active
  iosc IOSurface (`iosurface-zerocopy 2880x2160 [metal]`, input connected).
  Backend smoke after deploy returned `APPS_END\t0` for `APPS_LIST` and
  `APPS_SYNC\tnative\tdry`. Remaining validation is a physical/tap-through UI
  check of the new sheet and one controlled apply sync.
- Settings.app PreferenceBundle validation done: `com.max.xiosprefs 0.1.0`
  built, installed, copied to the repo deb pool, and reflected in regenerated
  local repo metadata. On-device package contents include the bundle and
  PreferenceLoader registration plist; `preferenceloader 2.2.8` and
  `xios-launcher-tools 0.1.0` are installed. Backend validation through
  `/var/jb/tmp/ioscd.sock` returned `APPS_END\t0` for native dry-run after the
  Settings hardening pass. A URL launch attempt starts Preferences without a
  fresh crash. The installed bundle now contains the three PreferenceLoader icon
  PNGs and the installed registration plist contains the `icon` key. USB
  screenshot capture was unavailable (`idevicescreenshot`: no device found), so
  visual confirmation in Settings.app is still pending.

## Hardening (2026-07-02, from the native-integration review)
- **Blocking mach hand-off moved off the compositor thread.** `deliver_canvas_port`
  (task_for_pid + a timed mach_msg a suspended host can stall) previously ran on
  iosc's wl event-loop thread under `s_lock` from `xios_canvas_announce`/`_geom`,
  so a window mapping/resizing against a slow host could freeze every other native
  window's input+present. Now the wl thread only flags the window
  (`deliver_pending`) + nudges the reader thread; the reader does the record write
  (still under the lock, on a non-blocking fd) + the unlocked mach send in
  `process_pending_deliveries`. Single-threaded delivery keeps each
  {WINDOW_NEW/GEOM, port} pair correlated for `recv_canvas`. `announced` still gates
  DIRTY so it can't precede WINDOW_NEW.
- **Map/unmap race closed.** `xios_canvas_gone` now sends WINDOW_GONE regardless of
  `announced` (a WINDOW_NEW may be in-flight on the reader thread); a GONE for a
  window the host never saw is a harmless no-op there. Prevents an orphaned scene.
- **Socket is never world-writable.** The `0777` fallback in
  `xios_canvas_server_start` is gone; it now locks the rendezvous socket to mobile
  (uid 501 fallback if `getpwnam` fails), degrading to root-only 0600 + a warning
  rather than opening it to every uid (app_id is the flavor's only isolation).
- **First frame fits the tapped scene.** BIND's scene size is remembered
  (`xios_canvas_default_scene`) and `send_initial_configure` sizes a native
  toplevel's initial xdg configure to it, so the first mapped frame fills the iPad
  window instead of flashing a default size then reflowing on the first RESIZE.
- **Deploy re-signs on device + registers cdhash.** `gen-launchers.sh --deploy`
  now stages the entitlements, `ldid -S`-resigns each bundle's on-device binary,
  and best-effort trust-cache-adds the cdhash (jbctl/trustcache/ellekitc) before
  uicache — the plan §6 "launch error 3" guard. ldid ad-hoc alone suffices on
  palera1n/ellekit; the trust-cache step is non-fatal.

## Open items
1. Record the on-device demo result in this file: `gen-launchers.sh --native`, tap a generated app, confirm it opens as its own iPad window, resizes, focuses, accepts text, and closes cleanly.
2. Physical coexistence smoke: keep a classic Xios desktop up, tap a native generated app, and confirm both compositor sockets/configs stay live (`wayland-0`/`xios.json` and `wayland-native-0`/`xios-native.json`) while the UIKit host window is visible. Backend-only coexistence via `ioscd LAUNCH_NATIVE` passed on 2026-07-04.
3. **Touch coordinate transform per-window**: verify the host unprojects touches against the canvas's own fb size for every scene.
4. Validate jetsam/relaunch replay: open a native-hosted app, kill/relaunch the host, confirm `WINDOW_NEW` + the live canvas port are replayed from `xios_canvas.c`.
5. Confirm the keyboard hint path on device: focus a GTK/Qt text field inside a native-hosted window and verify the OSK appears when that scene is key.
6. Decide whether native mode should keep the classic output IOSurface for tooling/fallback or skip it later to save memory.
7. Visually validate the new Settings.app Xios pane on-device: open Settings,
   confirm the Xios entry appears, toggle one app off/on, run dry native/classic,
   then perform one controlled apply sync after confirming the visible candidate
   set. Also do the same quick tap-through for the in-app shortcut.

## Priority
Core path is implemented; next pass is validation notes + polish closure.
