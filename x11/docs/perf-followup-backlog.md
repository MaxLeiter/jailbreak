# Perf / follow-up backlog

Started as an audit on 2026-06-30 of every place the desktop did CPU work the GPU
should do, or carried a shortcut that risked correctness. Rechecked against the tree
on 2026-10-25. Line numbers drift; re-grep before editing. The item numbers (P0.1
and so on) are referenced from commits and other docs, so they stay.

## Still open

- **P0.4b: native flavor is unpaced.** The fullscreen path is vblank-paced (see P0.4
  below), but the native iPadOS host (`apps/iosc-host`) draws per-window canvases over
  the NATIVE_FRAME records and only got the `CAFrameRateRange`. Pacing it needs
  per-window pacing state on the 0x40-0x5f records. Owner: native-iPadOS track.
- **P0.5: screenshots are a software readback.** `wayland/iosc_screencopy.c` serves
  wlr-screencopy through `xios_read_output_region()` in
  `linux-build/patches/xios/xios_surface.c`, which locks the output IOSurface and
  copies rows on the CPU. Per screenshot, not per frame, so it ranks low. The seam for a
  GPU blit (output IOSurface to the client's buffer) is named in the file header.
- **P2.1: the megafile refactor is still queued.** `iosc.c` is about 7,500 lines and
  `XScreen.swift` about 5,300 (see `refactor-plan.md`). The Xios v2 app rewrite on the
  `claude/xios-v2-app` branch replaces `XScreen.swift` outright, so only the iosc.c half
  is worth planning on main.
- **P2.5: Nautilus ecosystem holes.** No gvfs (Trash and Network are empty) and no
  tracker-miners indexer, so search is inert even though `libtracker-sparql` ships.
- **P3: the bar/dock painter is the last CPU renderer in the desktop.** iosc-shell
  draws its chrome with cairo into shm (`apps/iosc-shell/shell-draw.h`). With per-surface
  texture caching (P0.2) a static panel costs nothing; it only shows when the panel
  animates. The `GSK_RENDERER=ngl` setenv in `shell-draw.h` is for apps the shell
  launches, not for the shell's own painting, which is easy to misread.
- **P0.1 caveat: shell-launched GTK4 apps may CPU-render.** Everything the desktop
  launches is forced to GSK-ngl (ioscd, iosc-shell, `xios-session-lib.sh`,
  `xios-capability-profiles.sh`). But a GTK4 app started from a login shell over SSH
  reads `/var/jb/etc/profile.d/10-gtk-renderer.sh`, and the published
  `libgtk-4-1 4.14.5+wl1` still sets that to cairo. `linux-build/recipes/gtk4.mk` already writes
  `ngl`, so the fix is a rebuild and version bump. On a device where that conffile was
  ever edited, dpkg will keep the old one (look for a `.dpkg-dist` beside it), so check
  it by hand after the upgrade.

## Deliberate degradations (not bugs)

- libei/libeis is a link-only shim: input capture and remote-desktop input do nothing.
- `xios-login1-stub` answers the logind calls gnome-session and gsd make; there is no
  real session or power management behind it.
- iosc has no CPU compositor or CPU-sync fallback. GPU init, shared-event creation and
  runtime GPU loss all fail closed.
- X11 is hardware-only rootless Xwayland on iosc. Xvfb and VNC remain as headless or
  remote tools.
- gnome-text-editor instead of gedit (libpeas-2 typelib chain).
- gnome-shell's JS runs on the interpreter-only `libmozjs-115-0` by default. The JIT
  build (`libmozjs-115-jit-0`) is a drop-in replacement but needs the
  dynamic-codesigning entitlement on the embedder. Compositing stays on the GPU either way.
- ios-inputd degrades gracefully without input-method-v2 / virtual-keyboard-v1; iosc
  advertises both.

## Done

Kept short so the numbers still resolve. Details are in the commits.

- **P0.1** GTK4 clients render GSK-ngl on ANGLE Metal into rotating IOSurfaces handed
  to iosc zero-copy. The ANGLE package stages the iosc EGL shim as
  `/var/jb/lib/angle/libEGL.dylib` and keeps the real ANGLE at `libEGL.angle.dylib`.
- **P0.2** Per-surface shm texture cache with `glTexSubImage2D` damage uploads; cursor
  motion costs zero uploads (5aaf0fe).
- **P0.3** No per-frame `glFinish` or readback in the compositor; validation reads and
  logs sit behind `IOSC_DEBUG` (b9cbdec).
- **P0.4** Display-refresh pacing (2026-07-29). The app streams its display clock as
  `XIOS_MSG_PACING`, iosc schedules the repaint to finish a quarter interval before the
  app samples, and `wl_surface.frame` retires on the drawable's presented handler. Wire
  values are deltas from send time, never timestamps, because `CACurrentMediaTime()`
  and `CLOCK_MONOTONIC` are different clocks. The multi-buffer half also landed since:
  the output is a queue of up to three IOSurfaces (`xios_output_queue.h`) for stream-v2
  consumers. `pacing=vblank` shows in `xios-status`.
- **P0.6** The EGL shim swaps with an EGL fence instead of `glFinish` and rotates
  `IOSC_NBUF=3` buffers on release.
- **P0.7** Xwayland's glamor IOSurface damage uses an EGL fence.
- **P1.1** iosc uses the shared `xios_input_socket` reader; the inline copy is gone.
- **P1.2** MetaBackendIOS's glue contract is checked against the canonical headers.
- **P1.3** MetaBackendIOS has a real keymap and sized stage; `get_input_settings()`
  returning NULL is intentional (no libinput devices on iOS).
- **P1.4** Cogl-on-ANGLE first pixels, IOSurface client import, packaged GNOME session.
- **P1.5** xdg-activation tokens carry app_id.
- **P1.6** `ioscd.sock` is `mobile:mobile` 0660.
- **P1.7** The input socket flushes Wayland clients once per batch.
- **P2.2** Tracker builds with ICU; EDS 3.52.4 is published. Whether the default Shell
  uses the EDS calendar is tracked in `handoff/gnome-session.md`.
- **P2.3** Full PulseAudio 17 with the Xios sink and mic source shipped
  (`pulseaudio`, `xios-audio-server`, `xios-media-server`).
- **P2.4** Obsolete: it was about packaging the software Xios X server, retired
  2026-07-29.
- **P2.6, P2.7, P2.8** doc, working-tree and kgx launcher cleanups.
- **P3 libgtop** `libgtop_ios.c` implements process enumeration through Darwin sysctls
  (`libgtop-2.0-11 2.41.3+ios2`).

MetalFX spatial upscaling also landed with P0.4 (opt-in, `IOSC_UPSCALE=auto|<factor>`
or `XIOS_UPSCALE` in the app's environment; `upscale=` in `xios-status`). Its write-up
and the thermal/jetsam follow-up are in `docs/ios-platform-features.md` on the unmerged
`claude/ios-features-graphics-50ff62` branch.
