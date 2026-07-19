# xios-fhs: a unix-y filesystem + hardware bridge for the Xios desktop

Goal: desktop software (GNOME today, KDE later) finds screen brightness, battery state and
standard paths where it expects them, without per-app hacks. Rootless constraint: we cannot
touch the real `/`, `/sys` or `/proc`; everything lives under `/var/jb`, and every consumer is
a binary WE cross-build, so "the right place" is a convention our patches share, not a kernel
mount.

Two halves:

1. **Hardware bridge** — one small fakesigned daemon (`xios-hwbridged`) that owns the iOS
   hardware APIs (IOKit power sources, BackBoardServices brightness) and presents them as
   (a) the `org.freedesktop.UPower` D-Bus service and (b) a synthetic sysfs tree.
2. **Static FHS** — the package also lays down the `/var/jb/sys` skeleton and the few
   standard files worth having (`os-release`), and documents what the session layer already
   provides so we stop re-deciding it.

## 1. Survey: what the desktop stack actually reads

### gnome-shell 46 (battery indicator + brightness slider)

- **Battery**: `js/ui/status/system.js` statically imports `gi://UPowerGlib` (this is the
  boot-blocker that forced the libupower-glib client build, commit b142e2f). `UpClient`
  is a GDBus proxy on **`org.freedesktop.UPower`**; the indicator binds to the
  **DisplayDevice** object (`/org/freedesktop/UPower/devices/DisplayDevice`) and reads
  `IsPresent`, `State`, `Percentage`, `TimeToEmpty`/`TimeToFull`. The shell **never touches
  /sys** for battery. Today no daemon owns that bus name, so the indicator shows nothing.
- **Brightness**: the slider (`js/ui/status/backlight.js`) is a proxy on
  **`org.gnome.SettingsDaemon.Power`** (`/org/gnome/SettingsDaemon/Power`, interface
  `...Power.Screen`, property `Brightness` 0-100). If gsd-power reports no backlight
  (Brightness = -1) the slider is hidden. The shell never touches /sys here either.

### gsd-power (gnome-settings-daemon 46) — currently DROPPED from our build

Verified against upstream 46.0 `plugins/power/gsd-backlight.c`:

- **All** udev/sysfs/logind/helper backlight code is inside `#ifdef __linux__`. Discovery is
  GUdev on the `backlight` subsystem (attrs read: `type`, `max_brightness`, `brightness`,
  parent `enabled`); writes prefer logind `Session.SetBrightness`, then the pkexec helper,
  then `gnome_rr_output_set_backlight()`.
- On a **Darwin build none of that code exists**: the only compiled path is GNOME-RR/X11
  backlight (useless under Wayland), so `GsdBacklight` init fails with "No usable backlight
  could be found!" and Brightness sits at -1.
- Consequence: we do NOT need udev emulation or a logind `SetBrightness` stub. We need a
  ~60-line Darwin backend patched into `gsd-backlight.c` that reads/writes plain files.
- gsd-power's battery side (low-battery notifications, `WarningLevel`) is `UpClient` again —
  same D-Bus service as the shell.
- gsd-power also wants mutter's IdleMonitor (present under gnome-shell) and logind
  `Inhibit`/`PrepareForSleep` (our `xios-login1-stub` already exports Inhibit).

### upower

- We ship **libupower-glib3 only** (`recipes/upower.mk` +
  `ports/upower/patches` drops the daemon/tools subdirs). The daemon normally
  reads `/sys/class/power_supply/*` via gudev on Linux;
  upstream also has bsd/openbsd/dummy backends, so the daemon core is portable — kept as the
  upgrade path (section 3), not the first move.

### KDE (later, flavor K)

- Battery: Solid talks the same `org.freedesktop.UPower` D-Bus API — served for free by the
  shim.
- Brightness: powerdevil uses its own KAuth helper on `/sys/class/backlight` (plus ddcutil).
  Needs its own small patch against the same synthetic tree when we get there. Out of scope
  now; noted so the tree layout is chosen with it in mind.

### Static paths (what already exists vs missing)

Already provided today (don't duplicate):

- `XDG_RUNTIME_DIR` = private per-session dir, `WAYLAND_DISPLAY`, `HOME=/var/jb/var/root`,
  `PATH` — set by `ioscd` (`apps/iosc-desktop/src/ioscd.c`) and the run scripts.
- `/var/jb/etc/{X11,fonts/conf.d,xdg/gtk-3.0,xdg/gtk-4.0}`, `/var/jb/etc/profile.d/xios.sh` —
  `xios-desktop-defaults`.
- `/var/jb/tmp` (1777) — ioscd; Procursus base owns `/var/jb/{etc,var,usr}` proper.

Missing, in scope for this package:

- `/var/jb/sys/class/backlight/xios_backlight/` and
  `/var/jb/sys/class/power_supply/{BAT0,AC0}/` — the synthetic sysfs (below).
- `/var/jb/etc/os-release` — written by postinst if absent (`gnome-control-center` About and
  the usual tools read it; only patched readers resolve it since real `/etc` is Apple's —
  cosmetic, cheap).

Out of scope, recorded so nobody re-derives them: `/proc` emulation (libgtop consumers like
gnome-system-monitor need a dedicated port, nothing in the boot path reads /proc), a real
FUSE `/sys` (no usable FUSE on jailbroken iOS 17 — palera1n ships no kernel FUSE; the
NFS-loopback tricks are far hackier than files), `/var/jb/run` (session bus dirs are already
per-session under XDG_RUNTIME_DIR; revisit only if a port hardcodes it).

## 2. Design

### Mechanism choice

- **FUSE synthetic /sys** — rejected: no clean FUSE on iOS 17 jailbreaks, and it would still
  live at `/var/jb/sys`, so it buys nothing over plain files for our patched readers.
- **Battery via synthetic sysfs + real upowerd** — rejected for now: needs a Docker rebuild
  of upower with a new backend AND the daemon carries history/statistics machinery nothing
  uses; the D-Bus surface the clients need is small and stable.
- **Chosen: small daemons, Linux-shaped faces.** `xios-hwbridged` (GLib/GDBus, same
  build pattern as the session stubs in `wayland/build-session-stubs.sh`):
  - claims **`org.freedesktop.UPower`** on the session bus (the session runs with
    `DBUS_SYSTEM_BUS_ADDRESS` pointed at the session bus, so system-bus clients land there —
    same trick as login1/polkit/accounts stubs);
  - maintains the **synthetic sysfs** under `/var/jb/sys` (`XIOS_SYS` env override) for
    file-based consumers, and watches the backlight `brightness` file for writes.

  `xios-sensord` is the sibling for low-rate CoreMotion data. It owns
  `net.hadess.SensorProxy` on the bus and mirrors accelerometer/gyroscope/magnetometer
  readings into `$XIOS_SYS/bus/iio/devices/iio:device0`. Camera, microphone and location
  stay out of this package's first wave: they need streaming or TCC-specific bridges.

### Battery: UPower D-Bus shim backed by IOKit

Data source: `IOPSCopyPowerSourcesInfo()` / `IOPSCopyPowerSourcesList()` /
`IOPSGetPowerSourceDescription()` (IOKit, resolved via `dlopen` of
`/System/Library/Frameworks/IOKit.framework/IOKit` — no SDK tbd/header dependency), plus
`IOPSNotificationCreateRunLoopSource` for push updates (CFRunLoop integrates with the GLib
main loop via a GSource wrapper or a 30 s fallback poll; v1 polls, notification is a fast
follow). Keys used: `Current Capacity` (0-100 on iOS), `Is Charging`, `Power Source State`,
`Time to Empty` / `Time to Full Charge` (minutes, -1 = unknown → 0 = upower-unknown),
`Is Present`.

D-Bus surface (all that UpClient 1.90 + gnome-shell 46 + gsd-power 46 consume):

- `org.freedesktop.UPower` on `/org/freedesktop/UPower`: `EnumerateDevices` → `[battery_BAT0,
  line_power_AC0]`, `GetDisplayDevice`, `GetCriticalAction` → "PowerOff"; properties
  `DaemonVersion` ("1.90.2-xios"), `OnBattery`, `LidIsPresent`/`LidIsClosed` (false);
  signals `DeviceAdded`/`DeviceRemoved` (declared, never fire — devices are static).
- `org.freedesktop.UPower.Device` on `.../devices/DisplayDevice`, `.../devices/battery_BAT0`,
  `.../devices/line_power_AC0`: `Type` (2 battery / 1 line-power), `State` (1 charging,
  2 discharging, 4 fully-charged, 5 pending-charge), `Percentage`, `TimeToEmpty`/`TimeToFull`
  (seconds), `IsPresent`, `PowerSupply`, `Online` (AC), `IconName` (upower's classic
  full/good/low/caution[-charging] mapping), `WarningLevel` (none / low ≤20% / critical ≤5%,
  upower's default thresholds — gsd-power's notifications key off this), `BatteryLevel` = 1
  (fine-grained), `Vendor`="Apple", `Refresh` method (re-polls). `PropertiesChanged` emitted
  on every change, which is what UpClient/exported properties bind to.

### Brightness: synthetic backlight + file-watch + BackBoardServices

- Tree (Linux `backlight` class shape, so the gsd patch stays dumb):

      /var/jb/sys/class/backlight/xios_backlight/
        max_brightness    "1000"  (constant)
        brightness        desired value 0-1000; ANYONE may write
        actual_brightness current hardware value, daemon-refreshed
        type              "raw"

- `xios-hwbridged` watches `brightness` with a GFileMonitor **on the directory** (survives
  the atomic-rename writes `g_file_set_contents()` does) and applies value/1000.0 via
  BackBoardServices: `BKSDisplayBrightnessSet(level, 1)` inside a
  `BKSDisplayBrightnessTransactionCreate` transaction (the Activator/flipswitch-proven
  pattern; resolved via dlopen of the private framework). A 10 s timer re-reads
  `BKSDisplayBrightnessGetCurrent()` and refreshes `actual_brightness` (+ `brightness`, so
  the gsd slider tracks Control Center changes). Re-applying a value the daemon itself wrote
  is idempotent, so no loop-breaking state is needed.
- **Shell slider WITHOUT gsd-power:** the daemon also claims
  `org.gnome.SettingsDaemon.Power` on the session bus and serves the `...Power.Screen`
  interface (readwrite `Brightness` percent, `StepUp`/`StepDown`/`Cycle`, XML copied
  verbatim from gsd 46) mapped onto the same BKS path. gnome-shell's quick-settings slider
  shows whenever `Brightness >= 0`, so brightness UX does not depend on porting gsd-power
  at all. Context: the gsd-power port stalled on a real wall — its non-Linux backlight path
  IS gnome-rr, which our GTK4 gnome-desktop drops, plus a GTK-skeleton include — so the
  port is a multi-file job pending a lead priority call. If it ever lands, set
  `XIOS_HWBRIDGE_NO_GSD_SHIM=1` (the daemon treats not getting the name as a normal
  hand-off, not an error) and its GsdBacklight reads the file node via the 0001 patch. What
  the shim does NOT cover (gsd-power's remaining value): idle-dim, auto-suspend policy,
  low-battery notification actions.
- **gsd side (patch delivered, port ON HOLD):** the `power` plugin un-drop is in
  `ports/gnome-settings-daemon/patches` (gnome-session owner: canberra no-op'd, raw-X11
  screensaver/DPMS gated `!__APPLE__`, canberra/x11/xext meson deps dropped). The Darwin
  backend is
  `linux-build/patches/gnome-settings-daemon/0001-gsd-backlight-darwin-xios-node.patch`
  (applies `-p1`, verified against pristine 46.0; glib API usage syntax-checked via an
  extracted harness): probes `$XIOS_SYS/class/backlight/xios_backlight/` in
  `gsd_backlight_initable_init` (min=0, max/val raw from the files, ahead of the RR
  fallback), writes `brightness` in `gsd_backlight_set_brightness_val_async` with
  `g_file_set_contents`, reports connector "xios", frees the path in finalize. No logind,
  no pkexec, no udev. NOTE `g_file_set_contents` writes temp+rename, so the node
  DIRECTORIES must be writable by the session uid — the xios-fhs postinst chowns the tree
  to 501 and marks the leaf dirs 0775 for exactly this.

### Torch: synthetic leds node + file-watch + AVCaptureDevice

Same shape as brightness, one class down. The Plasma Mobile flashlight quicksetting
(`quicksettings/flashlight`) normally finds a real torch LED via **libudev**
(`/sys/class/leds/*:torch`, match on `color == white`) and toggles the `brightness` sysattr.
There is no libudev or hardware LED node on iOS, so:

- `xios-hwbridged` exposes a synthetic Linux `leds` node at `<sys>/class/leds/xios:torch`
  (`color`, `function`, `max_brightness`, `brightness`), watches the directory, and on a
  `brightness` write drives the camera torch through **AVCaptureDevice**
  (`defaultDeviceWithMediaType:` → `lockForConfiguration:` → `setTorchMode:` → unlock).
  AVFoundation is `dlopen`'d like IOKit/BackBoardServices (only `AVMediaTypeVideo` is needed
  as a symbol); `-lobjc` is linked for the `objc_msgSend` calls. Signed with the added
  `kTCCServiceCamera` entitlement; no capture session is ever started.
- **Truthful availability**: the daemon publishes `max_brightness=1` only when
  `[device hasTorch]`, else `0`. The flashlight backend (rewritten in
  `plasma-mobile-ios-fixes.sh` to drop libudev and read/write this node) reports
  `available` from `max_brightness > 0`. **Most iPads have no rear torch LED**, so on that
  hardware the tile is correctly unavailable/hidden; it only lights up on a device with a
  camera flash. `brightness` is world-writable and never rewritten by the daemon, so the
  unprivileged shell can toggle it in place regardless of daemon uid.
- Startup ordering: the daemon (session launcher, before plasmashell) seeds the node before
  the tile's `available` (CONSTANT) is read. postinst also seeds it with `max_brightness=0`
  so file-based readers see something pre-daemon.

### Risks / open validation

- `BKSDisplayBrightnessSet` from a fakesigned standalone daemon is the standard jailbreak
  route but unverified on 17.6.1 from OUR daemon; build script signs with
  `com.apple.backboard.client` + platform-application entitlements. Fallbacks if backboardd
  refuses: IOMobileFramebuffer brightness, or a SpringBoard-side helper via notify tokens.
- IOPS on iOS reports percent granularity only (no energy/rate); `TimeToEmpty` is often -1
  early after state changes — clients handle 0 (unknown) fine.
- Torch: `AVCaptureDevice` torch control from a headless fakesigned session daemon is
  unverified on 17.6.1 from OUR daemon (well-established for CLI torch tools generally). The
  test iPad (7th gen) has **no torch LED**, so end-to-end validation needs torch-capable
  hardware; on the test device the correct result is `hasTorch == false` → tile hidden. If
  backboardd/TCC refuses torch access despite `kTCCServiceCamera`, `probe_torch()` returns
  false and the daemon runs battery/brightness unaffected.
- upowerd upgrade path if we ever want history/statistics: keep `-Dos_backend=dummy`, stop
  dropping `src/` in `ports/upower/patches`, overlay `src/dummy/up-backend.c` with an IOKit
  implementation, link `-framework IOKit`. The shim's D-Bus surface is a strict subset, so
  the swap is invisible to clients.

## 3. Package: `xios-fhs`

`x11/packages/xios-fhs/` (layout-style package like xios-desktop-defaults, plus a compiled
daemon dropped in by the build script):

- `DEBIAN/control` — Package: xios-fhs; Depends: libglib2.0-0. Provides: xios-hwbridge, xios-sensor-bridge.
- `DEBIAN/postinst` — creates `/var/jb/sys/class/{backlight/xios_backlight,power_supply/{BAT0,AC0}}`
  and `/var/jb/sys/bus/iio/devices/{iio:device0,trigger0}` (mobile-writable), seeds
  `max_brightness`/`type` and sensor identity/scale files, writes `/var/jb/etc/os-release`
  if absent.
- `var/jb/usr/libexec/xios-hwbridged` — the power/brightness daemon (built by `build-hwbridge.sh` in the
  Procursus cross image, session-stubs pattern; ldid with entitlements).
- `var/jb/usr/libexec/xios-sensord` — the CoreMotion/SensorProxy/IIO daemon (same build script,
  signed with `sensor-entitlements.plist`).
- Launch: session component next to the login1/polkit/accounts stubs (the xios.session
  wrapper the gnome-session layer owns starts it on the session bus). NOT a LaunchDaemon —
  it needs the session bus, and brightness/battery only matter while a desktop runs.
- Source: `packages/xios-fhs/src/xios-hwbridged.c`, `packages/xios-fhs/src/xios-sensord.m`.

Sysfs battery files (informational mirror for file-based tools; the D-Bus shim is the
authoritative path and reads IOKit directly): `BAT0/{type,present,status,capacity,model_name,
manufacturer,scope}`, `AC0/{type,online}`, refreshed on the same poll.

## 4. Status

- [x] Survey + mechanism decision (this doc)
- [x] Package skeleton: control/postinst, daemon source, build script
- [x] Sensor bridge added: `xios-sensord` serves `net.hadess.SensorProxy` and synthetic IIO
      accel/gyro/magnetometer nodes from CoreMotion
- [x] Build daemons in the Procursus image and package them (`xios-fhs 1.0.2`)
- [x] Device validation: IOPS battery state, BKS-backed brightness mirror, live
      CoreMotion/IIO values, and shell helper startup. See `docs/handoff/polish.md`
      for the captured 2026-07-04 values and remaining physical-gesture polish.
- [x] Darwin gsd-backlight backend patch (patches/gnome-settings-daemon/0001-...) — DORMANT:
      the gsd-power port is on hold (gnome-rr + GTK-skeleton walls); patch plugs into step 3
      of that port unchanged if the lead green-lights it
- [x] Shell brightness slider via the daemon's org.gnome.SettingsDaemon.Power.Screen shim
      (no gsd-power needed)
- [x] xios.session: xios-hwbridged added to the session launch (gnome-session, task #14)
- [x] Torch bridge: synthetic `class/leds/xios:torch` node + AVCaptureDevice torch in
      xios-hwbridged; Plasma Mobile flashlight tile backend swapped off libudev onto it
      (plasma-mobile-ios-fixes.sh). The daemon and Plasma packages were rebuilt;
      physical torch validation remains hardware-gated because the target iPad
      does not expose a rear torch LED.
- [ ] Flavor-K follow-up: powerdevil backlight patch against the same tree
