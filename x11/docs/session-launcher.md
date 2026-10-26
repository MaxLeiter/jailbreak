# Xios session launcher: design overview

This is the short design note for how a desktop gets picked and started. Current
status, version history, device evidence and open work live in
[`handoff/session-launcher.md`](handoff/session-launcher.md); read that before
changing anything. (The July version of this file also carried an in-app picker
spec based on a request file. The app talks to ioscd over a socket instead, so that
spec is gone.)

## One code path

Everything that starts or stops a desktop goes through one sourced shell library,
`x11/apps/iosc-desktop/xios-session-lib.sh`, shipped in the `xios-session` package:

| Piece | Installed to | Role |
|------|--------------|------|
| `xios-session-lib.sh` | `/var/jb/libexec/xios-session/` | preflight, teardown, preset bring-up |
| `xios-session` | `/var/jb/usr/local/bin/` | CLI for a shell or SSH; `-d` sends the request through ioscd instead |
| ioscd `SESSION` verb | `/var/jb/tmp/ioscd.sock` | what the Xios app's picker sends; ioscd runs the same CLI |
| `run-shell.sh`, `run-mutter.sh`, `run-kde-plasma.sh` | `/var/jb/libexec/xios-session/` | bring-up scripts for iosc, raw Mutter, KDE |
| `launch-gnome-session.sh` | `/var/jb/usr/bin/` | GNOME launcher, shipped by `xios-session-stubs` |

`xios-session` depends on `xios-session-stubs` (since 1.0.82) because the library
needs `xios-setsid` and `xios-sysintd` for every flavor, not just GNOME. ioscd ships in
`xios-launcher-tools`, which `xios-core` pulls in.

Bring-up scripts resolve to the copy installed by the owning package first and fall
back to the pinned copy in `libexec/xios-session/`. `XIOS_SESSION_BRINGUP_DIR`
overrides both.

## Presets

`xios-session presets` prints the ones whose bring-up script and key binaries are
installed. A preset that is not installed is refused (exit 69) before the running
desktop is touched.

| Preset | Brings up | Needs |
|--------|-----------|-------|
| `iosc` | iosc + wallpaper + panel; Xwayland too when `xios-x11` is installed | `xios-core` |
| `gnome` | gnome-session + GNOME Shell on Mutter | `xios-gnome` |
| `kde`, `kde-mobile`, `kde-nano` | iosc + nested KWin + a Plasma shell | `xios-kde` |
| `mutter` | raw Mutter `--wayland`, no shell | a standalone `mutter` binary, which no meta ships |
| `app <name>` | a client on the running compositor, no teardown | |
| `stop` | tear down and return to SpringBoard | |

`--slot <name>` runs a desktop beside the main one (Xios v2 M0); teardown is scoped
to that slot.

## Rules the library keeps

- **Preflight before teardown.** Check the new preset can start, then tear down.
- **Teardown is complete.** Kill the old compositor, its shells, clients and session
  buses, and remove its sockets, or the next compositor collides on `wayland-0` and the
  ddx sockets. The kill pattern is anchored to binary paths so it never matches
  `xios-session` itself.
- **Settle the GPU between compositors.** The old compositor's IOSurfaces and Metal
  context have to be reclaimed before the new one allocates, or the foreground Xios app
  can be jetsammed mid-switch. `XIOS_SESSION_SETTLE` (default 2 s).
- **The screen must be awake.** A backgrounded Xios app gets a nil Metal device. The
  picker path is fine by construction; over SSH, unlock the iPad first.
- **Report honestly.** `xios-session-status.json` walks
  `stopping → starting → waiting → relaunching → up` (or `error`, `stopped`,
  `compositor-only`). GNOME only counts as `up` once its log says `GNOME Shell started
  at`; Mutter writes its display config before the JS shell loads, so the config file
  alone proves nothing.
