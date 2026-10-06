# Xios v2: investigation notes (2026-10-06)

File-level findings behind `xios-v2-design.md`. Paths relative to `x11/`. Line numbers are as
of origin/main ca2f1c2e; re-check before editing.

## Concurrency blockers (M0)

Resolved by M0 (xios-session 1.0.81, xios-session-stubs 0.2.12, xios-a11y-tools 0.2.17, iosc 0.9.49,
iosc-shell 0.9.14); see `docs/handoff/session-launcher.md`, "M0 coexistence". The findings below are
kept as the record of what the code did before. Note the two scripts live in `x11/wayland/`, not
`apps/iosc-desktop/`.

- `apps/iosc-desktop/run-kde-plasma.sh:240-251`: global mode kills every iosc, kwin_wayland,
  plasmashell, kded6, kactivitymanagerd, `dbus-daemon --session` on the system, slots included.
- `run-mutter.sh:50-54`: gated on slot but kills globally. `run-iosc.sh:30-33`: kills every iosc
  and the Xios app (legacy, still installed).
- `apps/iosc-desktop/xios-session-lib.sh`: global teardown regex `xs_kill_pattern` (~712) spares
  only pids whose pgid is recorded slot-owned (`xs_pid_belongs_to_slot` 669-673, used 731/747);
  `rm -rf` of `xios-kde-runtime` and `xios-session-bus` (751-763).
- GNOME slots never call `xs_record_slot_process_pgroups`; `launch-gnome-session.sh:111`
  re-parents via `xios-setsid` (new pgid); gnome-shell argv has no slot needle, so the stale
  sweep (`xs_sweep_stale_slot_registry` 599-653, needles 602-603) can drop a live GNOME slot.
- Slot namespace already exists: `xios-session-lib.sh:105-129` (wayland-<slot>, xios-<slot>.json,
  iosc-<slot>-{ddx,input,clipboard,wm}.sock, mutter-<slot>-*, kwin-<slot>, logs, status,
  `xios-displays.d/<slot>.json` 448-454, KDE runtime 1002-1008, GNOME runtime
  launch-gnome-session.sh:33-43). Slot ops still take the global lock (1388).
- `wayland/xios-a11yd.c:26` hardcodes `/var/jb/tmp/xios-a11y.sock`, ignores `XIOS_A11Y_SOCK`
  that `xios-start-a11y:22` sets. App `XiosA11y.swift:11`, iosc-host `HostA11y.swift:18`.
- `wayland/xios-sysintd.c:37` global `/var/jb/tmp/xios-sysint.sock` (env override at 184).
  GNOME starts one per session unconditionally (`launch-gnome-session.sh:155`); KDE
  (`run-kde-plasma.sh:914-918`) and `xs_start_native_helper` (383-385) skip if any instance runs.
  PulseAudio sink module hardcodes the path (`linux-build/audio/module-xios-sink.c:67`),
  `packages/xios-fhs/src/xios-hwbridged.c` too.
- iosc status producer is named just `iosc` (`wayland/iosc.c:7335`), two slots overwrite
  `xios-status.d/iosc.status`.
- iosc parses `-clipboard-sock`/`-wm-sock` (`wayland/iosc_options.c:48-50`) but a July build
  still bound the global ones; re-verify on the current binary.
- iosc refuses classic output while another session owns the active marker; slots bypass with
  `IOSC_IGNORE_ACTIVE_SESSION=1` (lib ~893).
- KDE home is shared and persistent (`run-kde-plasma.sh:878-882`); GNOME config is per run
  (`launch-gnome-session.sh:107-128`). Each session has its own bus via dbus-run-session.

## ioscd (M2)

- `apps/iosc-desktop/src/ioscd.c`: wire 14-16; policy 42-60, 1505-1602 (`destructive = preset
  != "app" && !slot` at 1523); cooldowns 571-606; `init_paths` 195-310 hardwires wayland-0,
  xios.json, iosc-ddx.sock, iosc-wm.sock, ioscd-bus, active marker; `ensure_iosc` 966;
  `classic_compositor_socket_live` 839-848; `compositor_process_alive` 859-886 matches comm
  globally; LAUNCH/app 1130-1300, 1537; 8 tracked children (567); serial accept loop 2040-2066.
- `com.max.ioscd.plist` sets no JetsamProperties. Every desktop process is jetsam band 180
  (JetsamEvent-2026-07-30-054155), SpringBoard 160.

## Pausing (M2)

- With no app client, iosc `repaint_delay_ms` falls back to paint-now (`iosc.c:2647-2656`) and
  the frame-callback clock keeps the last interval (`iosc.c:653-686`, default 16.667 ms at 271;
  callbacks after repaint at 729-733). Mutter has a fixed 60 Hz clock
  (`meta-backend-ios.c:99-100`, `meta-monitor-manager-ios.c:96,150-151`).
- iosc drops app clients on OUTPUT (rotation), see INVARIANTS 55.

## Wire (M3)

- One ddx server (`linux-build/patches/xios/xios_surface.c`, in libxios_glue, static in mutter
  `linux-build/recipes/mutter.mk:34,137`), one input server (`wayland/xios_input_socket.c`, hosts:
  iosc, mutter, sysintd, ios-inputd), one clipboard bridge (`wayland/iosc-clipboard-bridge.c`,
  also in mutter `meta-clipboard-ios.c:10`). KWin has no app channel (nested in iosc).
- `xios.json` is written with plain fopen("w") (`xios_surface.c:243-272`), not atomic.
- Server logs "bad handshake" and closes with nothing sent (`xios_surface.c:814-826`).
- `XSurface.c:632-640` send_msg treats a short non-blocking write as a drop, which can desync
  framing.
- App C clients with static state: `IoscInput.c:11-26`, `IoscClipboard.c:11`,
  `SysIntClient.c:22-23`. Handle-based input client already exists:
  `apps/iosc-host/Sources/IoscInput.{h,c}`.

## Memory (device, 2026-10-06)

iosc classic 141 MB footprint (IOSurface 71 MB = 3 x 2880x2160x4), Xios 60 MB, ioscbg 32 MB.
KDE: plasmashell 333 MB (peak 433), kwin 112 MB, outer iosc 79 MB => plan 600-650 MB per KDE
session. iosc-only ~190 MB. Device: ~26 MB free, compressor 1.25 GB in 362 MB.

### GNOME, measured in M0 (`footprint -p`, iPad7,12, 2026-10-06)

Measured on the real gnome-shell pid (`gnome-shell --wayland --wayland-display wayland-<slot>`, a
child of `xios-gnome-session-client`; the re-exec means the pid you launched is not the one to
measure). Run as a slot next to a KDE slot and the iosc shell; numbers are `Footprint:` per process,
summed over the session's process group.

| state | gnome-shell | whole session |
|---|---|---|
| just started, idle (Shell reported started) | 82 MB (peak 96) | 106 MB |
| gnome-text-editor + gnome-calculator open | 147 MB | 171 MB shell+session, 221 MB with the two apps (32 + 18 MB) |

Of the 82 MB at idle: IOAccelerator (graphics) 20 MB, MALLOC_TINY 18 MB, MALLOC_LARGE 14 MB,
IOSurface 13 MB (one 2160x1620 output buffer, not three), MALLOC_SMALL 6 MB. The rest of the session
is small: gjs notifications 5 MB, hwbridged 2.6 MB, sensord 2.1 MB, everything else 1-2 MB each.
So GNOME is the light desktop on this device: about 110 MB idle, about 175 MB with a couple of
windows, against KDE's 570 MB. The budget table should use ~150 MB as the GNOME estimate.

### KDE and the iosc shell with all of them running

| desktop | footprint |
|---|---|
| KDE desktop slot (kde-desktop) | 568 MB (plasmashell 332, kwin_wayland 113, iosc 79, kded6 8.5, kactivitymanagerd 7+11, powerdevil 6) |
| KDE desktop, non-slot (same build, later run) | 554 MB |
| iosc shell slot (iosc + bg/bar/dock) | 189-192 MB (iosc 139-141, ioscbg 32, bar 9, dock 9) |
| GNOME slot | 106 MB idle, 221 MB with two apps |

KDE + GNOME + the iosc shell together is about 0.9 GB on a device whose free pages sat at 30-110 MB
during the test; nothing was jetsammed over the ~15 minutes of the run, but the Xios app was not
foregrounded (slots do not present by default), so the numbers exclude its 60 MB and the presenting
cost. Two KDEs are out of the question (shared `~/.config`, and 1.1 GB).
