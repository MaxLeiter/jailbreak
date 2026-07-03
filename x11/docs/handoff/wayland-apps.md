# Handoff: Wayland/desktop app wave + launch-in-iosc fixes

Owner scope: the ported desktop apps (terminal / viewers / media / utilities), why
some don't yet open a window in `iosc`, the fixes, and the on-device debug tooling.
Living doc — update the STATUS table and OPEN ITEMS as things land. Last touched
2026-07-03.

Related memory-of-record: the session narrative lives in the assistant memory files
`x11-desktop-apps-wave` and `x11-iosc-app-launch-fixes`; this file is the in-repo
version for any agent.

## App status

| App | Deb | On device | Launches in iosc? | Notes |
|---|---|---|---|---|
| grim 1.4.1 | out/ ✓ | installed | **YES (classic)** | upright screenshot verified; blank in `-native` |
| slurp 1.5.0 | out/ ✓ | not yet | untested | region select; pairs w/ grim |
| fuzzel 1.12.0 | out/ ✓ | not yet | untested | launcher; pinned <1.13 (pixman 0.40) |
| dunst 1.13.2+ios1 | out/ ✓ | not yet | untested | notifications (GDBus, not sd-bus) |
| foot 1.27.0 | out/ ✓ | installed | **NO — root-caused** | PTY broken + C locale (see below) |
| imv 5.0.1 | out/ ✓ | installed | untested | wl_shm path (same as grim, should map) |
| mpv 0.36.0 | out/ (old) | installed (old) | **fix wired, unverified** | GPU via angle shim; needs classic verify |
| zathura 0.5.12 | out/ ✓ | installed | **fix ready, unverified** | GTK3 → needs libgtk-3-0+ios1 |
| hitori 44.0 | none in out/ | installed (old) | **2 fixes, unverified** | schema + GTK3 wayland |
| gnome-calculator 46.2 | in repo/debs | installed | (GTK4, works) | — |
| wl-clipboard 2.2.1 | out/ ✓ | installed | n/a (CLI) | needs iosc data-control (shipped) |

## The launch-in-iosc fixes

How apps are spawned: shell `sd_launch` (apps/iosc-shell/shell-draw.h:223) forks →
sets `WAYLAND_DISPLAY=/var/jb/tmp/wayland-0`, `XDG_RUNTIME_DIR=/var/jb/tmp`,
`GDK_BACKEND=wayland`, `GSK_RENDERER=cairo`, `GSETTINGS_BACKEND=memory` →
`dbus-run-session -- sh -lc <exec>`. Per-client stderr → `$XDG_RUNTIME_DIR/<client>.log`
under `IOSC_SHELL_DEBUG=1`.

- **GTK3 apps (zathura, hitori) — FIX BUILT, not yet installed/verified.** GTK3 was
  built with no wayland backend (`recipes/gtk+3.0.mk` `-Dwayland_backend=false`), so
  `gtk_init` fails under `GDK_BACKEND=wayland`. Rebuilt multi-backend (wayland+x11):
  `libgtk-3-0_3.24.38+ios1` in out/ (defines `gdk_wayland_*`, links libwayland-egl/
  cursor + xkbcommon). Build wall fixed: `libgtkintl` proxy-libintl shim reexport
  (commit 1b17f17). Device still has old 3.24.38 → **install the +ios1 debs**.
- **hitori schema — FIX COMMITTED (29df69e).** `g_settings_new("org.gnome.hitori")`
  aborts unless the schema is compiled; added build_info/hitori.postinst to run
  glib-compile-schemas. NOTE: `GSETTINGS_BACKEND=memory` does NOT help (schema lookup
  is separate from value storage). No hitori deb in out/ yet — must be packaged.
- **mpv GPU — FIX WIRED (f50115a, 926daac), deb not rebuilt.** iosc serves no
  `wl_drm`/`zwp_linux_dmabuf` — only `wl_shm` + custom `iosc_iosurface`. The angle deb
  stages `libiosc_egl.dylib` AS `/var/jb/lib/angle/libEGL.dylib` (install_name sub);
  any ANGLE-linking client transparently gets the iosc GPU path (kgx/GTK4 do this).
  mpv already links that libEGL. Added `Depends: angle` + `mpv-iosc` wrapper forcing
  `--vo=gpu --gpu-api=opengl --gpu-context=wayland --force-window=yes`. angle shim
  confirmed present on device (`nm -U /var/jb/lib/angle/libEGL.dylib | grep iosc_iosurface`).
- **foot — ROOT-CAUSED on device, fix pending.** Log shows window transport works
  (connects, sees output) then dies at the PTY: `terminal.c: failed to set initial
  TIOCSWINSZ: Inappropriate ioctl for device` + `fdm: no such FD: 7..13` → the pts is
  not a working tty in the sandbox. Secondary: `'C' is not a UTF-8 locale` (launch env
  has no `LANG`). Locale fix is trivial (set `LANG=C.UTF-8`/`en_US.UTF-8`); the PTY is
  the real work (iOS pts allocation — other iOS terminals do use /dev/ptmx, so foot's
  specific open/TIOCSCTTY path needs investigation).
- **grim — WORKS, no fix needed.** Upright full-color screenshot captured in classic
  mode (2880×2160). Orientation is correct: output IOSurface is top-left, iosc.c:1654
  sends `flags=0` (no Y_INVERT) — do NOT "fix" it to Y_INVERT.
- **Xwayland glamor — WORKS in rootful smoke.** `xwayland 23.2.7+ios2` enables the
  IOSurface glamor backend by default, depends on `angle`/`libepoxy0`, and no longer
  forces `XWAYLAND_NO_GLAMOR=1` in the run wrapper unless `XWAYLAND_GLAMOR=0`.
  On-device evidence shows Xwayland binding `iosc_iosurface`, iosc importing the
  Xwayland client IOSurfaces, and the compositor presenting via ANGLE/Metal. The
  Xwayland backend marks IOSurfaces as top-left through bit 31 of the iosc IOSurface
  `format` word; iosc keeps the old vertical flip for clients that pass `format=0`.
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
- **foot**: PTY (TIOCSWINSZ/fdm) + missing `LANG` (C locale not UTF-8).
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
- `bin/iosc-capture-remote.sh` — MAC-SIDE driver: ships the core over ssh (via
  `apps/iosc-desktop/deploy-env.sh`), runs it, pulls PNG+log into `./iosc-capture-artifacts/`.
- Design: the capture core is device-local (grim/wayland/compositor are on the iPad);
  only the orchestration varies (on-device vs mac-driven). Keep it stateless one-shot;
  a persistent daemon isn't worth it for a debug skill.

## Open items / TODO

- [ ] Verify gtk3-wayland: install `libgtk-3-0_3.24.38+ios1` (+gtk-3-bin+ios1, libgtkintl),
      launch zathura + hitori in CLASSIC mode, confirm a window maps.
- [ ] Verify mpv GPU: `mpv-iosc <clip>` (or the wrapper env) in classic; confirm window + video.
- [ ] foot: add `LANG=C.UTF-8` to the launch env (quick); investigate the iOS PTY path
      (why TIOCSWINSZ says not-a-tty) — the real blocker.
- [ ] Package hitori as a deb carrying build_info/hitori.postinst (none in out/ today).
- [ ] Rebuild the mpv deb with the wrapper + `Depends: angle` (only recipe committed).
- [ ] On-device verify slurp / fuzzel / dunst / imv.
- [ ] Publish (Max-gated): copy the app wave + `angle -3` into repo/debs, run make-repo, deploy.

## How to verify on-device

Ensure CLASSIC mode first (`ps aux | grep iosc` should show ioscbg + iosc-shell, not
`iosc -native`). Then, from the Mac:
```
x11/bin/iosc-capture-remote.sh zathura zathura /var/jb/tmp/doc.pdf
x11/bin/iosc-capture-remote.sh hitori  hitori
x11/bin/iosc-capture-remote.sh mpv     mpv-iosc /var/jb/tmp/clip.mp4
x11/bin/iosc-capture-remote.sh foot    foot --log-level=info
```
Each prints alive/exited + the failure signature and pulls back a screenshot + log.
