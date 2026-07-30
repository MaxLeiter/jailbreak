# Xios Device Testing Harness

`bin/xios-device` is the host-side entry point for autonomous device checks.
It wraps the existing `apps/iosc-desktop/deploy-env.sh` SSH settings, the
on-device `xios-session` launcher, `iosc-input-test`, screenshot helpers, and
`/var/jb/tmp` status/log collection.

Use it instead of hand-writing SSH snippets in agent sessions.

## Preconditions

- The repo root `device.env` should define the usual device settings if the
  defaults are not enough. `deploy-env.sh` reads `THEOS_DEVICE_IP`,
  `THEOS_DEVICE_PORT`, and `SSH_KEY`.
- SSH/SCP calls fail fast by default when the iPad is offline or mDNS is broken:
  `SSH_CONNECT_TIMEOUT=8`, `SSH_SERVER_ALIVE_INTERVAL=5`, and
  `SSH_SERVER_ALIVE_COUNT_MAX=2`. Override those environment variables for
  long-running diagnostics on a flaky link.
- The iPad must be awake/unlocked for Xios foreground presentation. SSH can
  start compositors while the screen is asleep, but the Metal app may not adopt
  or present the IOSurface until foregrounded.
- On-device helpers should be installed:
  `/var/jb/usr/local/bin/xios-session`,
  `/var/jb/usr/local/bin/iosc-input-test`, and ideally `grim` or
  `/var/jb/usr/local/bin/iosc-screenshot-test`.

## Quick Start

```bash
bin/xios-device doctor
bin/xios-device status
bin/xios-device session iosc
bin/xios-device session --slot codex-kde kde-desktop
bin/xios-device foreground
bin/xios-device app kgx
bin/xios-device input type "echo hello from xios-device"
bin/xios-device shot
```

Artifacts from `shot` and `collect` go under
`artifacts/device-runs/<timestamp>/` unless an output directory is supplied.
Those directories are local evidence bundles: status files, logs, process
snapshots, and any screenshots the harness could capture.

## Commands

### `doctor`

Checks host tools, SSH reachability, `/var/jb`, and key on-device Xios helpers.
Run this first when an agent is unsure whether device testing is possible.

### `status`

Prints:

- Xios/iosc/Mutter/GNOME process summary.
- `/var/jb/tmp/xios-session-status.json`.
- `/var/jb/tmp/xios-active-session`.
- `/var/jb/tmp/xios.json`.
- `/var/jb/tmp/xios-status.txt`.
- `/var/jb/tmp/xios-geom.txt`.
- Recent `/var/jb/tmp/xios-touch.log`.

This is the fastest non-destructive health check.

### `session`

Runs the installed on-device `xios-session` CLI.

```bash
bin/xios-device session iosc
bin/xios-device session mutter
bin/xios-device session gnome
bin/xios-device session kde
bin/xios-device session kde-mobile
bin/xios-device session --slot codex-kde kde-desktop
bin/xios-device session stop
bin/xios-device session --width 1080 --height 1440 --dpi 176 iosc
bin/xios-device session --via-daemon iosc
```

Remember that session switches use the same teardown semantics documented in
`docs/handoff/session-launcher.md`.

### `app`

Launches a client into the currently running session:

```bash
bin/xios-device app kgx
bin/xios-device app gnome-text-editor
```

### `foreground`

Asks FrontBoard to foreground `com.max.xios`, then waits briefly for
`xios-status.txt` to show `iosurface-zerocopy`. This is useful after starting a
compositor or relaunching the app, but it is not perfectly reliable if
FrontBoard throttling has been triggered. A physical icon tap can still be more
reliable.

### `input`

Injects deterministic input through `iosc-input-test`, bypassing UIKit.
Coordinates are physical output pixels in the compositor framebuffer space.
Read `/var/jb/tmp/xios.json` or `bin/xios-device status` before choosing them.

Examples:

```bash
bin/xios-device input click 540 405
bin/xios-device input --mutter click 1080 810
bin/xios-device input --iosc type "ls -la"
bin/xios-device input scroll 1000 900 0 -240
bin/xios-device input drag 300 300 900 500
bin/xios-device input touch 500 400
bin/xios-device input pencil 300 300 900 500
bin/xios-device input key 0x6e 3
```

Use UIKit/Xios app gestures only when the bug is specifically in the app input
path. For compositor/client bugs, `iosc-input-test` is more reproducible.

### `shot`

Captures visual evidence and then collects status/log files.

```bash
bin/xios-device shot
bin/xios-device shot /tmp/xios-shot
```

Capture order:

1. Try on-device `grim` against the active Wayland display and copy
   `compositor.png`.
2. If `grim` is missing or does not create a PNG, run `iosc-screenshot-test`;
   copy `compositor.png` when it emits one and always copy
   `compositor-shot.log`, which contains the screencopy probe map.
3. If a USB or network-paired device is visible through `idevice_id`, try
   `idevicescreenshot` and save `device.png`.

The compositor screenshot proves raw Wayland output contents. It may not match
the final UIKit/Xios presentation orientation or fit transform exactly. The
physical device screenshot, when available, proves what the iPad display actually
shows. For app scaling, orientation, black-frame, overlay, or foreground bugs,
prefer physical device evidence or explicit human confirmation from the iPad.

### `collect`

Copies the usual `/var/jb/tmp` evidence into a local directory without taking a
screenshot:

```bash
bin/xios-device collect
bin/xios-device collect /tmp/xios-evidence
```

### `push`

Copies one local file to the device's temporary Xios area:

```bash
bin/xios-device push linux-build/out/webkitgtk-smoke /var/jb/tmp/webkitgtk-smoke
```

The destination defaults to `/var/jb/tmp/<local basename>` and is deliberately
restricted to paths beneath `/var/jb/tmp`. Use `exec` for any follow-up
permission change or invocation.

### Session profiling

Use `bin/xios-profile-session` when comparing compositor performance before and
after KWin, Mutter, GNOME, or iosc changes. It starts or attaches to a preset,
samples the relevant processes and logs for a fixed interval, then writes a
summary plus the standard `xios-device collect` bundle:

```bash
bin/xios-profile-session kde
bin/xios-profile-session --duration 30 mutter
bin/xios-profile-session --no-session --duration 10 kde
```

The summary highlights renderer/backend clues and common bottleneck signatures
such as Qt Wayland EGL fallback, KWin IOSurface imports, Mutter IOSurface
present, frame-callback stalls, protocol errors, and compositor crashes.

### KDE smoke helper

Use `bin/xios-kde-smoke` for repeatable Plasma Desktop/Mobile/Nano visual
checks. It wraps `bin/xios-device`, starts or attaches to the requested KDE
flavor, foregrounds Xios, optionally launches an app or swipes the Mobile app
drawer, and writes a standard evidence bundle:

```bash
bin/xios-kde-smoke mobile --drawer
bin/xios-kde-smoke desktop --app systemsettings
bin/xios-kde-smoke --no-session desktop
bin/xios-kde-smoke desktop --slot codex-kde
```

With `--no-session`, the helper records the current reported preset and warns if
it differs from the requested flavor.
With `--slot`, the helper starts or inspects a named secondary display without
foregrounding Xios or replacing the main active session. Slot screenshots use
the slot Wayland display and collect `/var/jb/tmp/xios-<slot>.json`,
`xios-session-<slot>.json`, and slot-specific logs when present.

### `logs`

Prints recent log tails, optionally filtered:

```bash
bin/xios-device logs
bin/xios-device logs MetaInputIOS
bin/xios-device logs JS.ERROR
```

### `exec`

Runs an arbitrary remote Bash command through the shared SSH settings:

```bash
bin/xios-device exec 'cat /var/jb/tmp/xios.json'
```

Use named subcommands when possible; reserve `exec` for one-off inspection.

## Agent Workflow

1. Read `docs/handoff/INDEX.md` and the relevant domain handoff file.
2. Run `bin/xios-device doctor` if device availability is uncertain.
3. Run `bin/xios-device status` before changing device state.
4. Start or switch sessions with `bin/xios-device session ...`.
5. Use `bin/xios-device input ...` for deterministic interaction.
6. Use `bin/xios-device shot` or `collect` before reporting device behavior.
7. Include artifact paths in the handoff or final response.

Do not treat host syntax checks as on-device validation. UIKit, FrontBoard,
IOSurface, Metal, launchd, and package-manager behavior still require device
evidence.

## Landmine: a host-signed `iosc` can be SIGKILLed on launch

Observed 2026-07-29 on iPad7,12 / iPadOS 17.6.1 / Dopamine. A freshly
cross-built `iosc`, signed on the Mac by `sign-iosc.sh` (which reports success and
whose entitlements read back correctly with `ldid -e`), was killed instantly by
the kernel every launch:

```
$ iosc -logical 1440x1080 ...
exit=137          # 128 + SIGKILL
                  # ZERO bytes of output — not one fprintf reached stderr
```

**Zero output plus exit 137 means AMFI rejected the signature, not that the code
is broken.** Nothing in the program ran, so there is no crash log and no clue in
any `/var/jb/tmp` log. It looks exactly like a compositor that dies during
bring-up, and `xios-session` reports only the downstream symptom
(`iosc did not create wayland-0`).

Isolate it in one step — run the previous, package-installed binary with the same
arguments. If that one starts and prints its `output IOSurface ...` banner, the
device is fine and the new binary's signature is the problem.

Fix: re-sign **on the device**, which has its own `ldid`:

```bash
scp x11/wayland/iosc-gl-ent.xml root@$IP:/var/jb/tmp/
ssh root@$IP 'ldid -S/var/jb/tmp/iosc-gl-ent.xml /var/jb/usr/local/bin/iosc'
```

Notes:
- The scp is not at fault. Verify with `shasum -a 256` on both ends: the bytes are
  identical, so the host's signature itself is what AMFI refuses.
- Only `iosc` was affected. `Xios.app`, signed by the same host `ldid` through
  `bin/lib/build-app.sh`, launched fine — so this is specific to the entitlement
  set in `iosc-gl-ent.xml` (`platform-application`,
  `com.apple.private.amfi.can-allow-non-platform`, the IOKit user-client array)
  rather than to the host toolchain in general.
- `sign-iosc.sh`'s header comment claims the Homebrew `ldid` "emits those
  correctly". On this host, at this version, it does not. Treat host signing as
  best-effort and re-sign on device whenever a fresh `iosc` exits 137.
- `.deb`-installed compositors are signed at package build time and are unaffected;
  this only bites the scp-a-dev-build loop.
