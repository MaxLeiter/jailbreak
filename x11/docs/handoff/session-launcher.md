# session-launcher — the flavor switcher (CLI + ioscd + in-app picker)

## Ownership
Letting the user pick/switch desktop flavors from the iPad: the CLI, ioscd's `SESSION` request path, and the in-app ⧉ picker's backend. Reuses the real `run-*.sh` bring-up scripts (does not reinvent them).

## Key files (all under `x11/apps/iosc-desktop/`)
- `xios-session-lib.sh` — single source of truth: ONE bulletproof teardown (kills iosc/mutter/gnome-shell/Xios/panels/clients/session-buses + rm stale wayland-0/xios.json/*-ddx.sock/*-input.sock) + preset fns that CALL `run-shell.sh`/`run-mutter.sh`/`run-gnome-shell.sh`. Resolver prefers the INSTALLED script (/var/jb/usr/local/bin, then /var/jb/usr/bin) over a pinned libexec copy.
- `xios-session` — CLI: `xios-session iosc|mutter|gnome|kde|app <name>|stop|status`. Works over SSH (no daemon needed). Installed at `/var/jb/usr/local/bin/xios-session` (not on the default SSH PATH — use the full path over SSH, or bare on an on-device terminal).
- `package-session.sh` → current source package version is `xios-session_1.0.15_iphoneos-arm64.deb`. `install-xios-session.sh` — lead-run scp+chmod. Doc: `x11/docs/session-launcher.md`.
- In-app picker: ⧉ button → modal; sends `SESSION` over `/var/jb/tmp/ioscd.sock`. Status line polls `/var/jb/tmp/xios-session-status.json`.

## Current state — built, installed (1.0.4), CLI works
- Presets: iosc (works), mutter (up), gnome (experimental), kde (host-prepped experimental KWin + plasmashell nested on iosc), app <name> (launch a client, no teardown), stop (→ SpringBoard).
- GNOME success signal keys off "GNOME Shell started at" in gnome-shell.log (not xios.json). IOSC_PANEL_OPACITY forwarded. Resolver flip applied.
- Local pickup: ioscd parses optional `width`/`height`/`dpi` fields on `SESSION` requests and exports `IOSC_LOGICAL=WxH` before calling the shared launcher, so the in-app ⧉ picker can choose the next desktop dimensions.
- KDE pickup: `run-kde-plasma.sh` is now in the session manifest. It starts outer `iosc` with `IOSC_FRAME_PULSE=1`, launches `kwin_wayland` on `kwin-ios-test`, then starts `plasmashell` on that KWin socket under the same `dbus-run-session`. The Xios in-app picker has a "KDE Plasma" button. This path is packaged and syntax/package-contents checked, but it has not been installed or run on-device.

## Active display ownership — FIXED in 1.0.4
- `xios-session-lib.sh` records the owner in `/var/jb/tmp/xios-active-session` when launching `iosc`, `mutter`, or `gnome`, and clears it on `stop`.
- `ioscd` and the classic `iosc` binary respect that owner: direct/classic iosc is refused while the active owner is another session, with `IOSC_IGNORE_ACTIVE_SESSION=1` as an explicit diagnostic override. Native iosc remains allowed.
- Verified with Mutter active: `/var/jb/usr/local/bin/iosc` exited 2, logged `iosc: refusing classic output because active session is mutter`, and left Mutter's `xios.json` unchanged.
- Installed on-device: `dpkg -s xios-session` reports `Version: 1.0.4`; `xios-session mutter` starts Mutter with `mutter-ddx.sock`/`mutter-input.sock` and active owner `mutter`.

## Shared app bus — ADDED in 1.0.15
- `xios-session app <name>` now creates/reuses one `/var/jb/tmp/xios-session-bus/session-bus` with `dbus-daemon --session --fork` instead of wrapping every client in a fresh `dbus-run-session`.
- The per-app environment still uses the same `XDG_RUNTIME_DIR`, Wayland socket, GTK Wayland settings, memory gsettings, and a11y prefix. If direct bus creation is unavailable, it falls back to the old `dbus-run-session` wrapper.
- Device smoke on 2026-07-03 launched kgx plus GNOME Text Editor under the force-a11y gate; one session bus, one AT-SPI bus, and one `xios-a11yd` served both apps. Probe transcript:
  `artifacts/device-runs/20260703-052614/a11y-shared-bus-probe.txt`.

## Flavor-switch jetsam — FIXED in 1.0.2 (needs on-device deploy + verify)
Max hit it: switching iosc→mutter jetsammed the Xios app (took two tries). Root cause: killing the old compositor (~30MB GPU IOSurface + Metal/ANGLE ctx) while a new one immediately allocates spikes GPU memory past the foreground-app limit. `xios-session_1.0.2` (repo/debs + linux-build/out) applies all three fixes in `xios-session-lib.sh`:
1. **Settle** (`xs_settle`, `XIOS_SESSION_SETTLE` default 2s): switching presets now do teardown → settle → start (nothing holds stale GPU state during the settle; kernel reclaims the old surface first). Stacks with run-*.sh's own 1s for ~3s margin.
2. **Per-step status** in `xios-session-status.json`: `stopping → starting <preset> → waiting for compositor surface → relaunching display → up` (or error/compositor-only) with a human `message` for the picker/CLI.
3. **Relaunch-if-dead** (`xs_ensure_xios`): after the new surface exists, `uiopen -b` the app if it isn't running (status "relaunching display"); else foreground.
Verified host-side (bash -n, simulated the transition sequence). **DEPLOY:** `bash x11/apps/iosc-desktop/install-xios-session.sh` (or install the 1.0.2 deb), then test a switch on-device.
- GREENLIT (xios-app 8a94860 LANDED release-on-loss): the app now releases the dead IOSurface promptly on ddx-socket EOF, survives the switch, and re-adopts the new compositor's surface on its own — so you can DROP the app-kill from teardown for SWITCHES (keep it only for `stop`) to make switching fully flash-free (no SpringBoard flash). Co-confirm on device first: kill the compositor with the app foreground → expect the status banner (not a jetsam) then auto re-adopt. The 8a94860 build also polls `xios-session-status.json` for the live banner, so the per-step status (fix #2) now shows on-screen during a switch.

## Note
The `app <preset>` (launch app onto the running compositor) does NOT teardown → it's safe + works. Only the SESSION-SWITCH presets jetsam. The session-switch crash (renderTestPattern buffer overflow) was separately fixed in xios-app 923e92f; the remaining issue is the memory-peak jetsam + the missing progress UI.
