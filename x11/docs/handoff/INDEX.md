# Xios / X11-on-iOS — team handoff index

One file per domain. Each is a self-contained charter for an independent agent: ownership, current state, key files/commits/gotchas, open items, and how to verify on-device. Spin up one agent per file and point it at that file; use the per-domain timestamps as the status authority.

## Device
- iPad7,12 / A10 / iOS 17.6.1, rootless jailbreak (/var/jb).
- SSH: `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@MaxsiPad.local`
- Repo: /Users/max/Documents/jailbreak/x11 (this dir).
- Agent harness: prefer `bin/xios-device` for SSH status checks, session
  launch/switch, input injection, screenshots, and evidence collection. See
  `docs/device-testing.md`.

## The product
"Install one `xios` meta-package → pick your desktop flavor": iosc (lightweight Wayland shell, WORKS today) · GNOME Shell/Mutter · KDE Plasma · native-iPadOS per-window. Chooser = Sileo + the in-app Xios panel (three-finger tap, or the status bar button); switching between already-running X/Wayland displays lives under Advanced in that panel.

## Domains (files here)
1. **xios-app.md** — the Xios iOS app (Metal present + touch/keyboard input + IOSurface adopt). Scale/tap/sized-session path is verified; rotation/polish remain.
2. **iosc-shell.md** — the iosc lightweight shell (panel/dock/overview/wallpaper) + the tablet-DE redesign vision.
3. **iosc-compositor.md** — the iosc Wayland compositor (iosc.c) + the wire protocol (input/present/clipboard/native/XWM/etc).
4. **mutter.md** — MetaBackendIOS (Mutter on iOS, = GNOME Shell's compositor).
5. **gnome-session.md** — GNOME session layer + the shell boot. First light achieved; current work is packaging/persistence/polish.
6. **gtk4-typelibs.md** — on-device GObject-Introspection typelibs. The boot-critical scan work is packaged as `xios-gnome-typelibs 0.2.0`; ATK/AT-SPI version alignment remains.
7. **kde-kf6.md** — Qt6 modules + KF6 + KWin first-light package work.
8. **native-ipados.md** — the native per-window iPad flavor. Runtime-coexists with the fullscreen desktop.
9. **session-launcher.md** — the flavor switcher (CLI + daemon + in-app picker).
10. **svg-loader.md** — real `librsvg`/GdkPixbuf SVG loader audit for GTK/GNOME icon themes.
11. **polish.md** — smaller tracks: touch-scroll/gestures, clipboard sync, rotation, native-feel (volume/dark/haptics), gsd plugins.
12. **wayland-apps.md** — the ported desktop app wave (terminal/viewers/media/utilities), why some don't yet map a window in iosc + the fixes (foot PTY, GTK3 wayland backend, mpv EGL shim, hitori schema), the on-device capture/debug tooling, and the app TODO.
13. **wayland-extra-apps.md** — the next requested standalone app wave: swaybg, tofi, waybar, swayimg, yad, nwg-look, Geary/WebKitGTK, Gnumeric, and Transmission.
14. **xfce.md** — the previously stranded XFCE 4.16 recipe chain, its new reproducible build lane, and the gates before it can become a supported session flavor.
15. **loose-ends-audit.md** — repository-wide 2026-07-18 closure ledger: completed host work, immutable package queue, intentional shims, real port blockers, and deferred device proof.
16. **games.md** — SDL2/SDL3 strategy-game wave: OpenTTD, Warzone 2100, Battle for Wesnoth, and 0 A.D.; shared dependencies, packaging, and isolated device proof.
17. **openjdk.md** — full OpenJDK 21 HotSpot JRE/JDK lane, rootless package split, iOS code-cache behavior, and A10 device proof.
18. **amethyst-minecraft.md** — native UIKit/LWJGL graphical Minecraft launcher, rootless/rootful packaging, system OpenJDK integration, and physical GUI proof gate.

## Current headline status
- **OpenJDK 21.0.12 HotSpot is built, packaged, and running on the A10 iPad
  (2026-07-30):** the rootless `openjdk-21-jre-headless` and
  `openjdk-21-jdk-headless` packages provide the complete headless runtime,
  compiler/tool suite, JFR/JVMCI, and C1/C2 rather than a Zero-only VM. Device
  proof covers 30/30 cold starts, tier-4 compilation, ProcessBuilder, ImageIO,
  HTTPS, JFR, `jlink`, interpreted mode, and the optional mirrored code cache.
  Native AWT windows remain a separate XAWT/Wayland peer milestone; see
  **openjdk.md**.
- **Full desktop input is implemented locally (2026-07-19):** both the fullscreen Xios app and
  native per-window host now consume raw Game Controller HID keyboard transitions, preserve
  held keys/chords, map Command to Super, forward Caps/Num lock, support hover plus five mouse
  buttons, and distinguish continuous trackpad scrolling from discrete wheel scrolling. iosc
  also honors pointer lock/confinement and client cursor surfaces; Mutter's iOS backend consumes
  the same stateful key/modifier wire. Release iPhoneOS builds and host keymap tests pass. The iPad
  is offline, so physical Magic Keyboard/mouse/trackpad proof remains the release gate.
- **iosc desktop WORKS interactive on-device**: GPU-composited, panel with launchers, GNOME apps launch as windows, auto-keyboard + typing.
- **The prior stale-scale/tap-offset bug is fixed on the app path:** Xios now re-adopts/re-syncs IOSurface geometry, resets zoom on adopt, and maps input through the current fit transform. Keep checking `/var/jb/tmp/xios-touch.log` when changing present/input code.
- **Portrait/rotation path exists now:** the in-app Desktop Session picker can still launch portrait-sized sessions, and the clean packaged compositor now includes the native-feel OUTPUT resize path. Verified default `1440x1080` logical iosc -> OUTPUT transform 1 -> `1080x1440` logical / `2160x2880` framebuffer on-device with `iosc 0.9.9` and the rebuilt Xios app. Latest Xios build removes visible debug chrome: three-finger tap opens the one Xios panel (desktop, size, apps; displays and diagnostics under Advanced), pinch app-zooms in/out to fit, lower-screen one-finger swipe opens the keyboard.
- **Native iPadOS per-window mode is implemented and runtime-gated, not build-time-gated.** Classic and native can coexist: ioscd accepts explicit `LAUNCH_CLASSIC`/`LAUNCH_NATIVE`; native uses `wayland-native-0`, `iosc-native-input.sock`, and `xios-native.json`.
- **App launching is app-ID-only and unprivileged.** ioscd resolves trusted,
  root-owned desktop entries itself and starts clients/session D-Bus as
  `mobile`; socket clients cannot supply executable text. The package split is
  `xios-runtime` (shell-independent compositor/GPU/D-Bus/audio/FHS bridges),
  `xios-core` (fullscreen Xios app/shell/session), and `xios-native` (runtime +
  launcher tools + Settings, no fullscreen shell).
- **Native-feel bridges are mostly live:** volume/dark-mode helpers, battery/backlight/sysfs, SensorProxy/CoreMotion, haptic broadcast plumbing, and PulseAudio sink+mic source are deployed/validated in pieces. Physical haptic feel, true UIKit pasteboard round trip, real VoiceOver gestures, and GNOME-facing camera portal/GStreamer remain follow-ups; see `polish.md`.
  - Battery is genuinely live as of 2026-07-29 (`kf6-solid 6.3.0+ios2` — KDE reads batteries via Solid, not UPower, and ours shipped no real backend). **Backlight is only half live:** reads work, writes reach the sysfs node and go no further, because `BKSDisplayBrightnessSet` is inert outside SpringBoard. Details in `kde-kf6.md` and `polish.md` #15.
- **GNOME Shell 46 is up on-device with `gnome-shell 46.0+ios3`**: `xios-session gnome` and
  `xios-session -d gnome` now route through the packaged full-session `launch-gnome-session.sh`
  and the latest daemon smoke reached `gnome/up` with `xios-session 1.0.46` +
  `xios-session-stubs 0.2.4`; the old direct Shell runner is no longer shipped or present on-device.
  Gvc/volume no longer blocks first paint, and Quick Settings no longer hits the
  `get_accessible`/`_output` JS errors. Offline candidates `xios-session-stubs 0.2.5`,
  `libgtop-2.0-11 2.41.3+ios2`, and `xios-desktop-stublibs 0.1.1` close the remaining behavioral
  shim gaps but still need device smoke. Later stop/KDE requests can supersede GNOME by design.
- **KDE/KF6 has a clean-built real KWin ANGLE/Metal + IOSurface backend (`kwin +ios5`), QtWayland/ANGLE IOSurface smoke, `xios-session kde`/`kde-desktop` launching the real upstream Plasma Desktop shell, a live KIO `desktop:` worker, real KScreen/System Settings/KCM packages, Breeze/plasma-integration styling, real Milou search, Xios/iOS-backed Plasma Mobile providers, a stable detached KWin/plasmashell launcher path, and a published/smoked first app batch (`ark`, `gwenview`, `kwrite`).** The installed device baseline is still `kwin +ios2`; `+ios5` and `xios-kde 0.1.9` are live in staging, and the next gate is an isolated GPU/effects smoke once the device returns, then System Settings/KScreen and app-launch checks.
- **Wayland app ecosystem is now broad enough for daily smoke testing**:
  wl-clipboard/mpv/foot/imv/slurp/fuzzel/grim/dunst/GTK3 apps and the rootless
  Xwayland XWM work are on local commits and have on-device evidence in classic
  `iosc`. The package repo output is very dirty; coordinate before publishing.
  See **wayland-apps.md** for per-app status, the launch-in-iosc fixes (foot PTY,
  GTK3 wayland backend, mpv EGL shim, hitori schema, fuzzel worker defaults,
  imv native GLES renderer + Xwayland wrapper), and the `bin/iosc-capture*`
  debug tooling. Remaining app-wave work is Max-gated publish/rollout of newer
  local candidates.

## Key cross-cutting gotchas (all domains touching the app/device)
- **Deploy the Xios app**: it is a PACKAGE (`com.max.xios`), pulled in by `xios-core`, so the shipping path is `bin/package-app.sh x11/apps/Xios` → `dpkg -i` the deb. Bump `MARKETING_VERSION` in `x11/apps/Xios/project.yml` first or apt sees no upgrade. The deb keeps perms and the ldid signature (`package-app.sh` signs with `entitlements.plist` before staging) and its postinst runs `uicache -p`, so none of the scp landmines below apply. They still apply to the `bin/install-app.sh` iteration loop: `scp -r` DROPS the exec bit AND the bundle `_CodeSignature`, so `chmod +x Xios.app/Xios` then re-sign `ldid -e Xios.app/Xios > ents; ldid -S<ents> Xios.app/Xios` (keeps GPU entitlements); `scp -r` into an existing bundle NESTS → `rm -rf` the dest first; `uicache -p` after.
- **FrontBoard relaunch throttle**: rapidly killing+relaunching the app trips it (0 procs, empty status, no crash log). `sbreload` clears it. The app needs the screen AWAKE + foreground to launch (nil Metal when backgrounded). A home-screen icon TAP is far more reliable than SSH `uiopen -b`.
- **Zombie surfaces**: fixed since `iosc 0.9.4` by cleaning compositor surfaces on client disconnect; the current host-built/indexed candidate is `iosc 0.9.18` (device smoke deferred). If stale panels reappear, first verify the installed package/hash and inspect `/var/jb/tmp/iosc.log`; restarting iosc still clears any residual state during diagnosis.
- **Per-compositor geometry**: iosc's output IOSurface is variable (logical×scale); the next Mutter `+ios3` build also honors requested startup geometry and replaces its IOSurface on rotation. Anything mapping fb↔screen must still read `/var/jb/tmp/xios.json`, never a fallback constant.
