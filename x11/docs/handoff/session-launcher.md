# session-launcher — the flavor switcher (CLI + ioscd + in-app picker)

## Ownership
Letting the user pick/switch desktop flavors from the iPad: the CLI, ioscd's `SESSION` request path, and the in-app ⧉ picker's backend. Reuses the real iosc/Mutter bring-up scripts and the packaged GNOME session launcher (does not reinvent them).

## Key files (all under `x11/apps/iosc-desktop/`)
- `xios-session-lib.sh` — single source of truth: ONE bulletproof teardown (kills iosc/mutter/gnome-shell/panels/clients/session-buses/KDE app bundles + rm stale wayland-0/xios.json/*-ddx.sock/*-input.sock) + preset fns that CALL `run-shell.sh`/`run-mutter.sh`; normal switches preserve the Xios display app, while explicit `stop` also terminates it. GNOME resolves the packaged `launch-gnome-session.sh` from `xios-session-stubs`. Resolver normally prefers the installed owner script (`/var/jb/usr/local/bin`, then `/var/jb/usr/bin`) over the pinned libexec copy, but slot mode prefers the packaged libexec copy first so stale live owner scripts cannot drop slot-specific env/argv. Switch operations serialize with atomic `/var/jb/tmp/xios-session.lock`; `app <name>` deliberately stays off that lock so a slow GUI launch cannot block desktop controls. The launcher records daemon session process groups, validates that a live group still contains a known Xios session process before signaling it, and uses `/var/jb/tmp/xios-session.request-seq` so stale queued switch requests skip instead of running after a newer pick.
- `xios-session` — CLI: `xios-session iosc|mutter|gnome|kde|app <name>|stop|status`. Works over SSH (no daemon needed). Installed at `/var/jb/usr/local/bin/xios-session` (not on the default SSH PATH — use the full path over SSH, or bare on an on-device terminal). `-d/--via-daemon` talks to ioscd's Unix socket via `nc`, `socat`, then Python; it now falls through to the next transport if an installed `nc` exists but cannot handle the socket.
- `package-session.sh` → current device-tested package is `xios-session 1.0.67`
  (immutable deb in `linux-build/out/` and top-level `repo/debs/`; not a production
  publication claim). This package carries the KDE Qt platformtheme/Breeze env bridge,
  KDE color-scheme app-data bridge, Desktop fullscreen outer-KWin placement, guarded
  stale Desktop state migration, Mobile sizing/wallpaper/Folio setup, non-foregrounding
  slot sessions, slot cleanup, and the 2026-07-29 responsiveness fixes.
- `ioscd` — socket daemon. For `SESSION`, it now invokes `/var/jb/usr/bin/bash /var/jb/usr/local/bin/xios-session ...` instead of `execve`ing the shell script directly; direct script exec from launchd returned `ENOENT` before the script reached its own log. The daemon logs untracked child exit/signal status and now logs each `SESSION` request's peer pid/uid/path plus payload before launch, so parallel CLI/app-picker requests are attributable in `/var/jb/tmp/ioscd.log`.
- In-app picker: ⧉ button → modal; sends `SESSION` over `/var/jb/tmp/ioscd.sock`. Status line polls `/var/jb/tmp/xios-session-status.json`.

## Current state — package-installed 2026-07-29, CLI/daemon works

- `xios-session 1.0.72` removes a process-substitution deadlock from capability
  profile collection and launches apps into the active GNOME compositor's
  private runtime directory/session bus. The GNOME startup gate now treats
  Shell process exit and main-entry/GPU errors as fatal without mistaking
  unrelated helper-service JS warnings for a compositor failure.
- `ioscd` app launches now use a separate strict contract from `SESSION`:
  launchers send only an app id, the daemon resolves a trusted installed
  desktop entry, and the client/session bus run as `mobile`. The daemon still
  owns compositor and session lifecycle as root. `xios-launcher-tools 0.1.5`
  carries this implementation and no longer hard-depends on `xios-session`, so
  the native flavor can remain shell-free.
- 2026-07-29 responsiveness/device closure (`xios-session 1.0.67`):
  normal switches no longer terminate Xios in either the shared teardown or the
  nested KDE/Mutter bring-up scripts; explicit `stop` retains the full-kill behavior.
  Xios liveness uses `ps` because procps/`pgrep` is not installed. Client app launches
  no longer take the global switch lock, so a deliberately slow `xios-session app kgx`
  left the lock absent while an iosc switch completed normally.
- PGID records now use `-` for the global/non-slot field. The former empty tab field
  was collapsed by Bash, causing timestamps to be mistaken for slot names and
  protecting stale global compositors from both reapers. Legacy records are normalized,
  and PGIDs are signaled only if the live group still contains a recognized Xios
  session process, preventing recycled PGIDs from touching unrelated work. Device
  validation reaped two stale iosc groups, compacted the historical file to one current
  `kde` record, and restored a nonblank desktop.
- End-to-end proof retained Xios PID `77756` through iosc/KDE switches, finished
  `kde/up` with no lock and no new Xios analytics report, and captured a nonblank
  2880x2160 desktop in
  `artifacts/device-runs/xios-responsiveness-final-20260729-kde/`.
- 2026-07-29 dangling-process closure: overlapping slot/KDE work left a dead
  iosc slot's panel/dock/background spinning, 20 orphaned PowerDevil processes,
  three orphaned `kded6` processes, disconnected Ladybird/native clients, and a
  hung OpenCode version probe. Targeted cleanup lowered one-minute load from
  about 134 to 2.27 while the live `codexthunar` slot remained up. The KDE
  monitor now traps every exit/signal and TERM/KILL/waits PowerDevil,
  `kactivitymanagerd`, and `kded6`; the shared session reaper recognizes
  PowerDevil-only process groups; and `install-xios-session.sh` now preserves
  the `/var/jb` prefix in generated mkdir/chmod commands. The scripts were
  deployed live over installed `xios-session 1.0.72`; package script `1.0.73`
  remains the next immutable artifact. Evidence:
  `artifacts/device-runs/dangling-cleanup-before-20260729-2330/` and
  `artifacts/device-runs/dangling-cleanup-after-20260729-2337/`.

Host follow-up on 2026-07-18: the teardown path and KDE monitor now rewrite a
previously-live session to `state=down` instead of leaving a stale `up` in the
picker. A synthetic teardown smoke passed for `kde-desktop/up -> down`, and the
next immutable package version is `xios-session 1.0.55`. Packaging and device
validation are deferred until Docker and the iPad are available; 1.0.54 remains
the currently published package.
- Presets: iosc (works), mutter (up), gnome (verified full GNOME session path), kde (host-prepped experimental KWin + plasmashell nested on iosc), app <name> (launch a client, no teardown), stop (→ SpringBoard).
- Multi-display slot groundwork: `xios-session --slot <name> <preset>` now switches the launcher into a namespaced desktop slot instead of the legacy one-at-a-time global session. Slot mode writes status to `/var/jb/tmp/xios-session-<slot>.json`, registry entries to `/var/jb/tmp/xios-displays.d/<slot>.json`, and compositor config to `/var/jb/tmp/xios-<slot>.json`. iosc/KDE slot paths use `wayland-<slot>`, `iosc-<slot>-ddx.sock`, `iosc-<slot>-input.sock`, `iosc-<slot>-clipboard.sock`, `iosc-<slot>-wm.sock`, and `kwin-<slot>`. `stop` with `--slot` reaps only the recorded slot process group and removes that slot's rendezvous files; unqualified `stop` remains stop-everything.
- 2026-07-28 stale-slot sweep: a slot's `xios-displays.d` entry is only deleted on a clean `stop`, so a slot that dies any other way (crash, jetsam, a killed bring-up, a reboot that left `/tmp` behind) left its entry there forever and the Xios app kept listing a display nothing could reach — the iPad had accumulated eight, the oldest two days old. `xs_sweep_stale_slot_registry` now runs once per session operation, right after `xs_acquire_session_lock`, and drops entries with no Wayland socket, no display config, and no processes named for the slot, plus that slot's orphaned `xios-session-<slot>.json`. Anything still serving is left alone, as is the slot the current invocation is bringing up; holding the lock means it cannot race another `xios-session` writing an entry. `XIOS_SESSION_SWEEP_SLOTS=0` disables it. Verified host-side across six cases (dead / live-by-socket / live-by-config / mid-start-with-live-process / same-slot / process-dies-then-swept) and on-device against the deployed lib in a sandboxed `XS_TMP`, with the live KDE session untouched. Deployed to `/var/jb/libexec/xios-session/xios-session-lib.sh`; not yet folded into a package bump.
- Slot sessions do not foreground Xios by default, so parallel agents can collect compositor evidence without stealing the active device display. Set `XIOS_SLOT_FOREGROUND=1` only when intentionally presenting a slot in the app. `xios-session 1.0.45` also reaps slot-named child processes (`wayland-<slot>`, `iosc-<slot>-*`, `kwin-<slot>`) on `--slot <name> stop`; the cleanup proof used `codex-clean` and left `after=0` matching slot processes with evidence in `artifacts/device-runs/slot-cleanup-20260705-2338/`.
- `ioscd` `SESSION` requests accept an optional seventh tab field for the slot name and export it as `XIOS_SESSION_SLOT` before execing `xios-session`. Older six-field app/CLI requests remain valid.
- Mutter/GNOME slot plumbing is present but still needs on-device proof under concurrency: MetaBackendIOS now honors `XIOS_DDX_SOCKET` and `XIOS_JSON_PATH`, and the run scripts/full-session launcher pass slot-specific `WAYLAND_DISPLAY`, output json, ddx socket, input socket, and log paths. Confirm whether the installed `mutter`/`gnome-shell` accepts `--wayland-display <name>` before relying on concurrent GNOME/Mutter slots.
- GNOME success signal keys off "GNOME Shell started at" in the active shell log (slot mode uses `gnome-shell-<slot>.log`, not the legacy global log). IOSC_PANEL_OPACITY forwarded.
- 2026-07-04 23:15 PDT full-session GNOME validation: installed `xios-session 1.0.22` and
  `xios-session-stubs 0.2.3`; direct `xios-session gnome` and daemon `xios-session -d gnome` both
  reached `{"preset":"gnome","state":"up","message":"GNOME Shell started"}` through
  `launch-gnome-session.sh`. Xios adopted the `2160x1620` Mutter IOSurface with mutter input
  connected. Evidence bundle: `artifacts/device-runs/20260704-231534/` (logs/status; the separate
  screenshot attempt at `artifacts/device-runs/20260704-231559/` only logged `failed to create
  display`, expected for the non-iosc capture path). A later explicit `stop` and KDE launch replaced
  GNOME; that is newest-request-wins behavior, not a GNOME launch failure.
- 2026-07-06 12:59 PDT GNOME direct-runner removal validation: installed state is
  `xios-session 1.0.46` plus `xios-session-stubs 0.2.4`; the device has no
  `run-gnome-shell.sh*` under `/var/jb/libexec/xios-session`, `/var/jb/usr/bin`, or
  `/var/jb/usr/local/bin`. Daemon `xios-session -d gnome` reaped a stale KDE app-launch lock,
  switched from `kde-desktop`, and reached `{"preset":"gnome","state":"up","message":"GNOME Shell started"}`.
  Xios adopted the `2160x1620` Mutter IOSurface with mutter input connected. Evidence bundle:
  `artifacts/device-runs/20260706-125913/`.
- 2026-07-04 native-helper bridge: `xios-session app` and `ioscd` app launches now start `xios-hwbridged`, `xios-sensord`, and `xios-sysintd` on the shared app bus, and app client env sets both `DBUS_SESSION_BUS_ADDRESS` and `DBUS_SYSTEM_BUS_ADDRESS` to that bus. `run-kde-plasma.sh` starts the same helpers inside KDE's session bus. Package contents verified in `xios-session_1.0.22`; device smoke saw the helpers start, battery/backlight/sensor sysfs mirrors populate, and `xios-sysintd` apply dark appearance plus desktop-volume-to-device.
- 2026-07-04 slot audit: `xios-session --slot audit-iosc --via-daemon iosc` reached slot
  `state=up` while the global `kde` session stayed active. It created
  `/var/jb/tmp/xios-session-audit-iosc.json`, `/var/jb/tmp/xios-displays.d/audit-iosc.json`,
  `/var/jb/tmp/xios-audit-iosc.json`, `wayland-audit-iosc`, `iosc-audit-iosc-ddx.sock`, and
  `iosc-audit-iosc-input.sock`; `grim` wrote `/var/jb/tmp/audit-iosc.png` against
  `WAYLAND_DISPLAY=wayland-audit-iosc`. After SSH returned, the PNG and slot state were copied to
  `artifacts/device-runs/20260704-214818-slot-audit-cleanup/`; the PNG is a valid nonblank
  2880x2160 compositor screenshot. Cleanup ran `xios-session --slot audit-iosc stop`, removing
  the slot config/socket files and leaving only the normal stopped status/registry record.
- Slot caveat from the same audit: the installed `iosc` binary accepted the slot-specific
  `-clipboard-sock`/`-wm-sock` argv but still bound `/var/jb/tmp/iosc-clipboard.sock` and
  `/var/jb/tmp/iosc-wm.sock`. The local `wayland/iosc.c` source parses those flags correctly, so
  verify/redeploy the current `iosc` package before claiming clipboard/WM socket isolation for
  concurrent slots.
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
- KDE pickup: `run-kde-plasma.sh` is in the session manifest. It starts outer `iosc` with `IOSC_FRAME_PULSE=1`, launches `kwin_wayland` on `kwin-ios-test`, then starts `plasmashell` on that KWin socket under the same `dbus-run-session`. As of `xios-session 1.0.45`, the desktop preset defaults to the real upstream `org.kde.plasma.desktop` shell, exports the KDE Qt platformtheme/Breeze style when installed, seeds Breeze Dark defaults, bridges KPackage app-data paths including `color-schemes`, migrates stale Desktop favorites/configs, and keeps Desktop on `IOSC_LOGICAL=1440x1080`/KWin `1360x1000` so the panel is not clipped after iosc output rotation. Mobile uses a portrait KWin viewport (`1080x1440` for default `IOSC_LOGICAL=1440x1080`), pre-foregrounds Xios so KWin binds after the app has rotated the output to `2160x2880`, fullscreen-configures the outer KWin toplevel, seeds Mobile wallpaper/Folio app-grid config, and suppresses `wl_output` transform advertising to avoid KWin rendering into a rotated square. The old `org.kde.plasma.xios` first-light shell is no longer shipped by the session package. Desktop proof after the UI style/layout pass: `artifacts/device-runs/kde-ui-style-clean-layout-final-20260705-194801/`. Mobile clean-home proof after the transform/sizing fix: `artifacts/device-runs/kde-mobile-final-clean-20260705-2152/` has a full-frame `2160x2880` Mobile home capture; current Mobile proof with `plasma-mobile 6.1.5+ios13` and the exact repo-byte `plasma-desktop 6.1.5+ios5` is `artifacts/device-runs/kde-mobile-ios13-ios5-finalrepo-20260706-002750/`, with live iOS-backed status providers, no activitypager mainscript warning, and no MobileShell provider type-resolution cycle. A concurrent `--slot codex-desktop kde-desktop` smoke started KWin/plasmashell without foregrounding Xios, but the slot iosc exited under the extra nested KDE load while the main device session was active; use lightweight iosc slots for parallel capture, and reserve full KDE slot smokes for lower device load.

## Active display ownership — FIXED in 1.0.4
- `xios-session-lib.sh` records the owner in `/var/jb/tmp/xios-active-session` when launching `iosc`, `mutter`, or `gnome`, and clears it on `stop`.
- `ioscd` and the classic `iosc` binary respect that owner: direct/classic iosc is refused while the active owner is another session, with `IOSC_IGNORE_ACTIVE_SESSION=1` as an explicit diagnostic override. Native iosc remains allowed.
- Verified with Mutter active: `/var/jb/usr/local/bin/iosc` exited 2, logged `iosc: refusing classic output because active session is mutter`, and left Mutter's `xios.json` unchanged.
- Installed on-device during the latest GNOME full-session smoke: `dpkg-query` reported
  `xios-session 1.0.46` and `xios-session-stubs 0.2.4`. Direct CLI and daemon-triggered
  session picks start Mutter/GNOME with active ownership. Newer switch requests still win by design;
  if a later request replaces GNOME, use ioscd's peer/payload request log to identify the requester.

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
  but also confirms the intended behavior: the newest explicit requester wins.

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

## 2026-07-30 additive-launch/status repair — PRODUCTION + DEVICE VERIFIED
- The observed dead-KDE state had three contradictory records: no
  `kwin_wayland`/`plasmashell`, `xios-active-session=kde`, and global status
  `preset=app,state=error`. Root cause: `xios-session app` used the display
  lifecycle file for additive client progress. Once overwritten, KDE's exit
  monitor correctly refused to replace a status owned by another preset, so the
  dead display stayed advertised.
- `xios-session 1.0.78` keeps app submission state in
  `xios-app-launch-status.json`, preserves the desktop lifecycle record on both
  accepted and rejected launches, passes the active-owner path to KDE, and
  clears that marker when the owning KWin/Plasma session exits. Its installed
  capability-profile helper now infers `/var/jb` instead of trying to source the
  unshipped `//linux-build/target-lib.sh`. Empty environment arrays use the
  Bash-3-safe expansion form.
- `xios-launcher-tools 0.1.8` makes ioscd reject an app request immediately when
  no classic compositor socket is live, repairs stale active markers during
  health checks, and marks the matching steady session down. Host regression
  `apps/iosc-desktop/test-session-state.sh`, shell syntax, desktop-entry tests,
  signed ioscd build, and both package builds pass.
- Production now serves `xios-session 1.0.78`, `xios-launcher-tools 0.1.8`,
  and `com.max.xios 0.1.9`; live payload fetch-back matched the indexed SHA256
  values. The same versions are installed on the iPad. Starting KWrite through
  the additive path preserved the global `kde/up` lifecycle record and wrote
  `kwrite/submitted` only to `xios-app-launch-status.json`. Terminating the exact
  KWin PID then produced `kde/down`, removed the active marker, and stopped the
  KDE process set. A subsequent KDE launch succeeded. Physical UIKit tap-through
  is still not claimed because Xios foreground adoption remained at
  `holding-frame` / `input-not-connected` during this verification.
