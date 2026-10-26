# session-launcher: the flavor switcher (CLI, ioscd, in-app picker)

Owns how a desktop gets picked, started, switched and stopped on the iPad: the
`xios-session` CLI and its shell library, ioscd's `SESSION` request path, and the backend
of the picker in the Xios app. It reuses the real bring-up scripts (`run-shell.sh`,
`run-mutter.sh`, `run-kde-plasma.sh`) and the packaged GNOME launcher instead of
reinventing them. The design overview is `docs/session-launcher.md`; the multi-desktop
design is `docs/xios-v2-design.md`.

## Current state (2026-10-25)

- Production serves `xios-session 1.0.82`, `xios-session-stubs 0.2.12`,
  `xios-launcher-tools 0.1.12` (ioscd), `com.max.xios 0.1.12`, `iosc 0.9.51` and
  `iosc-shell 0.9.14`. `xios-core 0.1.13` pulls all of them in; the flavor table is in
  `docs/repo-fold-in.md`.
- Desktops coexist (Xios v2 M0): several slots can run at once, each torn down on its own.
  Device-verified on 2026-10-06 (see "M0 coexistence").
- `xios-session` and `xios-launcher-tools` both depend on `xios-session-stubs` now, so
  every fullscreen flavor and every ioscd app launch has `xios-sysintd` (volume and dark
  mode bridge) and `xios-setsid`. Before 1.0.82 only `xios-gnome` brought them, so KDE and
  X11 sessions ran without the bridge and without process-group isolation.
- A flavor that is not installed is refused before the running desktop is touched, and
  `xios-session presets` lists what can start (ioscd `PRESETS` serves it to the app). Host-tested; no device run yet.
- ioscd starts its app-launch helpers per bus, not "once anywhere", and gives its own
  sysintd a private socket when a desktop already serves the global
  `/var/jb/tmp/xios-sysint.sock` (03da4e55). Host-tested; no device run yet.
- With `xios-x11` installed, the iosc preset starts Xwayland (rootless, under iosc's XWM)
  and `xios-session app` hands clients `DISPLAY` plus `GDK_BACKEND=wayland,x11`. Device
  proof and the XWM itself are in `iosc-compositor.md`.
- The app asks ioscd's `PRESETS` verb (0.1.14, below) and falls back to its own file check; it
  does not yet send appearance changes to every slot's sysintd (M1 work, see
  `docs/xios-v2-design.md`). No meta ships a standalone `mutter`, so the `mutter` preset
  only works on a dev install.

## Key files (under `x11/apps/iosc-desktop/` unless noted)

- `xios-session-lib.sh`: the one implementation. Presets call the bring-up scripts;
  `xs_preset_check` knows what each flavor needs; teardown is ownership-based (recorded
  process groups first, then exact slot needles, never a blind pattern over another
  slot). Normal switches keep the Xios app alive; `stop` with no slot alive also ends it.
- `xios-session`: the CLI. `xios-session iosc|mutter|gnome|kde|kde-desktop|kde-mobile|kde-nano|app <name>|resize|stop [all]|status|presets`,
  plus `--slot <name>` and `-d/--via-daemon`. Installed at `/var/jb/usr/local/bin/xios-session`,
  which is not on the default SSH `PATH`, so use the full path over SSH. Without `-d` it
  runs the library directly and needs no daemon; `-d` sends the same request the picker
  sends, over `nc`, then `socat`, then Python.
- `src/ioscd.c`: the root daemon behind `/var/jb/tmp/ioscd.sock` (`com.max.ioscd`,
  packaged in `xios-launcher-tools`). `SESSION` runs `/var/jb/usr/bin/bash
  /var/jb/usr/local/bin/xios-session ...`; optional fields carry width/height/dpi (exported
  as `IOSC_LOGICAL`) and a slot name (exported as `XIOS_SESSION_SLOT`). App launches take
  only an app id: ioscd resolves a trusted, root-owned desktop entry and starts the client
  and its session bus as `mobile`. Each `SESSION` request is logged with the peer
  pid/uid/path in `/var/jb/tmp/ioscd.log`, so you can tell who asked for a switch.
- `x11/wayland/run-iosc.sh`, `x11/apps/iosc-shell/run-shell.sh`, `x11/wayland/run-mutter.sh`,
  `x11/wayland/run-kde-plasma.sh`: bring-up scripts. They refuse to start over a live
  compositor of the same name instead of killing it.
- Runtime files in `/var/jb/tmp`: `xios-session-status.json` (non-slot lifecycle; the
  picker polls it), `xios-session-<slot>.json`, `xios-displays.d/<slot>.json` (registry the
  app lists), `xios-app-launch-status.json` (additive app launches, kept apart from the
  lifecycle record), `xios-session.lock`, `xios-session.request-seq`,
  `xios-session.pgids`, `xios-active-session[-<slot>]`.
- Host tests: `test-session-slots.sh`, `test-session-state.sh`, `test-session-preflight.sh`,
  `test-session-x11.sh`, `test-session-bus.sh`, `test-ioscd-helpers.sh` and
  `test-ioscd-fds.sh` (the last two run by `build-stub.sh`). `test-ioscd-helpers.sh` also covers
  `PRESETS` and the a11y helper's identity.

## How a switch works

1. Preflight: `xs_preset_check` refuses a flavor that cannot start (exit 69) before anything
   is stopped.
2. Lock: every state-changing command takes `xios-session.lock` (atomic `mkdir`, since iOS
   has no `flock`), waiting up to `XIOS_SESSION_LOCK_WAIT` (45 s) and reaping an owner older
   than `XIOS_SESSION_LOCK_STALE` (180 s). `app <name>` stays off the lock so a slow GUI
   launch cannot block desktop controls.
3. Supersede: switch requests bump `xios-session.request-seq` before waiting; a queued
   request that sees a newer one exits 75. The newest explicit request wins by design, so
   if a desktop "disappears", check `ioscd.log` for who asked.
4. Teardown, then settle (`XIOS_SESSION_SETTLE`, 2 s) so the kernel reclaims the old
   compositor's IOSurface and Metal context before the next one allocates. Without the
   settle the GPU memory spike jetsammed the Xios app.
5. Start, wait for the compositor surface, foreground or relaunch the app, write `up`.
   Status states: `stopping | starting | waiting | relaunching | up | error | stopped |
   compositor-only | down`. Teardown, the KDE exit monitor and ioscd write `down` when a
   live session dies, so the picker never shows a stale `up`.

Slot sessions do not foreground Xios unless `XIOS_SLOT_FOREGROUND=1`, so a test can start
a slot without stealing the screen. The stale-slot sweep (`xs_sweep_stale_slot_registry`,
off with `XIOS_SESSION_SWEEP_SLOTS=0`) drops registry entries with no socket, no config and
no live process, once per operation and under the lock.

## 2026-10-25: uninstalled flavors are refused before teardown (host-tested, not on device)

- The picker lists every preset, and a switch used to tear the running desktop down
  before the new preset looked for its bring-up. A KDE user who tapped GNOME lost KDE and
  got "launch-gnome-session.sh missing". Now `xs_preset_check` (next to the presets in
  `xios-session-lib.sh`) is the one place that knows what each flavor needs, and
  `xs_prepare_display_session` runs it first, so nothing is stopped for a flavor that
  cannot start. It checks the bring-up script `xs_find_bringup` would resolve plus the
  key binaries, with the same paths and env overrides as the run scripts: iosc =
  `usr/local/bin/iosc`; mutter = `$MUTTER` or `usr/bin/mutter`; gnome = `$SHELL_BIN` or
  `usr/bin/gnome-shell`, `gnome-session` on PATH, `usr/libexec/xios-setsid`; kde,
  kde-desktop, kde-nano, kde-mobile = `$IOSC_BIN`, `$KWIN_BIN`, `$PLASMA_BIN` (defaults
  under `/var/jb/Applications/KDE/`) and xios-setsid or setsid. It does not check the
  Plasma shell packages (mobile/nano); `xios-kde` depends on both.
- A refusal exits 69 and logs `<preset> cannot start: ... nothing was stopped`. If a
  desktop is live, its status record keeps its `preset` and `state` (ioscd, the KDE exit
  monitor and the picker key on those); only `message` changes ("GNOME is not installed:
  install xios-gnome") and `request`/`request_state:"error"` are added. With nothing live
  it is a normal `error` status for the requested preset; a refused slot gets no registry
  entry. ioscd counts the non-zero exit as a failure, so a non-root retry of that preset
  within 2 minutes hits the existing cooldown.
- `xios-session presets` prints the presets that can start, one per line (no lock, also
  answered locally with `-d`), for the app to hide uninstalled flavors later.
- `run-mutter.sh` says "Mutter is not installed: ..." instead of the scp hint.
  `run-kde-plasma.sh` starts iosc and the KWin session through `$LIBEXEC/xios-setsid`
  (falling back to `setsid`); the python3 shim it used to write is gone.
- Test: `apps/iosc-desktop/test-session-preflight.sh` (scratch prefix, fake live KDE,
  `xios-session gnome` must exit 69 and leave KDE, its status and pgids alone).

## ioscd helpers per bus, honest SESSION reply (2026-10-25, xios-launcher-tools 0.1.12, published)

- ioscd's app-launch helper guard was still the old "skip if any `xios-hwbridged`/`xios-sensord`/
  `xios-sysintd` runs anywhere" ps grep, so once a desktop ran its own helpers, Home Screen and
  picker launches got none on `ioscd-bus`. It now uses the shell lib's rule: one per bus,
  recorded in `<busdir>/<name>.pid` (`"<pid>\n"`), running while that pid is alive and its
  process name matches. Because the bus dir is mobile's and the helpers start as root, the pid
  files and `<name>.log` are unlinked and recreated through the dir fd (O_EXCL|O_NOFOLLOW) and
  bash writes through those fds, never by name. An empty pid file under 30 s old counts as a
  start in progress, so two quick launches do not double-start during `xios_pulse_start`.
- `SESSION` used to answer `SESSION_STARTED` even with no xios-session installed (bash just
  exited 127 in `ioscd.log`). ioscd now checks the script with `access(R_OK)` before forking
  and answers `ERR xios-session is not installed`. The `/usr/bin/xios-session` fallback exec
  was unreachable (the first exec is bash, which only fails if bash is missing) and is gone.
- The package now Depends on `xios-session-stubs (>= 0.2.12)`, which ships `xios-sysintd`; only
  the GNOME flavor pulled it in before. hwbridged/sensord still come from `xios-fhs`.
- Host test: `apps/iosc-desktop/test-ioscd-helpers.sh` (run by `build-stub.sh`).

## 2026-10-25 (later still): `PRESETS` verb, a11y helper as mobile (xios-launcher-tools 0.1.14, `com.max.xios 0.2.1`, host-tested only)

- **`PRESETS\n`** on `ioscd.sock` runs `bash xios-session presets` exactly like the `SESSION`
  child (root, `set_rootless_path`, stderr to `ioscd-session.log`) and replies one preset per
  line, then `PRESETS_END\t<exit status>` (the `APPS_END` shape). Only lines that look like
  a preset name (`[a-z0-9-]`, 31 chars) are relayed. It is bounded (4 s, then the child's
  group is killed and the reply is `ERR presets timed out`) because the accept loop is
  single-threaded; a missing script is `ERR xios-session is not installed`. An ioscd without
  the verb answers `ERR malformed`. Any peer may ask (read-only, like `APPS_LIST`).
- The Xios app (0.2.1) asks first and falls back to `PresetProbe` (its mirror of
  `xs_preset_check`) on an ERR, no ioscd, a non-zero status or an empty list. The
  `xios-core` pin on `xios-launcher-tools` stays `>= 0.1.13`: the fallback makes 0.1.14 optional.
- **The a11y helper on ioscd's bus now runs as mobile.** `start_a11y_for_busdir` used to run
  `xios-start-a11y` as root on every bus; ioscd's bus daemon is mobile's and refuses root
  clients, so at-spi-bus-launcher never reached it. The helper now takes the identity of the
  bus socket's owner: mobile (HOME/USER/LOGNAME, `close_inherited_fds`, `drop_to_mobile`) on
  `ioscd-bus`, root on `xios-session-bus` (the root CLI's bus). For mobile it also sets
  `XIOS_A11Y_SOCK=/var/jb/tmp/xios-a11y.sock` (same path as before; xios-a11yd chowns it to
  mobile 0660, which is what the app and `iosc-host` connect to), and moves the logs to
  `ioscd-bus/xios-atspi.log` and `ioscd-bus/xios-a11yd.log` (the old ones in the sticky tmp
  dir are root-owned, so mobile's `>>` redirect would fail).
- **Leftovers from the old root helper** (before it drops privileges, only for the mobile case):
  root-owned `ioscd-bus/at-spi` and `ioscd-bus/dconf` trees are chowned to mobile (children first,
  nothing followed, hard-linked files skipped); a root-owned `/var/jb/tmp/xios-a11y.sock` and
  `.pid` are unlinked unless the recorded `xios-a11yd` is still alive (a live one is left alone:
  it may be serving xios-session's bus, and `xios-start-a11y` will not start a second one).
- Host tests (`test-ioscd-helpers.sh`, run by `build-stub.sh`): PRESETS against stand-in scripts
  and against the real `xios-session` + lib on a scratch prefix; the a11y helper's env/fds for a
  mobile-owned and a foreign-owned bus; stale-leftover cleanup. The chown itself needs root and
  is not exercised on the host.
- **Device checks still open:** (1) `PRESETS` over the socket as mobile returns what
  `xios-session presets` prints as root, and the Xios app writes `source=ioscd` to
  `xios-presets.txt`; (2) with VoiceOver on, an ioscd `LAUNCH` starts `xios-start-a11y` as
  mobile (`ps -o user`), at-spi-bus-launcher and xios-a11yd own the bus, `xios-a11y.sock` is
  mobile 0660, and `ioscd-bus/at-spi` is mobile-owned; (3) an `xios-a11yd` left running as root
  by the old ioscd keeps `a11yd_running` true, so kill it once (or respring) before expecting the
  mobile one.

## M0 coexistence (2026-10-06): desktops run side by side

Shipped in `xios-session 1.0.81` with `xios-session-stubs 0.2.12`, `xios-a11y-tools 0.2.17`,
`iosc 0.9.49` and `iosc-shell 0.9.14`, all on production. No app or wire change. The old
GNOME launcher writes no pgid file and older `xios-a11y-tools` ignores `XIOS_A11Y_SOCK`, so
`xios-session` depends on `xios-session-stubs (>= 0.2.12)` and Breaks
`xios-a11y-tools (<< 0.2.17)`.

**Rules the launcher follows**

- Nothing is killed by pattern when it can be shown to belong to someone else. Ownership is,
  in order: a recorded process group (`xios-session.pgids`, checked against a live session
  process before it is signalled), then an argv needle that names the slot exactly
  (`xs_slot_regex`: `wayland-<slot>`, `kwin-<slot>`, `iosc-<slot>-ddx.sock`, ... each ends at a
  character that cannot continue a slot name, so `kde` never matches `kde-2`).
- A non-slot teardown reaps its recorded groups, then subtracts every slot-owned pid
  (`xs_slot_protected_pids`) from its fallback pattern before signalling. Shared audio
  (`xios-audiod`, `xios-mediad`) is only stopped by an everything-stops teardown.
- `--slot X stop` reaps that slot's groups, its named processes, its shell clients
  (`<client>-wayland-<slot>.pid`), sockets, session bus (`xios-session-bus-<slot>`), runtime
  dirs and markers. A group recorded for more than one owner is never signalled as a group.
  The CLI re-execs itself through `xios-setsid` for state-changing presets so chained
  commands do not share a group.
- `xios-session stop` means the non-slot session; the app and shared services go with it
  only when no slot is alive. `xios-session stop all` stops everything (CLI only; ioscd's
  `SESSION` has no `all`).
- GNOME: `launch-gnome-session.sh` writes the group id of the session it re-parents through
  `xios-setsid` to `xios-gnome[-<slot>].pgid`. Mutter slots are found by needle
  (`--wayland-display wayland-<slot>`).
- Every slot has its own active marker (`xios-active-session-<slot>`), so `app <name>` in a
  slot finds that slot's compositor.

**Per-slot helpers and endpoints**

| helper | slot socket | notes |
|---|---|---|
| `xios-sysintd` | `xios-<slot>-sysint.sock` | via `XIOS_SYSINT_SOCK`; one per session bus (KDE, GNOME, the app bus). |
| `xios-a11yd` | `xios-<slot>-a11y.sock` | honors `XIOS_A11Y_SOCK`; started by the first `app` launch in the slot. |

Both paths are advertised as `sysint_socket` and `a11y_socket` in `xios-displays.d/<slot>.json`
and `xios-session-<slot>.json`. The socket may not exist yet (a11yd starts lazily, sysintd
after the session bus), so the app must check before connecting. Per-slot logs:
`xios-sysintd-<slot>.log`, `xios-a11yd-<slot>.log`, `xios-atspi-<slot>.log`.

**Volume and appearance with several sysintds.** PulseAudio stays one shared daemon.
`module-xios-sink` and `xios-hwbridged` hardcode `/var/jb/tmp/xios-sysint.sock`; while no
non-slot session owns it, the launcher keeps it as a symlink to a live slot's sysintd
(`xs_publish_default_sysint_link`), and a real sysintd binding that path replaces the link.
Volume therefore applies to every desktop. Appearance is applied per session bus, so the app
has to send it to every slot's `sysint_socket` (M1). If a single relay is ever wanted, give
`module-xios-sink` its `sysint_socket` argument.

**iosc status producer.** iosc publishes as `iosc-<slot>` (from `XIOS_SESSION_SLOT` or
`-s wayland-<slot>`; `wayland-0` stays `iosc`), and binds `iosc-<slot>-clipboard.sock` and
`iosc-<slot>-wm.sock`.

**Device results (2026-10-06).** KDE, GNOME and the iosc shell up as slots at once; stopping
one left the others; non-slot `iosc`, `kde-desktop` and `mutter` starts left the slots alone;
`--slot gnome stop` removed GNOME's group, bus, sysintd, hwbridged and files while a non-slot
KDE stayed up; `stop all` left no session process. Footprints are in `docs/xios-v2-notes.md`.

## 2026-10-25 (later): ioscd helpers as mobile, X11 for Home Screen launches (xios-launcher-tools 0.1.13, unpublished, device-tested)

- **Helpers on ioscd's bus never worked.** `ioscd-bus`'s dbus-daemon runs as `mobile`, and its
  default policy admits only its own uid: a root client authenticates, then is disconnected
  after `BEGIN` (reproduced with `gdbus` as root vs `sudo -u mobile`). hwbridged exited ("lost
  org.freedesktop.UPower"); sensord and sysintd stayed up with no bus. The helpers need nothing
  root-only (IOKit battery, backboardd, CoreMotion go by entitlement; `/var/jb/sys` is mobile's;
  PulseAudio admits mobile), so `ensure_native_helpers_for_bus` now drops to mobile (HOME, USER
  too) after closing every fd but its pid/log fds. It no longer runs `xios_pulse_start` there
  (ensure_audio already ran it as root). A recorded helper that runs as another uid (root, from
  an older ioscd) is SIGTERMed, waited for, and replaced. A dead socket or dangling link at the
  global `xios-sysint.sock` is unlinked by root first, since mobile cannot replace it in the
  sticky tmp dir. Device: UPower, SensorProxy and the gsd Power shim all owned on `ioscd-bus`,
  `gdbus` as mobile reads the battery percentage. The a11y path (`start_a11y_for_busdir` on
  ioscd's bus) still ran as root and had the same refusal; fixed in 0.1.14 (below).
- **DISPLAY for LAUNCH/LAUNCH_CLASSIC.** `launch_client` reads `x11-display` from
  `xios-status.d/iosc.status` (`iosc-native.status` for native) and passes `DISPLAY` +
  `GDK_BACKEND=wayland,x11` only while `/tmp/.X11-unix/X<N>` accepts a connection (stronger than
  the lib's `-S`: a SIGTERMed iosc leaves both the sidecar and the socket). ioscd's own classic
  iosc start sets `IOSC_XWAYLAND=1` + `IOSC_XWAYLAND_BIN` when Xwayland is installed (=0 opts
  out), unlinks the stale sidecar first, and waits up to 6 s for `x11-display`, so the launch
  that started iosc gets its DISPLAY too (without the wait the first xterm logged "DISPLAY is
  not set"). Depends now `iosc (>= 0.9.52)` (the X access grant below).
- Host test: `test-ioscd-helpers.sh` gained mobile-HOME, stale/live global sysint, x11-display,
  DISPLAY-in-launch and IOSC_XWAYLAND cases.
- Device proof: ioscd `LAUNCH` from a mobile peer of a test `xterm` desktop entry: ioscd started
  wayland-0 iosc with Xwayland on `:0`, xterm ran as mobile with `DISPLAY=:0` and mapped
  (grim capture). Evidence: `x11/artifacts/device-runs/x11-gaps-20261025/` (main checkout).
- **Landmine found the hard way:** dropping a new `.desktop` file into
  `/var/jb/usr/share/applications` while Plasma runs crashed plasmashell (SIGSEGV in
  `libkickerplugin` `QObject::disconnectImpl` from a timer, right after a burst of
  `QKqueueFileSystemWatcherEngine::addPaths` errors), and the KDE monitor took KWin down with
  it. Any package install that adds a desktop entry can do the same. Report:
  `CrashReporter/plasmashell-2026-10-25-162754.ips`.
- xterm: the installed `xterm 368` is Procursus's (apt.procurs.us), not ours, and it works: as
  root in an iosc slot and as mobile once X admits mobile (both Xwayland 24.1.13+ios2 and
  23.2.7+ios5). The "0.00 CPU, state ?" was this device's `ps`, which shows that for every
  process (KWin too). It ships no `.desktop`, so no launcher can list it.

## Gotchas

- **ioscd must exec bash, not the script.** Exec'ing `xios-session` directly from launchd
  returned `ENOENT` before the script logged anything.
- **The screen must be awake and unlocked**, or FrontBoard suspends the Xios app and it
  presents black. Rapid kill/relaunch of the app trips FrontBoard's throttle; `sbreload`
  clears it.
- **Never write app progress into the lifecycle status file.** Before 1.0.78, `app` launches
  overwrote `xios-session-status.json`, KDE's exit monitor then (correctly) refused to touch
  a record owned by another preset, and a dead KDE stayed advertised as up.
- **Bash collapses an empty tab field.** pgid records use `-` for the non-slot field; an empty
  field once made timestamps parse as slot names and protected stale compositors from both
  reapers.
- **Recycled pgids.** A pgid is only signalled if the live group still contains a known Xios
  session process.
- **`pgrep` is not installed** (no procps). Liveness checks use `ps`.
- **KDE leaves strays if killed badly.** The KDE monitor traps every exit and stops
  PowerDevil, `kactivitymanagerd` and `kded6`; before that, overlapping runs left 20 orphaned
  PowerDevil processes and a load average over 100.
- **A full KDE slot next to a live desktop can exhaust the device.** The slot's iosc exited
  under the extra nested load. Use light iosc slots for parallel testing.
- **`install-xios-session.sh` is the dev loop.** It copies the session manifest over SSH; check
  checksums afterwards, since one early run left a stale lib on the device.

## History (short)

- 1.0.2 to 1.0.18 (early July): settle between teardown and start, per-step status, the
  lock, the shared app bus (one `dbus-daemon` per app bus instead of `dbus-run-session` per
  client), queued-request supersede, active-session owner (classic iosc refuses to start
  over another owner unless `IOSC_IGNORE_ACTIVE_SESSION=1`).
- 1.0.45 to 1.0.72 (July): slots, KDE Desktop and Mobile presets through
  `run-kde-plasma.sh`, the GNOME full-session launcher (the direct Shell runner is gone),
  VoiceOver gate (`A11Y_STATE` to ioscd creates `xios-a11y-enabled`), app launches by id as
  `mobile`.
- 1.0.78 (2026-07-30): app launch status split out of the lifecycle record.
- 1.0.81 (2026-10-06): M0 coexistence.
- 1.0.82 (2026-10-25): preflight, `presets`, Xwayland with iosc, depends on the stubs.
