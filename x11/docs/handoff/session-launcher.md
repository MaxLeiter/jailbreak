# session-launcher — the flavor switcher (CLI + ioscd + in-app picker)

## Ownership
Letting the user pick/switch desktop flavors from the iPad: the CLI, ioscd's `SESSION` request path, and the in-app ⧉ picker's backend. Reuses the real `run-*.sh` bring-up scripts (does not reinvent them).

## Key files (all under `x11/apps/iosc-desktop/`)
- `xios-session-lib.sh` — single source of truth: ONE bulletproof teardown (kills iosc/mutter/gnome-shell/Xios/panels/clients/session-buses + rm stale wayland-0/xios.json/*-ddx.sock/*-input.sock) + preset fns that CALL `run-shell.sh`/`run-mutter.sh`/`run-gnome-shell.sh`. Resolver prefers the INSTALLED script (/var/jb/usr/local/bin, then /var/jb/usr/bin) over a pinned libexec copy. It now also serializes `xios-session` operations with an atomic `/var/jb/tmp/xios-session.lock`, reaps stale lock owners, records daemon-launched session process groups so the next teardown can kill the whole previous tree instead of chasing children, and uses `/var/jb/tmp/xios-session.request-seq` so stale queued switch requests skip instead of running after a newer pick.
- `xios-session` — CLI: `xios-session iosc|mutter|gnome|kde|app <name>|stop|status`. Works over SSH (no daemon needed). Installed at `/var/jb/usr/local/bin/xios-session` (not on the default SSH PATH — use the full path over SSH, or bare on an on-device terminal). `-d/--via-daemon` talks to ioscd's Unix socket via `nc`, `socat`, then Python; it now falls through to the next transport if an installed `nc` exists but cannot handle the socket.
- `package-session.sh` → current source package version is `xios-session_1.0.19_iphoneos-arm64.deb` (not yet built here; `1.0.18` is the installed/validated GNOME daemon-path package). `install-xios-session.sh` — lead-run scp+chmod. The package is now target-aware for rootless/rootful staging; rootless `1.0.18` installed cleanly on-device after declaring the `xios-start-a11y` helper takeover from `iosc-shell <= 0.9.9`.
- `ioscd` — socket daemon. For `SESSION`, it now invokes `/var/jb/usr/bin/bash /var/jb/usr/local/bin/xios-session ...` instead of `execve`ing the shell script directly; direct script exec from launchd returned `ENOENT` before the script reached its own log. The daemon also logs untracked child exit/signal status, which made this visible.
- In-app picker: ⧉ button → modal; sends `SESSION` over `/var/jb/tmp/ioscd.sock`. Status line polls `/var/jb/tmp/xios-session-status.json`.

## Current state — package-installed 2026-07-03, CLI works
- Presets: iosc (works), mutter (up), gnome (experimental), kde (host-prepped experimental KWin + plasmashell nested on iosc), app <name> (launch a client, no teardown), stop (→ SpringBoard).
- Local multi-display slot groundwork: `xios-session --slot <name> <preset>` now switches the launcher into a namespaced desktop slot instead of the legacy one-at-a-time global session. Slot mode writes status to `/var/jb/tmp/xios-session-<slot>.json`, registry entries to `/var/jb/tmp/xios-displays.d/<slot>.json`, and compositor config to `/var/jb/tmp/xios-<slot>.json`. iosc/KDE slot paths use `wayland-<slot>`, `iosc-<slot>-ddx.sock`, `iosc-<slot>-input.sock`, `iosc-<slot>-clipboard.sock`, `iosc-<slot>-wm.sock`, and `kwin-<slot>`. `stop` with `--slot` reaps only the recorded slot process group and removes that slot's rendezvous files; unqualified `stop` remains stop-everything.
- `ioscd` `SESSION` requests accept an optional seventh tab field for the slot name and export it as `XIOS_SESSION_SLOT` before execing `xios-session`. Older six-field app/CLI requests remain valid.
- Mutter/GNOME slot plumbing is present but still needs on-device proof under concurrency: MetaBackendIOS now honors `XIOS_DDX_SOCKET` and `XIOS_JSON_PATH`, and the run scripts pass slot-specific `WAYLAND_DISPLAY`, output json, ddx socket, input socket, and log paths. Confirm whether the installed `mutter`/`gnome-shell` accepts `--wayland-display <name>` before relying on concurrent GNOME/Mutter slots.
- GNOME success signal keys off "GNOME Shell started at" in gnome-shell.log (not xios.json). IOSC_PANEL_OPACITY forwarded. Resolver flip applied.
- `xios-session 1.0.18` is installed on-device. Direct `xios-session gnome` and daemon
  `xios-session -d gnome` are both verified with `gnome-shell 46.0+ios3`: GNOME reaches
  `state=up`, Xios adopts the `2160x1620` Mutter surface, and the fresh shell log clears the
  Quick Settings/volume JS errors. Daemon evidence: `artifacts/device-runs/20260703-161839/`.
  A later newer `stop`/`kde-mobile` request intentionally won and switched the live device back
  to KDE; that is request ordering, not a daemon launch failure.
- 2026-07-03 rootless package validation: installed
  `x11-fonts-sf_1.0.0`, `xios-desktop-defaults_1.1.7`,
  `x11-xvfb_1.20.11+rootless1`, and `xios-session_1.0.15` from local
  target-aware artifacts. `xios-session` now owns
  `/var/jb/usr/local/bin/xios-start-a11y` via `Replaces: iosc-shell (<= 0.9.9)`.
  `xios-session status` and `--help` load from the packaged files, Xvfb stayed
  running for a short `:88` smoke, and the active iosc session reports
  `iosurface-zerocopy 2880x2160 [metal]` with input connected. Evidence bundle:
  `artifacts/device-runs/20260703-123110/`.
- Local pickup: ioscd parses optional `width`/`height`/`dpi` fields on `SESSION` requests and exports `IOSC_LOGICAL=WxH` before calling the shared launcher, so the in-app ⧉ picker can choose the next desktop dimensions.
- KDE pickup: `run-kde-plasma.sh` is now in the session manifest. It starts outer `iosc` with `IOSC_FRAME_PULSE=1`, launches `kwin_wayland` on `kwin-ios-test`, then starts `plasmashell` on that KWin socket under the same `dbus-run-session`. The Xios in-app picker has a "KDE Plasma" button. This path is packaged and syntax/package-contents checked, but it has not been installed or run on-device.

## Active display ownership — FIXED in 1.0.4
- `xios-session-lib.sh` records the owner in `/var/jb/tmp/xios-active-session` when launching `iosc`, `mutter`, or `gnome`, and clears it on `stop`.
- `ioscd` and the classic `iosc` binary respect that owner: direct/classic iosc is refused while the active owner is another session, with `IOSC_IGNORE_ACTIVE_SESSION=1` as an explicit diagnostic override. Native iosc remains allowed.
- Verified with Mutter active: `/var/jb/usr/local/bin/iosc` exited 2, logged `iosc: refusing classic output because active session is mutter`, and left Mutter's `xios.json` unchanged.
- Installed on-device: `dpkg-query` reports `xios-session 1.0.18`. Direct CLI and daemon-triggered
  session picks start Mutter/GNOME with active ownership. Newer switch requests still win by design,
  so concurrent picker taps can replace GNOME after a successful launch.

## One-at-a-time session reaper — ADDED in 1.0.14
- Every non-status `xios-session` command takes `/var/jb/tmp/xios-session.lock` before doing work. The lock is atomic `mkdir`, so it works without `flock` on iOS.
- If another request is active, later requests wait up to `XIOS_SESSION_LOCK_WAIT` seconds (default 45) instead of starting overlapping teardown/bring-up work. A stale lock owner older than `XIOS_SESSION_LOCK_STALE` seconds (default 180) is reaped.
- Daemon-launched sessions (`ioscd` uses `setsid`) record their process group in `/var/jb/tmp/xios-session.pgids`; the next teardown kills that whole group first, then falls back to the pattern reaper. The pattern now includes KDE wrappers, `kactivitymanagerd`, Xios audio/media/sysint helpers, and known stuck `pactl`/`mpv` session leftovers.

## Queued Switch Supersede — ADDED in 1.0.18
- Switch presets (`iosc`, `mutter`, `gnome`, KDE flavors, `resize`, `stop`) write a monotonic
  `/var/jb/tmp/xios-session.request-seq` marker before waiting on the session lock. A waiting older
  request exits with code 75 and logs `session request '<preset>' superseded while waiting` when a
  newer switch request appears.
- Device smoke used an artificial lock, queued `iosc`, then queued `gnome`; both skipped when a newer
  `kde-mobile` request appeared. This proves stale queued requests no longer run after a later pick,
  but also confirms the intended behavior: the newest picker/CLI request wins.

## Shared app bus — ADDED in 1.0.15
- `xios-session app <name>` now creates/reuses one `/var/jb/tmp/xios-session-bus/session-bus` with `dbus-daemon --session --fork` instead of wrapping every client in a fresh `dbus-run-session`.
- The per-app environment still uses the same `XDG_RUNTIME_DIR`, Wayland socket, GTK/Qt Wayland settings, memory gsettings, and a11y prefix. If direct bus creation is unavailable, it falls back to the old `dbus-run-session` wrapper.
- Device smoke on 2026-07-03 launched kgx plus GNOME Text Editor under the force-a11y gate; one session bus, one AT-SPI bus, and one `xios-a11yd` served both apps. Probe transcript:
  `artifacts/device-runs/20260703-052614/a11y-shared-bus-probe.txt`.
- ioscd now mirrors the same app-bus model at `/var/jb/tmp/ioscd-bus/session-bus`.
  Direct `LAUNCH_CLASSIC` smoke with kgx plus GNOME Text Editor produced one
  AT-SPI bus and an enabled daemon snapshot with two windows / 29 upserts:
  `artifacts/device-runs/20260703-053707-ioscd-a11y-shared-bus/ioscd-shared-bus-probe.txt`.

## VoiceOver a11y state gate — LOCAL 2026-07-03
- Xios sends `A11Y_STATE\t1|0` to `/var/jb/tmp/ioscd.sock` when iOS VoiceOver state changes. `ioscd` persists VoiceOver-on as `/var/jb/tmp/xios-a11y-enabled` and removes only that generated file on VoiceOver-off; `/var/jb/tmp/xios-a11y-force` remains the manual smoke override.
- `xios-session-lib.sh` treats either generated state, force file, or `XIOS_ENABLE_A11Y=1` as the enable gate. A fresh device smoke with no force file set `A11Y_STATE 1`, launched `xios-session app kgx`, and saw `xios-a11yd`, `at-spi-bus-launcher`, `dbus-daemon`, and `at-spi2-registryd` running from the shared app bus.
- Deploy note: `install-xios-session.sh` copies the updated `xios-session-lib.sh` through the shared manifest. During this smoke an early install appeared to leave a stale remote copy, so the lib was force-copied once before the passing run; a later installer rerun checksum-matched local and remote copies.

## Flavor-switch jetsam — FIXED in 1.0.2 (needs on-device deploy + verify)
Max hit it: switching iosc→mutter jetsammed the Xios app (took two tries). Root cause: killing the old compositor (~30MB GPU IOSurface + Metal/ANGLE ctx) while a new one immediately allocates spikes GPU memory past the foreground-app limit. `xios-session_1.0.2` (repo/debs + linux-build/out) applies all three fixes in `xios-session-lib.sh`:
1. **Settle** (`xs_settle`, `XIOS_SESSION_SETTLE` default 2s): switching presets now do teardown → settle → start (nothing holds stale GPU state during the settle; kernel reclaims the old surface first). Stacks with run-*.sh's own 1s for ~3s margin.
2. **Per-step status** in `xios-session-status.json`: `stopping → starting <preset> → waiting for compositor surface → relaunching display → up` (or error/compositor-only) with a human `message` for the picker/CLI.
3. **Relaunch-if-dead** (`xs_ensure_xios`): after the new surface exists, `uiopen -b` the app if it isn't running (status "relaunching display"); else foreground.
Verified host-side (bash -n, simulated the transition sequence). **DEPLOY:** `bash x11/apps/iosc-desktop/install-xios-session.sh` (or install the 1.0.2 deb), then test a switch on-device.
- GREENLIT (xios-app 8a94860 LANDED release-on-loss): the app now releases the dead IOSurface promptly on ddx-socket EOF, survives the switch, and re-adopts the new compositor's surface on its own — so you can DROP the app-kill from teardown for SWITCHES (keep it only for `stop`) to make switching fully flash-free (no SpringBoard flash). Co-confirm on device first: kill the compositor with the app foreground → expect the status banner (not a jetsam) then auto re-adopt. The 8a94860 build also polls `xios-session-status.json` for the live banner, so the per-step status (fix #2) now shows on-screen during a switch.

## Note
The `app <preset>` (launch app onto the running compositor) does NOT teardown → it's safe + works. Only the SESSION-SWITCH presets jetsam. The session-switch crash (renderTestPattern buffer overflow) was separately fixed in xios-app 923e92f; the remaining issue is the memory-peak jetsam + the missing progress UI.
