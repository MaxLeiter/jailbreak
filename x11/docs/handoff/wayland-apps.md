# Handoff: Wayland/desktop app wave + launch-in-iosc fixes

Owner scope: the ported desktop apps (terminal / viewers / media / utilities), why
some don't yet open a window in `iosc`, the fixes, and the on-device debug tooling.
Living doc — update the STATUS table and OPEN ITEMS as things land. Last touched
2026-07-06.

Related memory-of-record: the session narrative lives in the assistant memory files
`x11-desktop-apps-wave` and `x11-iosc-app-launch-fixes`; this file is the in-repo
version for any agent.

## App status

| App | Deb | On device | Launches in iosc? | Notes |
|---|---|---|---|---|
| grim 1.4.1 | out/ ✓ | installed | **YES (classic)** | upright screenshot verified; blank in `-native` |
| slurp 1.5.0 | out/ ✓ | installed | **YES** | layer-shell overlay + drag stdout verified |
| fuzzel 1.12.0+ios1 | repo/debs ✓ | installed | **YES** | launcher; iOS worker/lock/focus defaults; pinned <1.13 (pixman 0.40) |
| dunst 1.13.2+ios2 | out/ ✓ | installed | **YES** | notification popup verified through GDBus |
| foot 1.27.0+ios3 | repo/debs ✓ | installed | **YES** | PTY + locale + render-worker path verified |
| imv 5.0.1+ios5 | out/ ✓ | installed | **YES (Xwayland)** | `imv` wrapper still defaults to rootful Xwayland; native Wayland now reaches IOSurface window creation, then crashes in the desktop-GL canvas path |
| mpv 0.36.0+ios2 | repo/debs ✓ | installed | **YES** | ANGLE/Metal + iosc_iosurface verified via `mpv-iosc` |
| zathura 0.5.12 | out/ ✓ | installed | **YES** | GTK3 Wayland + PDF/poppler content render verified |
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
- **zathura PDF path — WORKS.** The device has `zathura-pdf-poppler 0.3.3`
  installed at `/var/jb/usr/lib/zathura/libpdf-poppler.dylib` alongside
  `libpoppler-glib8`. Generated a real Cairo PDF on-device with `pango-view
  --no-display`, verified the `%PDF-1.5` header, then launched
  `zathura /var/jb/tmp/xios-zathura-smoke.pdf` in classic `iosc` with
  `bin/iosc-capture-remote.sh`. The client stayed alive with no failure
  signature and the compositor capture shows the rendered PDF page:
  `artifacts/device-runs/20260705-zathura-pdf/cap-zathura-pdf.png`.
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
- **fuzzel — FIX BUILT + VERIFIED as `fuzzel 1.12.0+ios1`.** iOS returns
  `ENOSYS` from unnamed `sem_init()`, so the port now defaults render/match
  worker counts to zero and avoids touching uninitialized worker synchronization
  objects. It also strips directory components from absolute `WAYLAND_DISPLAY`
  values before building the lock filename (`/var/jb/tmp/wayland-0` must not
  become a nested lock path), and defaults to staying alive across keyboard-focus
  loss because Xios does not yet provide fuzzel with the wlroots focus lifecycle
  it expects. Built from scratch, installed on-device as `1.12.0+ios1`, and
  captured plain `fuzzel` in classic `iosc` with no failure signature:
  `artifacts/device-runs/20260705-fuzzel-ios1-plain/cap-fuzzel-ios1-plain.png`.
- **grim — WORKS, no fix needed.** Upright full-color screenshot captured in classic
  mode (2880×2160). Orientation is correct: output IOSurface is top-left, iosc.c:1654
  sends `flags=0` (no Y_INVERT) — do NOT "fix" it to Y_INVERT.
- **slurp — WORKS.** `slurp 1.5.0` maps its dim layer-shell overlay in
  classic `iosc` with no failure signature:
  `artifacts/device-runs/20260705-imv-slurp-fuzzel-clean/cap-slurp.png`.
  A driven `slurp -d` smoke also returned rc 0 and stdout geometry
  `100,100 226x161` after `bin/xios-device input drag 200 200 650 520`.
- **imv — WORKS via Xwayland; native Wayland progressed locally as
  `imv 5.0.1+ios5`.** The published `+ios3` package is still the practical
  fallback: `imv` builds both Wayland and X11 backends, `libxkbcommon0
  1.7.0+ios2` ships `libxkbcommon-x11`, `libxcb-xkb1` is installed, and
  `imv_5.0.1+ios3` carries the private `libinih.0.dylib` it links. The packaged
  `imv` wrapper now defaults to rootful `Xwayland :1` + `imv-x11` inside Xios
  Wayland sessions; set `XIOS_IMV_NATIVE_WAYLAND=1` to force the native Wayland
  backend for renderer work. Local `+ios5` patches make the native Wayland backend
  use a GLES context plus platform EGL display/window-surface entrypoints. After
  host DER re-signing and install, native imv now reaches
  `iosc_egl: bound iosc_iosurface` and `iosc_egl: window surface 1280x720 (3
  IOSurface buffers)`, then segfaults before drawing. The remaining native blocker
  is imv's desktop fixed-function renderer in `canvas.c` (`glPushMatrix`,
  `glBegin`, `GL_TEXTURE_RECTANGLE`) running on ANGLE/GLES; it needs a GLES2
  shader/texture path or a different native image viewer. On-device classic `iosc`
  capture kept plain
  `imv /var/jb/tmp/xios-imv-smoke.png` alive with empty stderr and a visible
  rendered PNG. The local compositor capture may appear rotated in portrait
  because it is a raw capture path; the on-device presentation was confirmed
  visually upright. Evidence:
  `artifacts/device-runs/20260705-imv-wrapper-ios3/cap-imv-wrapper.png`;
  native progress/crash evidence:
  `artifacts/device-runs/imv-native-platform-egl-20260706/cap-imv-native-platform-egl.log`.
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
  generated repo metadata/depictions are committed. Publish (`bin/publish-repo.sh` →
  `make-repo.py` → `vercel --prod`) is **Max-gated**; it does NOT stamp minos, so debs
  must be pre-stamped (`tools/stamp-minos.py`). As of 2026-07-06, the verified
  app-wave candidates have been copied to `repo/debs`, production-published, and
  observed from the iPad through an isolated `repo.maxleiter.com` apt cache:
  `foot_1.27.0+ios3_iphoneos-arm64.deb`,
  `fuzzel_1.12.0+ios1_iphoneos-arm64.deb`,
  `imv_5.0.1+ios3_iphoneos-arm64.deb`,
  `mpv_0.36.0+ios2_iphoneos-arm64.deb`,
  `libxkbcommon0_1.7.0+ios2_iphoneos-arm64.deb`, and
  `libxcb-xkb1_1.14+ios1_iphoneos-arm64.deb`.

## Debug tooling (built this round)

- `bin/iosc-capture.sh` — ON-DEVICE core: launch a client in iosc → grim screenshot →
  tail stderr → match a failure SIGNATURE (schema / GTK-backend / EGL / PTY / epoll /
  font / no-socket) → print root cause + fix. Exit 0 mapped / 1 launch-fail / 2
  precondition. Usage: `iosc-capture.sh <name> <cmd> [args...]`.
  It sets `LC_CTYPE=UTF-8`; the EGL matcher is failure-only so successful
  `IOSC_EGL_DEBUG=1` logs do not false-positive.
- `bin/iosc-capture-remote.sh` — MAC-SIDE driver: ships the core over ssh (via
  `apps/iosc-desktop/deploy-env.sh`), runs it, pulls PNG+log into `./iosc-capture-artifacts/`.
- `bin/iosc-appwave-smoke` — MAC-SIDE app-wave suite: starts/attaches to classic
  `iosc`, foregrounds Xios, prepares PNG/PDF fixtures, runs the capture helper
  for zathura/hitori/mpv/foot/fuzzel/slurp/imv/dunst, verifies wl-clipboard, and
  writes one artifact directory. Use `--only clipboard,foot,imv` for targeted
  reruns before a publish. Initial targeted smoke passed for clipboard+foot:
  `artifacts/device-runs/appwave-smoke-targeted-20260705/`. The runner guards
  `/var/jb/tmp/xios-active-session == iosc` before each Wayland check so concurrent
  KDE/GNOME session switches fail as session contention instead of app regressions.
  Fresh exclusive-device full smoke passed all rows on 2026-07-06:
  `artifacts/device-runs/appwave-smoke-exclusive-20260706/`.
- Design: the capture core is device-local (grim/wayland/compositor are on the iPad);
  only the orchestration varies (on-device vs mac-driven). Keep it stateless one-shot;
  a persistent daemon isn't worth it for a debug skill.

## Open items / TODO

- [ ] Port/fix imv's native Wayland renderer for iOS (desktop EGL/OpenGL path
  currently aborts; Xwayland fallback works).
- [x] Publish (Max-gated): app-wave candidates are in production `repo.maxleiter.com`;
  iPad-side isolated apt policy shows the expected production candidates.

## How to verify on-device

Ensure CLASSIC mode first (`ps aux | grep iosc` should show ioscbg + iosc-shell, not
`iosc -native`). Then, from the Mac:
```
x11/bin/iosc-appwave-smoke
x11/bin/iosc-appwave-smoke --only clipboard,foot,imv

x11/bin/iosc-capture-remote.sh zathura zathura /var/jb/tmp/doc.pdf
x11/bin/iosc-capture-remote.sh hitori  hitori
x11/bin/iosc-capture-remote.sh mpv     mpv-iosc /var/jb/tmp/clip.mp4
x11/bin/iosc-capture-remote.sh foot    foot --log-level=info
x11/bin/iosc-capture-remote.sh foot-pty-echo foot --log-level=info sh -lc 'printf "foot pty ok\n"; sleep 30'
x11/bin/iosc-capture-remote.sh fuzzel  fuzzel
x11/bin/iosc-capture-remote.sh slurp   slurp
```
Each prints alive/exited + the failure signature and pulls back a screenshot + log.

For the current imv fallback, start classic `iosc`, then run plain `imv`; the
packaged wrapper starts/reuses rootful Xwayland and forces the X11 backend:
```
x11/bin/xios-device session iosc
IOSC_CAP_WAIT=6 x11/bin/iosc-capture-remote.sh imv-wrapper imv /var/jb/tmp/xios-imv-smoke.png
```
