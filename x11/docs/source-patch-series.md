# Source Patch Series Notes

Dependency source patches should live as quilt-style stacks under
`ports/<pkg>/patches/series`, then be staged into Procursus `build_patch/<pkg>`
by `linux-build/recipes/stage-port-patches.sh` and applied from the recipe with
`$(call DO_PATCH,<pkg>,<pkg>,-p1)`.

Current converted non-Qt stacks:

- `ports/xwayland/patches`: rootless shell path and IOSurface glamor backend
  hooks. The backend `.c` and protocol XML remain local build inputs in
  `linux-build/recipes/build_info/`.
- `ports/pulseaudio/patches`: daemon source-port edits for the Xios sink/source
  module entries, no-evdev, no armv7 NEON, and `_NSGetExecutablePath()`.
  `linux-build/recipes/pulseaudio-ios-fixes.sh` now only injects local module
  sources and verifies the patch series was applied.
- `ports/dunst/patches`: Darwin `stat` field compatibility and an iOS-safe
  GLib config-path expansion helper instead of `wordexp()`.
- `ports/zathura/patches`: skips macOS GtkOSX branches and removes the
  unconditional libmagic dependency in favor of GLib content-type guessing.
- `ports/gnome-text-editor/patches`: replaces unavailable iOS `wordexp()`
  usage with GLib home-directory expansion.
- `ports/nautilus/patches`: lowers the GLib floor to the stack's 2.78 baseline,
  adds Darwin `xlocale.h`, and rewrites GLib 2.80-only call sites.
- `ports/gnome-session/patches`: restores the non-systemd session manager path
  from the existing FreeBSD-derived patch set.
- `ports/upower/patches`: builds only the `libupower-glib` client library for
  shell boot imports, leaving daemon work for the future UPower service path.
- `ports/accountsservice/patches`: builds only the libaccountsservice client
  library, drops the daemon/test/policy paths, and carries the single-session
  sd-login shim that used to be staged from `recipes/`.
- `ports/libgdm/patches`: builds only the libgdm client library, replaces the
  daemon-heavy top-level Meson file, and carries the single-session sd-login
  shim plus sd-daemon header stub.
- `ports/gnome-settings-daemon/patches`: trims the daemon to the minimal iOS
  plugin set, makes plugin-only heavy deps optional, drops the malformed Darwin
  bundle loader flag, and carries the no-op canberra header for the dormant
  power-plugin groundwork.
- `ports/gnome-control-center/patches`: trims Settings panels/dependencies that
  are unavailable on iOS. `ports/gnome-control-center/patches-bluetooth` is
  staged only when `GCC_WITH_BLUETOOTH=1`.
- `ports/gnome-shell/patches`: default Shell source port with EDS/calendar
  patched out, on-device GIR gates, device `gjs` service paths, Rsvg removal,
  atk-bridge disabled, and the iOS GDM promisify guard. `patches-eds` carries
  the same iOS port while keeping EDS/calendar enabled, and is staged only when
  `WITH_EDS=1`.
- `ports/mesa-demos/patches`: carries the iOS Wayland EGLUT source port,
  OpenGL include spelling fix, iOS `__sincos`, and the wider es2gears default
  window. The generated `xdg-shell` protocol C/header files stay procedural via
  `mesa-demos-generate-xdg-shell.sh`.

Remaining non-Qt patcher-shaped scripts:

- `pulseaudio-ios-fixes.sh` is intentionally still procedural because it injects
  local Xios module sources after the patch stack has modified the upstream
  module list.
- `recipes-ladybird/ladybird-m0-patches.sh` is not a dependency recipe in this
  pass; it is a large engine bring-up patch script and should be converted as a
  separate Ladybird-specific cleanup.

Deferred deliberately: Qt/KDE/Plasma/layer-shell-qt patch conversion is skipped
while that track is under active development. Do not convert those recipe
`sed`/Python fixups to quilt until the current Qt work settles, because the
generated recipe/table flow needs to own the conversion.
