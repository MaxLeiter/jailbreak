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
- `ports/dunst/patches`: Darwin `stat` field compatibility, an iOS-safe GLib
  config-path expansion helper instead of `wordexp()`, and no `librt` link.
- `ports/zathura/patches`: skips macOS GtkOSX branches and removes the
  unconditional libmagic dependency in favor of GLib content-type guessing.
- `ports/gnome-text-editor/patches`: replaces unavailable iOS `wordexp()`
  usage with GLib home-directory expansion.
- `ports/gnome-desktop/patches`: gates GIR source references when
  `-Dintrospection=false` so libgnome-desktop-4 can build without the
  introspection variables.
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
- `ports/gjs/patches`: carries the GJS cross-build Meson edits for the
  SpiderMonkey sanity check, GjsPrivate GIR generation, and test subdirs. The
  manual GJS build applies this stack directly, and the draft recipe is wired
  to `DO_PATCH` if that path is revived.
- `ports/mesa-demos/patches`: carries the iOS Wayland EGLUT source port,
  OpenGL include spelling fix, iOS `__sincos`, and the wider es2gears default
  window. The generated `xdg-shell` protocol C/header files stay procedural via
  `mesa-demos-generate-xdg-shell.sh`.
- `ports/mesa/patches`: carries the old TigerVNC/Procursus Mesa source edits
  for Darwin swrast: no Apple DRI platform, the xxf86vm Meson dependency,
  portable GL include spelling, and the disk-cache headers needed by ld64.
- `ports/wayland/patches`: carries the base libwayland Darwin/iOS portability
  patch, including epoll-shim selection, credentials, cloexec, and timerfd
  fallbacks.
- `ports/fcft/patches`: carries the iOS `xlocale.h` include needed for
  locale APIs under the iOS SDK.
- `ports/fuzzel/patches`: carries the Darwin UTF-32/thread-name portability
  edits and skips the `doc/` Meson subdir that otherwise requires `scdoc`.
- `ports/foot/patches`: carries the Darwin UTF-32/thread-name portability
  edits plus the iOS locale, PTY bootstrap, and zero-render-worker runtime fixes.
- `ports/grim/patches`: makes the `librt` Meson lookup optional for iOS,
  where `clock_gettime()` is in libc.
- `ports/basu/patches`: keeps the Meson-level iOS/ld64 edits as a patch stack;
  basu remains documented as a blocked Linux-bound sd-bus port.
- `ports/gtk+3.0/patches`: keeps GTK3's Darwin backend gates from disabling
  the requested X11/Wayland build and drops the unavailable AT-SPI bridge.
- `ports/gtk4/patches`: keeps GTK4's Darwin backend gates from disabling the
  requested Wayland backend.
- `ports/libadwaita/patches`: forces libadwaita's Darwin settings backend onto
  the portal path instead of the unavailable macOS/AppKit implementation.
- `ports/pango/patches`: makes Pango's macOS ApplicationServices backend
  optional so the iOS build stays on fontconfig/freetype/cairo.
- `ports/libepoxy/patches`: enables Apple EGL dispatch for the ANGLE/Mesa
  rootless paths used by GTK4's Wayland renderer.
- `ports/harfbuzz/patches`: marks the CFF1 supplemental-size local as unused
  for the iOS clang build.
- `ports/nghttp2/patches`: enables Darwin's RFC3542 control-message macros
  needed by nghttp2's socket utility code. The Ladybird Wave 3 recipe reuses
  this same stack for its nghttp2 package.
- `ports/curl/patches`: drops curl's runtime library configure probe, which is
  not meaningful in the iOS cross-build environment. The Ladybird Wave 3 recipe
  reuses this same stack for its newer curl pin.
- `ports/exempi/patches`: drops the unshipped sample programs and the
  unavailable `-lrt` link flag for the iOS build.
- `ports/colord/patches`: trims colord to the libcolord client path by making
  daemon-only udev/USB deps optional, skipping generated daemon data, and
  removing GNU ld version-script use.
- `ports/appstream/patches`: keeps AppStream cross-build codegen on the host
  `appstreamcli` instead of a target-built iOS helper.
- `ports/polkit/patches`: builds the polkit agent client library under
  libs-only mode while dropping the setuid helper and unavailable auth-library
  edges.
- `ports/tracker/patches`: replaces Tracker's target-running strftime probe
  with the Darwin year-format modifier used by the iOS cross build.
- `ports/ibus/patches`: lets the disabled-XIM Compose locale check fall through
  while cross-building instead of aborting configure.
- `ports/mutter/patches`: makes remote-desktop-only input-emulation deps
  optional and guards systemd-only X11 policy code when libsystemd is off.
  `ports/mutter/patches-gir` carries the no-native-backend fallback for the
  standalone on-device GIR builder and the no-`/work/x11` cross-build fallback;
  the real MetaBackendIOS integration path deliberately does not apply it.
- `ports/evolution-data-server/patches`: carries the EDS SMIME-off,
  ld64-linker, host-generator, GLib include, and Camel no-NSS/NSPR source
  edits for the calendar/addressbook build.
- `ports/mozjs/patches`: carries the SpiderMonkey 115 iOS target/configure
  support, JS-shell removal, Darwin old-configure cases, iOS stack-size
  alignment, and the wasm signal-handler guard shared by the JIT and non-JIT
  MozJS recipes.
- `ports/mpv/patches`: carries the iOS runtime guard for disabled hardware
  decoding and the Meson Objective-C cross-compiler registration needed by the
  native AudioUnit output path.
- `ports/imv/patches`: makes the `librt` Meson lookup optional, uses the
  portable `st_mtime` stat field, and makes the launcher prefer the verified
  Xwayland fallback on iOS while keeping an opt-in native Wayland path.
- `ports/swayimg/patches`: carries Darwin eventfd/timerfd/stat portability,
  Meson 1.0 option-file compatibility, and libc++ compatibility shims for
  `std::format`, filesystem hashing, and newer C++20 construction patterns.
- `ports/waybar/patches`: trims the initial iOS build surface to clock/custom
  modules by dropping Linux-only service modules and compositor integrations
  from Waybar's source list and factory.
- `ports/slurp/patches`: makes the `librt` Meson lookup optional for iOS.
- `ports/mako/patches`: makes the `librt` Meson lookup optional; mako remains
  blocked by the Linux-bound sd-bus provider path.
- `ports/libsigcplusplus/patches`: keeps the Darwin libtool partial-link target
  flags in the source patch stack while the recipe passes the active
  min-version and architecture values into `configure`.

Remaining non-Qt procedural source edits:

- `pulseaudio-ios-fixes.sh` is intentionally still procedural because it injects
  local Xios module sources after the patch stack has modified the upstream
  module list.
- `build-gtk.sh` and `build-mutter.sh` still edit local build-driver/sysroot
  state (`makefiles/libxcursor.mk`, `makefiles/libxkbcommon.mk`, and staged
  Khronos headers). These are per-volume Procursus integration tweaks, not
  upstream dependency source patches.
- `recipes/ffmpeg.mk`, `recipes/gobject-introspection.mk`, `build-shell.sh`,
  and `build-skia.sh` still rewrite generated build/install/package artifacts
  such as `config.mak`, installed script shebangs, control metadata, and staged
  public headers. Keep those procedural unless the owning build system grows a
  stable pre-configure source seam.
- `recipes-ladybird/libjpeg-turbo.mk` uses upstream `-DWITH_JPEG8=ON` instead
  of patching generated `jconfig.h`, so it intentionally has no patch stack.
- `recipes-ladybird/patches-m0`: common Ladybird M0 engine-tree patches shared
  by headless and app builds. The stack gates macOS sandbox selection, libedit,
  the unused AVIF/JPEG-XL decoder dependency path, and the default M0 helper
  build graph for iOS. It also gates macOS-only source/framework paths while
  extending Darwin-only source guards where iOS has the same ABI behavior, and
  lets the LibJS AsmInterpreter codegen use host-built tools when provided by
  the build driver. The same stack also gates default WebView compositor
  launch/connect calls, adds the `headless-shot` M0 driver, and routes Skia
  font-manager setup through CoreText on iOS. For headless screenshots, it
  CPU-rasters the display list inside WebContent when no Compositor is launched.
- `recipes-ladybird/patches`: app-only Ladybird engine patches applied under
  `LB_APP_BUILD=1`, including Compositor/UI build-graph restoration,
  CPU fallback hooks, IOSurface/Mach transport, input caret updates, and
  ANGLE/GPU compatibility.
- `recipes-ladybird/ladybird-m0-patches.sh` still carries the remaining
  environment-sensitive Ladybird app bring-up cleanup for traces from reused
  trees. The app build driver still fills generated ANGLE trap-stub symbols
  after the first CPU-fallback link because that list is link-output-derived.
- Ladybird wave/app-engine/bundle scripts are likewise out of scope for this
  dependency pass; treat them as a separate browser-engine packaging cleanup.

Deferred deliberately: Qt/KDE/Plasma/layer-shell-qt patch conversion is skipped
while that track is under active development. Do not convert those recipe
`sed`/Python fixups to quilt until the current Qt work settles, because the
generated recipe/table flow needs to own the conversion.
