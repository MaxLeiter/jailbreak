# mutter: MetaBackendIOS (Mutter on iOS, which is GNOME Shell's compositor)

Owns the Mutter 46 backend for iOS: Clutter renders into the Xios output IOSurface through Cogl on
ANGLE/Metal, and the Xios app's input socket feeds Clutter. GNOME Shell links libmutter-14 and runs
this backend, so it is the GNOME flavor's compositor. The session side is in
[gnome-session.md](gnome-session.md); the original design record is
[../mutter-on-iosc.md](../mutter-on-iosc.md).

## Current state

- Published: `libmutter-14-0` / `libmutter-14-dev` **46.0+ios11** (2026-10-01 audit wave).
  `xios-gnome 0.1.12` requires `>= 46.0+ios10`. The thin `mutter` executable used by
  `xios-session mutter` is not shipped by any meta package; `xios-session presets` reports it as
  missing on a normal install.
- Live compositor on device: Shell paints, GNOME apps map as windows, input works. It runs as a
  Xios v2 slot next to other desktops.
- Output IOSurface defaults to 2160x1620 (scale 2), honors `IOSC_LOGICAL=WxH` at startup, and is
  replaced on `XIOS_IN_OUTPUT` rotation/resize (`xios_surface_resize()` runs before the monitor
  reload, so the new view binds the new IOSurface).
- Input (`x11/wayland/meta-input-ios.c`): MOTION, BUTTON, KEY, AXIS (smooth and wheel scroll),
  TOUCH (a real virtual touchscreen), TABLET, OUTPUT and TEXT. `MetaSeatIOS` reports
  `touch-mode = TRUE`, so the Shell picks touch-first behavior even with a keyboard attached.
  Non-ASCII soft-keyboard text is committed through the Shell's input method. Keys carry real
  keycodes and modifiers. When an input client drops, its held buttons, keys, touches and Pencil are
  released.
- The Pencil (TABLET) is mapped onto the pointer: pressure and tilt are dropped. A real tablet tool
  is the open item in [../gnome-touch-ux.md](../gnome-touch-ux.md) Phase 4.
- Clipboard: `meta-clipboard-ios.c` bridges the strict v1 clipboard wire.
- Text-input focus broadcasts TRAITS so the Xios app can raise the iOS keyboard
  (`linux-build/patches/mutter/meta-wayland-text-input-osk-ios.patch`).

## Key files

- `x11/wayland/meta-backend-ios.c`, `meta-renderer-ios.c`, `meta-onscreen-ios.c`,
  `meta-stage-ios.c`, `meta-monitor-manager-ios.c`, `meta-seat-ios.c`,
  `meta-virtual-input-device-ios.c`, `meta-input-ios.c`, `meta-wayland-iosurface.c`,
  `meta-clipboard-ios.c`: the backend.
- `x11/linux-build/patches/mutter/`: the integration patches (`meson-ios-backend.patch`,
  `meta-context-main-ios-backend.patch`, `meta-wayland-buffer-iosurface.patch`, ...).
  `meta-wayland-pointer-ios-debug.patch` is an opt-in diagnostic, not in the default stack.
- `x11/linux-build/recipes/mutter.mk`, `x11/linux-build/build-mutter.sh`; compile check
  `x11/linux-build/build-backend-check.sh`.
- Smoke without the Shell: `x11/wayland/run-mutter.sh` (or `xios-session mutter` if you install the
  `mutter` binary yourself).
- Probes: `x11/wayland/iosc-input-test.c` (`--mutter`, `--socket PATH`),
  `x11/wayland/mutter-pointer-test.c`.

## How rendering works (route A)

The output IOSurface is the default framebuffer (FBO 0) of a CoglOnscreen whose EGLSurface is an
ANGLE IOSurface pbuffer. ANGLE-Metal cannot render to an IOSurface-backed EGLImage
(`eglCreateImageKHR(GL_TEXTURE_2D)` fails `0x3000`) and the Mutter cogl fork dropped the
foreign-texture wrap, so there is no offscreen. Client IOSurface buffers are aliased into Cogl
textures the same way (pbuffer plus `eglBindTexImage`). Present is a brokered shared-event signal
plus a fenced dirty notification; nothing waits on the CPU. The display, context and pbuffer share
one EGLConfig (`xios_egl_config()`), or `eglMakeCurrent` fails with `EGL_BAD_MATCH`.

## Landmines

- **The first xdg-shell buffer must update window visibility.** Without
  `meta_window_update_visibility()` before `first_buffer_attached` is set, the window actor stays
  unmapped and unpickable: clicks reach the stage but never the client
  (`meta-wayland-xdg-first-buffer-showing.patch`).
- **X11 cannot be compiled out of Mutter 46.** `have_x11` is hardcoded and `core/frame.c` /
  `core/keybindings.c` use X11 unconditionally. The package weak-links the X11/xcb closure
  (`x11/linux-build/tools/macho-weaken.py`, run by `mutter.mk`). On chained-fixups binaries that is a two-stage
  edit: flip `LC_LOAD_DYLIB` to weak AND set `weak_import` on every chained-fixups import from those
  libs, or dyld fails at symbol bind instead of library load. Weak-linking only helps when the
  library is absent; a present library still loads and processes its own strong load commands.
  `x11/linux-build/tools/weaken-deb.sh` repacks any closure deb the same way.
- **Cogl dlopens Linux sonames** (`libGLESv2.so.2`, `libEGL.so.1`). The `angle` package ships those
  links now and the GNOME launcher checks for them.
- **GSettings schemas must be in the deb.** An early package dropped `share/`, and Mutter aborted on
  `org.gnome.mutter` not installed. `mutter-package` copies `share/` and the postinst compiles
  schemas.
- **`libwayland-server0` is a virtual name.** `libwayland0` provides it. Installing libmutter before
  libwayland0 with plain `dpkg -i` leaves it unconfigured, and `apt --fix-broken` may then remove
  libmutter. Install through apt or keep the order.
- **The pid you launched is not always the compositor.** Under GNOME it is the
  `gnome-shell --wayland` child of `xios-gnome-session-client`.
- **Map coordinates from the live geometry.** Anything converting framebuffer to screen must read
  the advertised `xios.json` (or `xios-<slot>.json`), never the 2160x1620 default.

## Debugging recipes

- App-bypass input: `iosc-input-test --mutter -c 1080 810` and look for
  `MetaInputIOS: motion out(X,Y)/WxH -> stage(x,y) in WxH` in `/var/jb/tmp/mutter.log`; W x H should
  match the live `xios.json`.
- Client dispatch: run `mutter-pointer-test` under the compositor's `WAYLAND_DISPLAY`, inject a
  click, expect `ENTER/MOTION/BUTTON` and `/var/jb/tmp/mutter-pointer-hit`.
- Ask before injecting into a session Max is using.

## History (short)

- 2026-06-30: Mutter 46 cross-built; Cogl-on-ANGLE smoke (`iosc-cogl-smoke.c`) passed on the A10
  the next day; backend pieces written against the real 46.0 tree.
- 2026-07-01: first pixels, input transport proven, the xdg first-buffer fix.
- 2026-07-02: GNOME Shell first light on this backend.
- 2026-07-18 to 07-29: touch, tablet, output resize, `touch-mode = TRUE` (+ios7), strict v1
  clipboard.
- 2026-10-01: input fixes from the audit (+ios11).
