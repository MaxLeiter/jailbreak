# Handoff: Wayland/desktop app wave + launch-in-iosc fixes

Owner scope: the ported desktop apps (terminal / viewers / media / utilities), why
some don't yet open a window in `iosc`, the fixes, and the on-device debug tooling.
Living doc — update the STATUS table and OPEN ITEMS as things land. Last touched
2026-07-05.

Related memory-of-record: the session narrative lives in the assistant memory files
`x11-desktop-apps-wave` and `x11-iosc-app-launch-fixes`; this file is the in-repo
version for any agent.

## App status

| App | Deb | On device | Launches in iosc? | Notes |
|---|---|---|---|---|
| grim 1.4.1 | out/ ✓ | installed | **YES (classic)** | upright screenshot verified; blank in `-native` |
| slurp 1.5.0 | out/ ✓ | installed | untested | region select; pairs w/ grim |
| fuzzel 1.12.0 | out/ ✓ | installed | untested | launcher; pinned <1.13 (pixman 0.40) |
| dunst 1.13.2+ios2 | out/ ✓ | installed | **YES** | notification popup verified through GDBus |
| foot 1.27.0+ios3 | out/ ✓ | installed | **YES** | PTY + locale + render-worker path verified |
| imv 5.0.1 | out/ ✓ | installed | untested | wl_shm path (same as grim, should map) |
| mpv 0.36.0+ios2 | out/ ✓ | installed | **YES** | ANGLE/Metal + iosc_iosurface verified via `mpv-iosc` |
| zathura 0.5.12 | out/ ✓ | installed | **YES (window)** | GTK3 Wayland maps; PDF plugin/content load still needs a real doc/plugin check |
| hitori 44.0+ios1 | out/ ✓ | installed | **YES** | schema + GTK3 Wayland verified |
| gnome-calculator 46.2 | in repo/debs | installed | (GTK4, works) | — |
| wl-clipboard 2.2.1 | out/ ✓ | installed | **YES (CLI)** | round-trip verified with package-installed `iosc 0.9.10` |

## The launch-in-iosc fixes

How apps are spawned: shell `sd_launch` (apps/iosc-shell/shell-draw.h:223) forks →
sets `WAYLAND_DISPLAY=/var/jb/tmp/wayland-0`, `XDG_RUNTIME_DIR=/var/jb/tmp`,
`GDK_BACKEND=wayland`, `GSK_RENDERER=ngl`, `ANGLE_REAL_LIBEGL`, and
`GSETTINGS_BACKEND=memory`; terminal launch paths also set `LC_CTYPE=UTF-8` →
`dbus-run-session -- sh -lc <exec>`. Per-client stderr →
`$XDG_RUNTIME_DIR/<client>.log` under `IOSC_SHELL_DEBUG=1`.

- **GTK3 apps (zathura, hitori) — FIX INSTALLED + VERIFIED.** GTK3 was
  built with no wayland backend (`recipes/gtk+3.0.mk` `-Dwayland_backend=false`), so
  `gtk_init` fails under `GDK_BACKEND=wayland`. Rebuilt multi-backend (wayland+x11):
  `libgtk-3-0_3.24.38+ios1` in out/ (defines `gdk_wayland_*`, links libwayland-egl/
  cursor + xkbcommon). Build wall fixed: `libgtkintl` proxy-libintl shim reexport
  (commit 1b17f17). Device was updated with `libgtk-3-0_3.24.38+ios1`,
  `gtk-3-bin_3.24.38+ios1`, and `libgtkintl`; `libgdk-3.0.dylib` now links the
  Wayland backend libs and exports `gdk_wayland_*`. Captures:
  `artifacts/device-runs/20260704-appwave-smoke/cap-zathura.png`,
  `artifacts/device-runs/20260704-appwave-smoke/cap-hitori.png`.
- **hitori schema — FIX PACKAGED + VERIFIED.** `g_settings_new("org.gnome.hitori")`
  aborts unless the schema is compiled; added build_info/hitori.postinst to run
  glib-compile-schemas. NOTE: `GSETTINGS_BACKEND=memory` does NOT help (schema lookup
  is separate from value storage). Built and installed `hitori_44.0+ios1_iphoneos-arm64.deb`.
- **mpv GPU — FIX BUILT + VERIFIED as `mpv 0.36.0+ios2`.** iosc serves no
  `wl_drm`/`zwp_linux_dmabuf` — only `wl_shm` + custom `iosc_iosurface`. The angle deb
  stages `libiosc_egl.dylib` AS `/var/jb/lib/angle/libEGL.dylib` (install_name sub);
  any ANGLE-linking client transparently gets the iosc GPU path (kgx/GTK4 do this).
  mpv already links that libEGL. The wrapper now forces
  `--hwdec=no --vo=gpu --gpu-api=opengl --gpu-context=wayland --opengl-es=yes
  --force-window=yes`. The source build also skips hwdec enumeration when hwdec is
  `no`, avoiding the bad `_av_hwdevice_get_type_name` lazy bind against `libavcodec.59`
  (the symbol lives in `libavutil.57` on this FFmpeg set). The rebuilt deb was
  host-DER-signed for GPU client entitlements, installed on-device, and captured:
  `artifacts/device-runs/20260704-appwave-smoke/cap-mpv-ios2-clean.png`.
- **foot — FIX BUILT + VERIFIED as `foot 1.27.0+ios3`.** The original crash was
  not Wayland: iOS `posix_openpt()` returns a master that rejects master-side
  `TIOCSWINSZ` until its slave has been opened once. The patch runs
  `grantpt()`/`unlockpt()`/`ptsname()`, opens and closes the slave, then lets
  foot's existing `TIOCSWINSZ` path proceed. It also fixes the Darwin UTF-8
  locale case (`LC_CTYPE=UTF-8`, not `LANG=en_US.UTF-8`/`C.UTF-8`) and forces
  foot's existing zero-worker renderer because iOS returns `ENOSYS` from
  unnamed `sem_init()`. Device evidence:
  `artifacts/device-runs/20260705-foot-pty/cap-foot-ios3.png` and
  `artifacts/device-runs/20260705-foot-pty/cap-foot-pty-echo.png`; the latter
  rendered `foot pty ok` through a child shell on the pty.
- **grim — WORKS, no fix needed.** Upright full-color screenshot captured in classic
  mode (2880×2160). Orientation is correct: output IOSurface is top-left, iosc.c:1654
  sends `flags=0` (no Y_INVERT) — do NOT "fix" it to Y_INVERT.
- **wl-clipboard — FIX PACKAGED + VERIFIED with `iosc 0.9.10`.**
  `wl-copy` reached `zwlr_data_control_device_v1.set_selection`, but the compositor's
  pipe reader returned on `WL_EVENT_HANGUP|ERROR` before draining bytes already queued
  by the source. On iOS/kqueue that left `g_clip_items` empty and `wl-paste` saw
  `selection(nil)`. `wayland/iosc.c` now drains first and publishes on hangup. Built
  with `IOSC_BUILD_XWM=0 wayland/build-iosc.sh`, packaged as
  `iosc_0.9.10_iphoneos-arm64.deb`, installed with `dpkg -i`, and verified on-device:
  `dpkg-query -W iosc` reports `0.9.10`, `/var/jb/usr/local/bin/iosc` sha256 is
  `3e06159e628c6aad442f6e91f50a6e6b487fc37dd0c65f56ae9c1e3e73cc7850`, and
  `wl-copy --foreground` -> `wl-paste` returned `xios clipboard foreground 0.9.10`.
- **dunst — WORKS.** Use dunst, not mako. `dunst 1.13.2+ios2` runs as a Wayland
  layer-shell client under `dbus-run-session`, accepts
  `org.freedesktop.Notifications.Notify` through GDBus, and visibly renders the
  notification popup. Capture:
  `artifacts/device-runs/20260704-appwave-smoke/cap-dunst.png`.
- **Xwayland glamor — WORKS in rootful smoke.** `xwayland 23.2.7+ios2` enables the
  IOSurface glamor backend by default, depends on `angle`/`libepoxy0`, and no longer
  forces `XWAYLAND_NO_GLAMOR=1` in the run wrapper unless `XWAYLAND_GLAMOR=0`.
  On-device evidence shows Xwayland binding `iosc_iosurface`, iosc importing the
  Xwayland client IOSurfaces, and the compositor presenting via ANGLE/Metal. The
  Xwayland backend marks IOSurfaces as top-left through the documented
  `iosc_iosurface.format.flag_top_left` enum flag; iosc keeps the old vertical flip
  for clients that pass `format=0`.
  Evidence: `artifacts/device-runs/xwayland-glamor-ios2-flipfix-20260703-153036/compositor.png`.

## Gotchas (device + build)

- **CLASSIC vs NATIVE mode decides everything screencopy.** grim/screencopy only work
  in the CLASSIC desktop (`ioscbg` + iosc-shell on `wayland-0`). In `-native` mode
  (`iosc -native -s` owns `wayland-0`; also `wayland-native-0`) there is NO screencopy
  → grim errors "compositor doesn't support wlr-screencopy" / returns a near-empty grab.
  Check with `ps aux | grep iosc`. To verify grim / gtk3 / mpv-into-output you must be
  in classic mode.
- **`WAYLAND_DISPLAY` may be empty or point at native** in an ssh shell → force
  `WAYLAND_DISPLAY=/var/jb/tmp/wayland-0` for classic-desktop work.
- **`setsid` does not exist on iOS** — scripts must fall back to plain background.
- **iOS locale for terminal apps**: prefer `LC_CTYPE=UTF-8`. `LANG=en_US.UTF-8`
  and `C.UTF-8` are not available on-device; foot `+ios3`, shell launch, and the
  capture helper now use the working `LC_CTYPE` path.
- **mako is a dead end** (sd-bus is Linux-bound: ELF section error-maps, SCM_CREDENTIALS,
  kdbus, /proc machine-id). Use **dunst** (GDBus). Don't re-litigate.
- **fuzzel pinned <1.13** — 1.13+ needs pixman ≥0.46; the volume ships 0.40 (shared with
  foot/imv, don't bump).
- **repo/debs is gitignored** — debs deploy from the working tree at publish; only
  depiction `repo/meta/*.json` are committed. Publish (`bin/publish-repo.sh` →
  `make-repo.py` → `vercel --prod`) is **Max-gated**; it does NOT stamp minos, so debs
  must be pre-stamped (`tools/stamp-minos.py`).

## Debug tooling (built this round)

- `bin/iosc-capture.sh` — ON-DEVICE core: launch a client in iosc → grim screenshot →
  tail stderr → match a failure SIGNATURE (schema / GTK-backend / EGL / PTY / epoll /
  font / no-socket) → print root cause + fix. Exit 0 mapped / 1 launch-fail / 2
  precondition. Usage: `iosc-capture.sh <name> <cmd> [args...]`.
  It sets `LC_CTYPE=UTF-8`; the EGL matcher is failure-only so successful
  `IOSC_EGL_DEBUG=1` logs do not false-positive.
- `bin/iosc-capture-remote.sh` — MAC-SIDE driver: ships the core over ssh (via
  `apps/iosc-desktop/deploy-env.sh`), runs it, pulls PNG+log into `./iosc-capture-artifacts/`.
- Design: the capture core is device-local (grim/wayland/compositor are on the iPad);
  only the orchestration varies (on-device vs mac-driven). Keep it stateless one-shot;
  a persistent daemon isn't worth it for a debug skill.

## Open items / TODO

- [ ] zathura: verify real document rendering with the intended PDF/poppler plugin path
      (the GTK window maps; the smoke PDF was not recognized as a document).
- [ ] On-device verify slurp / fuzzel / imv.
- [ ] Publish (Max-gated): copy the app wave + `angle -3` into repo/debs, run make-repo, deploy.

## How to verify on-device

Ensure CLASSIC mode first (`ps aux | grep iosc` should show ioscbg + iosc-shell, not
`iosc -native`). Then, from the Mac:
```
x11/bin/iosc-capture-remote.sh zathura zathura /var/jb/tmp/doc.pdf
x11/bin/iosc-capture-remote.sh hitori  hitori
x11/bin/iosc-capture-remote.sh mpv     mpv-iosc /var/jb/tmp/clip.mp4
x11/bin/iosc-capture-remote.sh foot    foot --log-level=info
x11/bin/iosc-capture-remote.sh foot-pty-echo foot --log-level=info sh -lc 'printf "foot pty ok\n"; sleep 30'
```
Each prints alive/exited + the failure signature and pulls back a screenshot + log.
