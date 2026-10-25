# Handoff: first Wayland app wave

Scope: the first batch of standalone desktop apps (terminal, viewers, media,
utilities), the fixes that got each one to open a window in `iosc`, and the
on-device capture tooling. The second batch lives in `wayland-extra-apps.md`.

Last checked against `repo/Packages`: 2026-10-25.

## Current state

Everything in this wave is published on `repo.maxleiter.com` and has at least
one on-device capture in classic `iosc`.

| Package (indexed) | Launches in iosc | Notes |
|---|---|---|
| `foot 1.27.0+ios3` | yes | PTY, locale and render-worker fixes below |
| `fuzzel 1.12.0+ios1` | yes | pinned below 1.13 (pixman 0.40) |
| `imv 5.0.1+ios13` | yes, native Wayland and X11 | wrapper still prefers the X11 backend, see gotchas |
| `mpv 0.36.0+ios2` | yes | ANGLE/Metal through `iosc_iosurface`, launch with `mpv-iosc` |
| `zathura 0.5.12+ios1`, `zathura-pdf-poppler 0.3.3+ios1` | yes | GTK3 Wayland, real PDF rendered |
| `hitori 44.0+ios1` | yes | needs its compiled schema (postinst) |
| `dunst 1.13.2+ios2`, `mako 1.9.0+ios1` + `basu 0.2.1+ios1` | yes | both notification daemons work; dunst is the default |
| `grim 1.4.1+ios1`, `slurp 1.5.0+ios1` | yes | screencopy only exists in classic mode |
| `wl-clipboard 2.2.1+ios1` | yes (CLI) | needed an iosc fix, below |
| `gnome-calculator 46.2+ios1` | yes | GTK4 |
| `ladybird-wayland 0.1.0+wl5` | yes | details in `../ladybird-plan.md` |
| `libgtk-3-0 3.24.38+ios3` | n/a | GTK3 now has the Wayland backend |

X11 clients (imv's X11 backend, and anything else without Wayland support) run
through rootless Xwayland under iosc. Since iosc 0.9.51 the XWM is built in by
default, and `xios-session` hands apps it launches the right `DISPLAY`. The old
software Xios X server is retired. See `iosc-compositor.md` for the XWM.

## Root causes worth remembering

How the shell launches apps: `sd_launch` in `apps/iosc-shell/shell-draw.h` sets
`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `GDK_BACKEND=wayland`, `GSK_RENDERER=ngl`,
`ANGLE_REAL_LIBEGL`, `GSETTINGS_BACKEND=memory` and `LC_CTYPE=UTF-8`, then runs
`dbus-run-session -- sh -lc <exec>`. With `IOSC_SHELL_DEBUG=1` each client's
stderr goes to `$XDG_RUNTIME_DIR/<client>.log`.

- **GTK3 apps (zathura, hitori, and the whole second wave).** GTK3 was first
  built with `-Dwayland_backend=false`, so `gtk_init` failed under
  `GDK_BACKEND=wayland`. `linux-build/recipes/gtk+3.0.mk` now builds wayland+x11. The build
  wall on the way was the `libgtkintl` proxy-libintl reexport.
- **hitori.** `g_settings_new("org.gnome.hitori")` aborts unless the schema is
  compiled, so `linux-build/build_info/hitori.postinst` runs `glib-compile-schemas`.
  `GSETTINGS_BACKEND=memory` does not help: schema lookup is separate from value
  storage.
- **mpv.** iosc serves no `wl_drm` or `zwp_linux_dmabuf`, only `wl_shm` and
  `iosc_iosurface`. The angle deb installs `libiosc_egl.dylib` as
  `/var/jb/lib/angle/libEGL.dylib`, so any client that links ANGLE's libEGL gets
  the iosc GPU path for free. The wrapper forces `--hwdec=no --vo=gpu
  --gpu-api=opengl --gpu-context=wayland --opengl-es=yes --force-window=yes`.
  Skipping hwdec enumeration also avoids a bad lazy bind of
  `_av_hwdevice_get_type_name` (it lives in `libavutil.57`, not `libavcodec.59`).
- **foot.** The crash was not Wayland. iOS `posix_openpt()` returns a master
  that rejects `TIOCSWINSZ` until the slave has been opened once, so the patch
  opens and closes the slave first. iOS also returns `ENOSYS` from unnamed
  `sem_init()`, so foot runs with zero render workers.
- **fuzzel.** Same `sem_init()` problem (zero workers). It also strips the
  directory from an absolute `WAYLAND_DISPLAY` before building its lock file
  name, and stays alive across keyboard-focus loss because iosc does not give it
  the wlroots focus lifecycle it expects.
- **wl-clipboard.** `wl-copy` reached `set_selection`, but iosc's pipe reader
  returned on `WL_EVENT_HANGUP` before draining bytes the source had already
  queued. On kqueue that left the selection empty. `wayland/iosc.c` now drains
  first and publishes on hangup (fixed in iosc 0.9.10).
- **grim orientation.** The output IOSurface is top-left and iosc sends
  `flags=0` (no `Y_INVERT`). The capture is upright. Do not "fix" it to
  `Y_INVERT`.
- **imv native Wayland.** imv's renderer is fixed-function desktop GL. The
  `+ios13` patch stack gives it a GLES2 shader canvas on ANGLE, uses the platform
  EGL entry points only (the legacy `eglGetDisplay(wl_display)` fallback is gone
  on Apple, so a missing entry point fails early instead of taking the wrong
  ABI), uploads Cairo ARGB32 as RGBA, and copies large-image tiles into a
  contiguous buffer.
- **Ladybird Wayland fonts.** WebContent reads fonts only from
  `resource://fonts`, never from `Gfx::FontDatabase::font_directories()` (only
  Compositor does), and upstream `Base/res/fonts` has no monospace face. Without
  a fixed-width font WebContent aborts on every launch. The package ships the
  checksum-pinned Liberation family via `xstage_lagom_fonts` (`lib/xlib.sh`).
  `--force-fontconfig` used to abort (`VERIFY(font_manager)` in
  `TypefaceSkia.cpp`); patch `0010-ios-m0-reject-force-fontconfig.patch` now
  rejects the flag with a clear error.
- **Xwayland glamor.** `xwayland 23.2.7+ios5` uses the IOSurface glamor backend
  on ANGLE with no software fallback. It marks its buffers top-left through
  `iosc_iosurface.format.flag_top_left`; iosc still flips clients that send
  `format=0`.

## Gotchas

- **Classic vs native mode.** grim and screencopy only work in the classic
  desktop (`ioscbg` + iosc-shell on `wayland-0`). Under `iosc -native` there is
  no screencopy and grim returns an error or a near-empty grab. Check with
  `ps aux | grep iosc` before blaming an app.
- **`WAYLAND_DISPLAY` over ssh** may be empty or point at the native socket.
  Force `WAYLAND_DISPLAY=/var/jb/tmp/wayland-0` for classic-desktop work.
- **No `setsid(1)` on iOS.** Use the packaged `$LIBEXEC/xios-setsid` (from
  `xios-session-stubs`) or fall back to plain backgrounding.
- **Locale.** Use `LC_CTYPE=UTF-8`. `LANG=en_US.UTF-8` and `C.UTF-8` do not
  exist on the device.
- **imv picks X11 whenever `DISPLAY` is set.** The wrapper
  (`ports/imv/patches/0002-ios-xwayland-wrapper.patch`) runs `imv-wayland` only
  with `XIOS_IMV_NATIVE_WAYLAND=1`; otherwise it uses `imv-x11` on `DISPLAY`, and
  with no `DISPLAY` it starts its own rootful `Xwayland :1`. The wrapper predates
  the working native renderer and the per-slot X displays in iosc 0.9.51, so it
  is due a look.
- **fuzzel stays below 1.13.** 1.13 needs pixman 0.46; the device has 0.40,
  shared with foot and imv. Don't bump it alone.
- **Session switches kill running smokes.** A concurrent `xios-session` switch
  removes `wayland-0` mid-run and looks exactly like an app crash ("Broken
  pipe"). Use a dedicated slot or make sure nobody else is driving the device.

## Debug tooling

- `bin/iosc-capture.sh` (on device): launch a client in iosc, take a grim
  screenshot, tail stderr, and match a failure signature (schema, GTK backend,
  EGL, PTY, epoll, font, no socket). Exit 0 mapped, 1 launch failure,
  2 precondition. The EGL matcher only fires on failures, so
  `IOSC_EGL_DEBUG=1` logs don't false-positive.
- `bin/iosc-capture-remote.sh` (Mac side): ships the core over ssh, runs it,
  and pulls the PNG and log into `./iosc-capture-artifacts/`.
- `bin/iosc-appwave-smoke` (Mac side): runs the whole wave in classic `iosc`
  and checks `wl-clipboard`. `--only clipboard,foot,imv` reruns a subset. It
  checks `/var/jb/tmp/xios-active-session == iosc` before each step so a
  concurrent session switch shows up as contention, not an app regression.

The capture core is deliberately a stateless one-shot that runs on the device.
A daemon isn't worth it for a debug helper.

## How to verify on device

Make sure the classic desktop is up (`ioscbg` + iosc-shell, not
`iosc -native`), then from the Mac:

```
x11/bin/iosc-appwave-smoke
x11/bin/iosc-appwave-smoke --only clipboard,foot,imv

x11/bin/iosc-capture-remote.sh zathura zathura /var/jb/tmp/doc.pdf
x11/bin/iosc-capture-remote.sh mpv     mpv-iosc /var/jb/tmp/clip.mp4
x11/bin/iosc-capture-remote.sh foot-pty-echo foot --log-level=info sh -lc 'printf "foot pty ok\n"; sleep 30'
```

Native imv:

```
x11/bin/xios-device session iosc
IOSC_CAP_WAIT=4 x11/bin/iosc-capture-remote.sh imv-native \
  env IOSC_EGL_DEBUG=1 ANGLE_REAL_LIBEGL=/var/jb/lib/angle/libEGL.angle.dylib \
  XIOS_IMV_NATIVE_WAYLAND=1 imv /var/jb/tmp/xios-imv-native-proof.jpg
```

## History

The wave was ported and smoked between 2026-07-04 and 2026-07-07, published to
production on 2026-07-06 (foot, fuzzel, imv, mpv, libxkbcommon0, libxcb-xkb1
first), and the rest followed in later scoped publishes. mako/basu were added
on 2026-07-29. The old `ladybird-xios-launcher` shortcut package was removed
from the repo on 2026-07-29; it had put a third "Ladybird" entry in Sileo.
