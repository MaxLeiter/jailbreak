# Xios v2: investigation notes (2026-10-06)

File-level findings behind `xios-v2-design.md`. Paths relative to `x11/`. Line numbers are as
of origin/main ca2f1c2e; re-check before editing.

## Concurrency blockers (M0)

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
session. iosc-only ~190 MB. GNOME unmeasured (measure gnome-shell with `footprint -p` on the
real pid; it re-execs). Device: ~26 MB free, compressor 1.25 GB in 362 MB.
