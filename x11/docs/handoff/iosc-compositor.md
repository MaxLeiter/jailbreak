# iosc-compositor: the iosc Wayland compositor and the app wire

Owns `iosc`, the C compositor on libwayland-server that composites clients on the GPU
(ANGLE on Metal) into IOSurfaces for the Xios app and the native per-window hosts to
present. Also owns the wire between compositor and app hosts (present, input, clipboard,
cursor, native per-window rendezvous) and the rootless Xwayland XWM. Every flavor runs on
iosc: the iosc shell directly, KDE as KWin nested inside it, native mode through its
per-window canvases. (GNOME uses Mutter's own iOS backend, see `mutter.md`.)

## Current state (2026-10-25)

- Production serves `iosc 0.9.51` (depends on `angle ...+es3-16`, `libxcb1`). It is the
  build every flavor installs through `xios-runtime`.
- **X11 works under iosc.** 0.9.50 builds the XWM by default; 0.9.51 makes X windows
  actually appear (the WM redirects the root's subwindows, X windows on non-32-bit visuals
  composite opaque, iosc picks the X display per slot). Device-verified on 2026-10-25:
  `glxgears` maps as an iosc window through the XWM, and two slots get `:0` and `:1` with
  their own sockets. The XWM stays dormant unless `IOSC_XWAYLAND` is set;
  `xios-session` sets it for the iosc preset when Xwayland is installed (the `xios-x11`
  flavor). See the 2026-10-25 note below for how X11 apps get `DISPLAY`.
- Presentation is fenced and triple-buffered: three output IOSurfaces rotated under an
  explicit ownership scheduler (`xios_output_queue.h`), a GPU release wait before reuse,
  and a direct-present path that forwards a fullscreen opaque client IOSurface (KWin) to the
  app with no outer draw. Device-verified with KDE in July (direct and composited
  transitions, app kill and reconnect).
- Coexistence (Xios v2 M0, 0.9.49): each slot's iosc publishes status as `iosc-<slot>` and
  binds `iosc-<slot>-clipboard.sock` and `iosc-<slot>-wm.sock`. See `session-launcher.md`.
- Startup fails closed: no ANGLE or IOSurface, no compositor. The old CPU fallback is gone.

**Open**

1. XWM coverage beyond `glxgears`: focus, close, popups and menus of a real toolkit app
   (`xterm`, a GTK3 app on `GDK_BACKEND=x11`) through the XWM.
2. X11 launch paths outside `xios-session app`: ioscd's direct `LAUNCH` (Home Screen
   launchers) sets no `DISPLAY` and runs clients as `mobile` while Xwayland runs as root,
   and iosc-shell's panel launches set no `DISPLAY` either.
3. The physical input matrix in `xios-app.md` (pointer lock, confinement, custom cursor
   surfaces, five-button chording, wheel versus finger axis source) has not been run on
   the shipped build.
4. Damage: cache the static layers (wallpaper, panel, dock).
5. `iosc.c` is still about 7.5k lines. The next low-risk seams are output and damage
   bookkeeping, `wl_surface` lifecycle, then input routing; keep each slice buildable and
   device-smoked.

## Key files (`x11/wayland/` unless noted)

- `iosc.c` plus the split-out modules (`iosc_options`, `iosc_util`, `iosc_iosurface`,
  `iosc_gl`, `iosc_render_plan`, `iosc_text_input`, `iosc_pointer_ext`, `iosc_tablet`,
  `iosc_viewport`, `iosc_screencopy`, `iosc_kde_output`, `iosc_foreign_toplevel`).
- `iosc_xwm.{c,h}` and `protocols/xwayland-shell-v1.xml`: the rootless XWM.
- `xios_input_socket.{c,h}`: the input side of the wire, shared with Mutter's backend.
- `xios_canvas.{c,h}`: native per-window canvases and the `iosc-native.sock` rendezvous.
- `x11/linux-build/patches/xios/xios_surface.{c,h}` (present side) and
  `xios_output_queue.h` (output ownership; host test `xios-output-queue-test.c` runs on
  every `build-iosc.sh`).
- `x11/apps/shared/XiosProtocol.h`: the wire definition. One 32-byte `xios_msg`;
  present/control codes below 0x100 (`HELLO`, `DIRTY`, `CURSOR`, `CLIPBOARD`, `RELEASED`,
  native `BIND`/`WINDOW_*`/`NATIVE_FRAME`, ...) and input codes `XIOS_IN_*` from 0x100. Unknown
  codes are fatal on purpose.
- `iosc_iosurface` (private Wayland protocol): version 1 everywhere (iosc, the ANGLE EGL
  producer, Mutter, KWin, Xwayland). Every frame carries a 32-byte broker token and a
  non-zero `MTLSharedEvent` value; the `com.max.xios.metal-event-broker` XPC service turns
  tokens into events. There are no unfenced variants.
- `build-iosc.sh` (cross build plus host tests; `IOSC_BUILD_XWM=0` drops the XWM),
  `package-iosc.sh`, `run-iosc.sh`, `run-kgx.sh`, `run-xwayland.sh` (rootful harness).
- `/var/jb/tmp/xios.json` is what the compositor writes for the app: size, stride, format,
  ddx and input sockets. Anything mapping framebuffer to screen must read it, never a
  constant. Slots write `xios-<slot>.json`.

## Debug switches

`IOSC_DAMAGE_STATS=1`, `IOSC_DAMAGE_REASON=1` (output and per-surface damage, occlusion),
`IOSC_NATIVE_STATS=1` (native canvas repaint counters), `IOSC_XWM_DEBUG=1` (X events,
errors, map requests, depth), `IOSC_FULLSCREEN_TOPLEVELS=1` (a nested compositor owns the
whole output; KDE sets it), `IOSC_IGNORE_ACTIVE_SESSION=1` (start a classic iosc over
another active owner, diagnostics only). Logs: `/var/jb/tmp/iosc.log` (or the slot's log),
shell stderr with `IOSC_SHELL_DEBUG=1`. Input socket: `/var/jb/tmp/iosc-input.sock`.

## Gotchas and root causes

- **Logical vs output pixels.** iosc composites at logical size times scale (default
  `1440x1080` at 2x, so a `2880x2160` IOSurface). Input records carry output pixels and are
  divided by the scale exactly once.
- **ANGLE `eglWaitSync`.** Public ANGLE `es3-15` did not export the EGL 1.5 `eglWaitSync`
  core entry point, so release waits could never queue. `es3-16` does; iosc depends on it.
- **A pbuffer cannot be both a bound texture and a draw surface.** Output IOSurfaces are
  permanent texture-backed FBO targets, and the context stays current on a dedicated 1x1
  pbuffer. Reusing an output pbuffer as a draw surface failed with `EGL_BAD_ACCESS` on
  rotation. A failed `eglBindTexImage` must destroy the pbuffer, not cache a zero texture.
- **A dropped app socket does not free its buffers.** Pending output buffers stay
  quarantined until the next completed app handshake proves the old Metal consumer is gone;
  otherwise iosc could write into a surface the dead app was still sampling.
- **XWM start-up.** Do not block on Xwayland's `-displayfd` before `wl_display_run()`:
  Xwayland writes it only after `InitOutput`, which round-trips with the compositor. Read
  it from the event loop.
- **Rootless Xwayland only makes a `wl_surface` for a manually redirected top-level.** The
  WM must redirect the root's subwindows (Composite, Manual), as wlroots and weston do.
- **Xwayland lock files never appear on iOS**, so two Xwaylands both took `:0` and the
  second unlinked the first one's socket. iosc picks the display and passes it explicitly.
- **No MIT-SHM.** iOS has no SysV shm and clients that see the extension die; Xwayland runs
  with `-extension MIT-SHM`.
- **Alpha on non-32-bit visuals is undefined** in the IOSurface; composite those opaque.
- **Nested compositors need frame callbacks after the mapping commit.** KWin stalled until
  iosc answered `wl_surface.frame` requested after the commit that made a surface visible;
  iosc now runs a real frame clock (c382a9b6).
- **Public `.deb` filenames are immutable.** Several iosc versions (0.9.39, 0.9.41) were
  skipped because a different payload already had that name. Bump, never replace.

## History (short)

- 0.8.0 to 0.9.9 (late June to early July): first release, layer-shell translucency,
  client-disconnect cleanup, damage tracking with up to 16 rects and occlusion, the protocol
  enum and validation, OUTPUT resize for rotation, haptic broadcast. Xwayland glamor via
  `iosc_iosurface` verified on device with `xwayland 23.2.7+ios2`.
- 0.9.15 (2026-07-05): fullscreen-toplevel mode for KDE Mobile.
- 0.9.20 (2026-07-19): stateful keys with modifier masks, chording, pointer lock and
  confinement, client cursor surfaces, `ios-inputd` for external compositors.
- 0.9.27 to 0.9.42 (2026-07-29): broker-token GPU fences, the single v1 `iosc_iosurface`
  contract, fail-closed start-up, input-method v1, native and classic selective repaint.
- 0.9.44 to 0.9.47 (2026-07-30 to 08-02): triple-buffered fenced output, direct present,
  the output-queue scheduler, disconnect quarantine, non-fatal IOSurface import failure.
- 0.9.48 and 0.9.49 (2026-10): audit rebuild, M0 per-slot sockets and status.
- 0.9.50 and 0.9.51 (2026-10-25): XWM by default, then X windows that actually show up.

## Dated notes

- 2026-10-25 X11 under iosc (iosc 0.9.50, xios-session change unpackaged): the published `xios-x11` flavor installed Xwayland but nothing started it (iosc built without the XWM, nothing set `IOSC_XWAYLAND`). Now: `build-iosc.sh` builds the XWM by default and the deb depends on `libxcb1`; the XWM stays dormant unless `IOSC_XWAYLAND` is truthy, so non-X11 sessions only gain a libxcb link. `xios_session_iosc` exports `IOSC_XWAYLAND=1` + `IOSC_XWAYLAND_BIN` when `$XS_PREFIX/bin/Xwayland` exists (each slot's iosc spawns its own Xwayland; `IOSC_XWAYLAND=0` opts out). Fixed a start-up deadlock that had kept the XWM from ever working: `iosc_xwm_start()` blocked reading `-displayfd` before `wl_display_run()`, but Xwayland writes it only after `InitOutput`, which round-trips with iosc. The display fd is now read from the event loop and the xcb/`WM_S0` setup runs then. Xwayland also gets `-extension MIT-SHM` (as in `run-xwayland.sh`) and iosc's own `-s` socket as `WAYLAND_DISPLAY`. **How X11 apps get DISPLAY:** once the WM owns the display, iosc latches `x11-display` = `:N` in its `xios-status.d` sidecar (`iosc.status` or `iosc-<slot>.status`; `none` if Xwayland dies; cleared on exit). `xios_session_app` (which the ioscd `SESSION app` path, i.e. the X11 picker, also runs) reads it via `xs_iosc_x11_display`, requires `/tmp/.X11-unix/X<N>` to exist, and passes `DISPLAY` plus `GDK_BACKEND=wayland,x11` when the session owner is iosc. Host coverage: `apps/iosc-desktop/test-session-x11.sh`. **Not yet device-proven:** Xwayland actually spawning under iosc and mapping an X window (`xterm`) as its own iosc surface; focus/close/popups through the XWM; slots getting distinct displays. **Known gaps:** ioscd's direct `LAUNCH` path (home-screen launchers) still sets no `DISPLAY`, runs clients as `mobile` while Xwayland runs as root (X local-user access would refuse them), and its own iosc restart does not set `IOSC_XWAYLAND`; xios-session needs a `Depends: iosc (>= 0.9.50)` bump or an older iosc just logs `Xwayland XWM failed to start`.
- 2026-10-25 follow-up (iosc 0.9.51, xios-x11 0.1.12, both published): the device test of
  0.9.50 got Xwayland running and X clients connecting (`glxgears` at about 190 fps) but no X
  window on screen. 0.9.51 redirects the root's subwindows, composites non-32-bit visuals
  opaque and picks the X display per slot; `glxgears` then mapped as an iosc window and two
  slots got `:0` and `:1`. `xios-session 1.0.82` already depends on `iosc (>= 0.9.50)`. The
  ioscd `LAUNCH` gaps above are still open.

## 2026-10-25 (later): X access for mobile clients
- iosc 0.9.52 (unpublished, device-tested; the binary was tested in its own slot and
  mv'd into place for the ioscd test, then the 0.9.51 bytes restored, not dpkg-installed:
  the iosc postinst re-bootstraps the Metal event broker, which a live KDE depends on). Xwayland
  seeds its host list with `SI:localuser:<its own user>` only and has no cookie, so with iosc
  (and Xwayland) as root every mobile client (all ioscd launches) got "Authorization required".
  The XWM now does what `xhost +si:localuser:mobile` does, right after WM setup and before
  `x11-display` is published: core `ChangeHosts(Insert, ServerInterpreted, "localuser\0mobile")`
  (`xwm_grant_local_user`, core libxcb only). Access control stays on; uid -2 (nobody) is still
  refused. Device: with both Xwayland 24.1.13+ios2 and 23.2.7+ios5 the host list reads
  `localuser:root`, `localuser:mobile`; mobile `glxgears` and `xterm` map as iosc surfaces;
  two iosc instances got distinct displays (`:0`, `:1`). Evidence:
  `x11/artifacts/device-runs/x11-gaps-20261025/` (main checkout).

## Xwayland 24.1.13+ios2 (2026-10-01, branch claude/xwayland-24, unpublished)

**2026-10-25: landing as `xwayland 24.1.14+ios1`** (branch `claude/land-xwayland-24`, rebased on main, unpublished). 24.1.14 is the 2026-10-07 security release. The 0001-0005 series applies to it unchanged, and the backend needed no port: the only `hw/xwayland` glamor change upstream is DRM render-node lookup in `xwayland-glamor-gbm.c`, which our backend replaces. The build also picks up main's `xios_metal_sync` / `XiosMetalEventBroker` fixes, which the 24.1.13 builds predate. `build-xwayland.sh` now fingerprints `xwayland.mk` and those four sources too, so a version bump or a change to them forces a clean Xwayland rebuild instead of reusing `.build_complete`. A local 24.1.13+ios2 ran on device under iosc 0.9.51's rootless XWM (explicit `:N`, `-rootless -wm -displayfd -terminate -extension MIT-SHM`); 24.1.14+ios1 itself still needs a device run.

- Ported the IOSurface/ANGLE glamor backend from 23.2.7 to 24.1.13 (24.1 removed `xwl_egl_backend`). With glamor and no gbm, meson sets `build_iosurface` and `recipes/build_info/xwayland-glamor-iosurface.c` replaces `xwayland-glamor.c` + `-gbm.c`; series `ports/xwayland/patches/0001-0005`. The Metal acquire fence is exported from `xwl_window_handle_pixmap_sync()`.
- Device-verified rootful under the iosc desktop (installed iosc has no rootless XWM, built without `IOSC_BUILD_XWM`): glamor on ANGLE A10, X windows presented via `iosc_iosurface` (iosc logs `imported client IOSurface` from the Xwayland pid), no fence FatalError over a multi-minute soak. Evidence (gitignored): `x11/artifacts/device-runs/xwayland-24-20261001/`.
- 0005 matters: glamor 24.1 checks `glGetError()` after the depth-8 probe `glTexImage2D`; a stale GL_INVALID_OPERATION (0x502, raised inside `glamor_init`, not in our EGL init) dropped the a8 format to software and X11 text rendered as black boxes. Verbose log line: `glamor: dropping stale GL error 0x502 before probing depth 8`.
- es2gears_x11 segfaults in `XGetVisualInfo` on 23.2.7 and 24.1.13 alike (client bug); GL over X is software GLX.

### Open follow-up: one glamor glyph shader does not link on ANGLE-Metal

24.1 no longer forces GLSL 120 on GLES, so glamor uses ES 3.0 programs. The ES 3.0 glyph facet (`glamor_facet_composite_glyphs_es300` in `glamor/glamor_composite_glyphs.c`) always declares `color0`/`color1`, but `glamor_program.c` only binds their locations for the dual-blend alpha mode. ANGLE-Metal fails to link the atlas program once at startup (`Failed to link ... invalid return type 'ANGLE_FragmentOut'`, outputs `_ucolor0/_ucolor1` `__unassigned_output__`); glamor falls back for that program, text still renders correctly, but that path is probably software. Tried and abandoned on device: binding the locations for all ES 3.0 programs (no change), disabling dual blend plus a single-output glyph facet (`glamor_render.c` then fatals on `frag_color`/`color0`), re-forcing `glsl_version = 120` (every program fails "Fragment shader version does not match", glxgears 38 FPS). A proper fix needs the glyph/render facets reworked to declare only the outputs they write. Repro: start Xwayland with `-verbose 3`, run Hitori with `GDK_BACKEND=x11`, grep the log for `Failed to link`.
