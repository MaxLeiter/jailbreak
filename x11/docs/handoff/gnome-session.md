# gnome-session: the GNOME session layer and the Shell boot

Owns getting GNOME Shell 46 from "installed" to "running" on the iPad: the session layer
(gnome-session, gnome-settings-daemon, dconf, the D-Bus stubs), the packaged launcher, and the
package closure behind `xios-gnome`. GNOME Shell is Mutter plus the gjs UI, so the compositor
half lives in [mutter.md](mutter.md) and the typelibs in [gtk4-typelibs.md](gtk4-typelibs.md).

## Current state (checked against repo/Packages, 2026-10-25)

GNOME Shell boots, paints and takes input on the A10. It ran as a slot next to KDE and the iosc
shell in the Xios v2 M0 tests (2026-10-06), at about 110 MB idle and about 220 MB with two apps
open (numbers in [../xios-v2-notes.md](../xios-v2-notes.md)).

What ships, from the published index:

| Package | Version | Notes |
|---|---|---|
| `xios-gnome` (meta) | 0.1.12 | the flavor; closure below |
| `gnome-shell` | 46.0+ios3 | atk-bridge disabled, Rsvg and EDS patched out, GDM promisify guard |
| `libmutter-14-0` | 46.0+ios11 | MetaBackendIOS, see mutter.md |
| `gnome-session` / `gnome-settings-daemon` | 46.0+ios1 | non-systemd build / minimal plugin set |
| `xios-session-stubs` | 0.2.12 | stubs, `xios-sysintd`, `xios-setsid`, the GNOME launcher |
| `xios-gnome-typelibs` | 0.2.0 | the regenerated boot typelibs |
| `libgdm1` / `libgweather-4-0` | 46.0+ios2 / 4.4.2+ios2 | carry the login-screen schema / `Locations.bin` |
| `libgjs0`, `gjs` | 1.78.0+ios1 | JIT-less mozjs by default |

`xios-gnome 0.1.12` (x11/packages/meta/xios-gnome/DEBIAN/control) depends on `xios-core (>= 0.1.13)`,
`gnome-shell`, `libmutter-14-0 (>= 46.0+ios10)`, `gnome-session`, `gnome-settings-daemon`, the gi://
client libs the Shell imports without declaring (`libaccountsservice0`, `libgdm1`, `libgeoclue-2-0`,
`libgeocode-glib-2-0`, `libgweather-4-0`, `libupower-glib3`), `xios-session-stubs (>= 0.2.10)`,
`xios-gnome-typelibs` and `xios-desktop-theme`. It recommends `gnome-console`, `nautilus`,
`gnome-text-editor` and `gnome-calculator`. Since `xios-session 1.0.82`, `xios-session` itself
depends on `xios-session-stubs`, so the stubs no longer arrive only through this flavor.

Launch: `xios-session gnome` from a shell, or pick GNOME in the Xios app (which goes through
ioscd's `SESSION` request, the same as `xios-session -d gnome`). `xios-session presets` lists what can
start; GNOME is refused before teardown if `gnome-shell`, `gnome-session` or `xios-setsid` is
missing (see [session-launcher.md](session-launcher.md)).

### How the launch works

`xios-session` calls `launch-gnome-session.sh` (source:
`x11/packages/templates/xios-session-stubs/files/usr/bin/launch-gnome-session.sh.in`). It:

1. checks that the installed `gnome-shell` already carries the GPU entitlements
   (AGXDeviceUserClient, IOGPUDeviceUserClient, IOSurfaceRootUserClient) and that the `angle`
   package's Linux-style `libEGL.so.1`/`libGLESv2.so.2` links and Mutter's plugin `.so` aliases
   exist. It no longer re-signs or edits anything installed; a missing piece is a reinstall hint.
2. makes a private `0700` runtime dir (`xios-run[-<slot>]`) and per-run config/data homes.
3. starts one `dbus-run-session` through `xios-setsid`, points `DBUS_SYSTEM_BUS_ADDRESS` at that
   session bus, writes the bus address and the session's process group to per-slot files, and
   starts the login1, polkit, accounts and BlueZ stubs, `xios-hwbridged`, `xios-sensord`,
   PulseAudio (`xios-pulse.sh`) and `xios-sysintd` on it.
4. execs `gnome-session --builtin --session=xios`. The packaged `xios.session` lists only
   `org.gnome.Shell`; its `.desktop` runs `xios-gnome-shell-session`, which starts the Shell under
   `xios-gnome-session-client`. That small adapter registers the Shell with gnome-session over
   D-Bus, because Mutter's own session client is XSMP and only exists in X11 builds. An exit the
   session did not ask for is reported as a failure, even with status 0, so gnome-session treats
   it as a crash.
5. waits for `xios.json` and the Mutter DDX socket, hands the socket to `mobile`, and relaunches
   Xios.

Per-slot sockets and files carry a `-<slot>` suffix (`mutter-<slot>-ddx.sock`, `xios-<slot>.json`,
`gnome-shell-<slot>.log`).

### Success signal

Do not gate on `xios.json`: Mutter writes it before the JS UI loads. Read the Shell log
(`/var/jb/tmp/gnome-shell[-<slot>].log`):

- compositor up: `xios.json` plus `MetaRendererIOS create_view`
- shell painted: `GNOME Shell started at`
- failed: `JS ERROR`, `Execution of main.js threw exception`, `Requiring <NS> couldn't be found`,
  `Failed to load module`, or a nil `MTLCreateSystemDefaultDevice`

`xios-session status` reports `state=up` with `GNOME Shell started` when the poller sees it.

## Open items

- **Pencil, scroll, touch and text input** are covered in [../gnome-touch-ux.md](../gnome-touch-ux.md)
  and mutter.md. The Pencil still drives the pointer, not a tablet tool.
- **atk-bridge is still off in gnome-shell.** The original reason (ATK 2.38 vs at-spi 2.52) is gone:
  `libatk1.0-0` is 2.52.0+ios2 now. Re-enabling it means dropping the atk-bridge hunk from
  `ports/gnome-shell/patches/0001-ios-source-port.patch` and rebuilding the Shell. That is also the
  prerequisite for GNOME in the AT-SPI to VoiceOver bridge.
- **Calendar is still patched out.** `evolution-data-server 3.52.4+ios2` is published, but
  `gnome-shell` is built with `GNOME_SHELL_WITH_EDS=0`. A `WITH_EDS=1` shell build exists in the
  recipe and has not been shipped.
- **Unpublished recipe fixes:** `libgnome-desktop` (iso-codes prefix) and `ibus` (rootless
  machine-id) are at `+ios2` in the recipes but the index still serves `+ios1`, so the two log
  warnings below persist until they are rebuilt and published.
- **Known nonfatal log noise:** IBus asks for `/var/lib/dbus/machine-id`; GnomeDesktop looks for
  iso-codes under the build root; `org.gnome.Shell.Screencast` wants `Gst-1.0.typelib`;
  CalendarServer, GeoClue, colord and the polkit agent are absent; `meta-barrier` warnings
  (MetaBackendIOS has no pointer barriers); "Error registering session with GDM" (there is no GDM).
- **gsd plugins:** only a11y-settings, housekeeping, keyboard and screensaver-proxy are built. The
  per-plugin reasons and what re-enabling would take are in
  [../gnome-session-plan.md](../gnome-session-plan.md).
- **Typelib reproducibility:** the boot typelibs in `xios-gnome-typelibs` were scanned on the
  device. The scan scripts are in `x11/linux-build/gir-build-*-ondevice.sh`; regenerating them is
  still a device job.

## Landmines (root causes worth keeping)

- **The first-paint SIGKILL was Gvc, not the GPU.** GNOME Shell used to die about 3.5 s in, exit
  137, no crash report, no jetsam event. Bare Mutter survived, so the backend was fine. The cause was
  `new Gvc.MixerControl()` hanging in its constructor on the compositor main thread (a broken
  PulseAudio module rpath), so the compositor stopped servicing the display and was killed. Fixed by
  fixing PulseAudio packaging; the temporary volume ectomy is gone and the Quick Settings slider is
  back (the `quickSettings.js` hunk of the port patch guards the missing slider accessibility
  handoff). If the Shell dies silently
  at first paint again, check `DYLD_PRINT_LIBRARIES` for what loaded last before suspecting the GPU.
  To read the signal of a SIGKILL on device: `timeout N cmd; echo EXIT=$? > file` in a foreground
  run, since SIGKILL leaves no `.ips`.
- **"Missing required core component Settings" is a red herring.** It only means no
  `org.gnome.Settings.desktop` is installed.
- **Typelib scans can silently drop methods.** The header-scan route produced 200-byte stub
  typelibs for Atk, Gcr, Atspi and PolkitAgent (`Namespace is empty`, or `#error Only <x.h> can be
  included directly`). Fix: build each library from source with introspection on, on the device,
  so its own meson drives g-ir-scanner. And re-scan St-14/Shell-14 after Atk is real, or every
  method with an `Atk.*` parameter is dropped. Per-library flags are in gtk4-typelibs.md.
- **Gdm-1.0 `_finish` methods missing.** The scanned Gdm typelib lacked the `_finish`/`_sync`
  pairs even though `libgdm.dylib` exports them. The Shell's `js/gdm/util.js` now promisifies only
  when `<name>_finish` exists (there is no GDM daemon on iOS anyway). `Gdm.get_session_ids` came
  back after the gated-`generate_gir` fix in `ports/libgdm/patches`.
- **Packaging gaps that looked like runtime bugs:** the libgweather deb once dropped
  `Locations.bin` (GWeather aborts with `assertion failed: (db)`), and gnome-shell does not ship
  `org.gnome.login-screen.gschema.xml` (it comes from GDM). Both are owned by their source packages
  now; keep it that way rather than copying files onto the device.
- **The stubs must start inside the same `dbus-run-session`.** login1, polkit and accounts are
  system-bus names; `DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS` makes stubs and clients
  agree. A stub started outside that tree lands on a different bus or none.
- **Find the right pid.** gnome-shell re-execs through `xios-gnome-session-client`, so the pid you
  launched is not the compositor. Measure the `gnome-shell --wayland --wayland-display ...` child.
- **On-device tooling:** no `bc`, no `log`, `ps aux` column 6 is not RSS, no `/bin/sh` (rootless
  uses `/var/jb/bin/sh`).
- **Do not `apt --fix-broken` a half-installed GNOME set.** It can remove libmutter. See the
  libwayland ordering note in mutter.md. Users install `xios-gnome` through apt, which orders the
  closure itself. For loose debs from a local build, `x11/linux-build/install-gnome-boot.sh` does an
  ordered `dpkg -i` plus a one-pass fetch of missing external dependencies; check with
  `apt-get check` afterwards. A dpkg conflict line between `libmozjs-115-0` and
  `libmozjs-115-jit-0` is expected (the JIT build provides, conflicts with and replaces the plain one).

## History (short)

- 2026-07-01: first manual Shell launch; compositor came up, JS died on a stale binary (atk-bridge
  link and an `import Rsvg` at boot). Rebuilt with patch 4b (atk-bridge drop) and patch 6 (Rsvg
  ectomy). St still draws SVG icons through the gdk-pixbuf librsvg loader.
- 2026-07-02: typelib walls cleared (Atk/Atspi/Gck/Gcr/GnomeDesktop/GWeather rebuilt, St/Shell
  re-scanned, Gdm guarded), then the Gvc hang found. First light about 11:15 PDT.
- 2026-07-03 to 07-06: PulseAudio fixed so Gvc returns; `gnome-shell 46.0+ios3`; `xios-session gnome`
  moved from a direct Shell runner to `launch-gnome-session.sh` and gnome-session; ioscd's
  `SESSION` path execs `xios-session` through bash. The old `run-gnome-shell.sh` is gone.
- 2026-07-29: the launcher stopped editing installed files (verify only); the Shell registers with
  gnome-session through `xios-gnome-session-client`; strict v1 clipboard bridge in Mutter.
- 2026-10-01 audit wave: Mutter input fixes (real keycodes, modifiers, non-ASCII soft-keyboard text
  through the Shell's input method, held input released when a client drops), published as
  `libmutter-14-0 46.0+ios11`.
- 2026-10-06 (Xios v2 M0): GNOME runs as a slot; slot-suffixed sockets and runtime dirs, the
  session's process group recorded for slot-scoped stop.
