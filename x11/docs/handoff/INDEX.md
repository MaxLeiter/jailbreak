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
"Install one `xios` meta-package → pick your desktop flavor": iosc (lightweight Wayland shell, WORKS today) · GNOME Shell/Mutter · KDE Plasma · native-iPadOS per-window. Chooser = Sileo + the in-app Desktop Session picker (four-finger tap in Xios); three-finger tap switches already-running X/Wayland displays.

## Domains (files here)
1. **xios-app.md** — the Xios iOS app (Metal present + touch/keyboard input + IOSurface adopt). Scale/tap/sized-session path is verified; rotation/polish remain.
2. **iosc-shell.md** — the iosc lightweight shell (panel/dock/overview/wallpaper) + the tablet-DE redesign vision.
3. **iosc-compositor.md** — the iosc Wayland compositor (iosc.c) + the wire protocol (input/present/clipboard/native/XWM/etc).
4. **mutter.md** — MetaBackendIOS (Mutter on iOS, = GNOME Shell's compositor).
5. **gnome-session.md** — GNOME session layer + the shell boot. First light achieved; current work is packaging/persistence/polish.
6. **gtk4-typelibs.md** — on-device GObject-Introspection typelibs. The boot-critical scan work is no longer the main GNOME gate; packaging the regenerated typelibs remains.
7. **kde-kf6.md** — Qt6 modules + KF6 + KWin first-light package work.
8. **native-ipados.md** — the native per-window iPad flavor. Runtime-coexists with classic Xios.
9. **session-launcher.md** — the flavor switcher (CLI + daemon + in-app picker).
10. **svg-loader.md** — real `librsvg`/GdkPixbuf SVG loader audit for GTK/GNOME icon themes.
11. **polish.md** — smaller tracks: touch-scroll/gestures, clipboard sync, rotation, native-feel (volume/dark/haptics), gsd plugins.
12. **wayland-apps.md** — the ported desktop app wave (terminal/viewers/media/utilities), why some don't yet map a window in iosc + the fixes (foot PTY, GTK3 wayland backend, mpv EGL shim, hitori schema), the on-device capture/debug tooling, and the app TODO.

## Current headline status
- **iosc desktop WORKS interactive on-device**: GPU-composited, panel with launchers, GNOME apps launch as windows, auto-keyboard + typing.
- **The prior stale-scale/tap-offset bug is fixed on the app path:** Xios now re-adopts/re-syncs IOSurface geometry, resets zoom on adopt, and maps input through the current fit transform. Keep checking `/var/jb/tmp/xios-touch.log` when changing present/input code.
- **Portrait sizing path exists now:** the in-app Desktop Session picker can attach display dimensions to a session request; the updated session daemon applies them to iosc via `IOSC_LOGICAL`. Verified `1080x1440` logical → `2160x2880` framebuffer for full-height portrait. Latest Xios build removes visible debug chrome: three-finger tap switches existing displays, four-finger tap opens the session/dimension picker, pinch app-zooms in/out to fit, lower-screen one-finger swipe opens the keyboard.
- **Native iPadOS per-window mode is implemented and runtime-gated, not build-time-gated.** Classic and native can coexist: ioscd accepts explicit `LAUNCH_CLASSIC`/`LAUNCH_NATIVE`; native uses `wayland-native-0`, `iosc-native-input.sock`, and `xios-native.json`.
- **GNOME Shell 46 is up on-device with `gnome-shell 46.0+ios3`**: direct
  `xios-session gnome` launches and keeps the shell running, Gvc/volume no longer blocks first
  paint, and Quick Settings no longer hits the `get_accessible`/`_output` JS errors. The daemon/app
  picker path still needs session-concurrency cleanup; use the direct CLI for GNOME validation.
- **KDE/KF6 has KWin first-light, QtWayland/ANGLE IOSurface smoke, a working `xios-session kde` first-light shell, real upstream Plasma Desktop reaching a live KIO `desktop:` worker, a stable detached KWin/plasmashell launcher path, and a published/smoked first app batch (`ark`, `gwenview`, `kwrite`).** Next gate is installing/retesting the newest Desktop layout packages after device reachability returns, then replacing remaining Mobile/Nano first-light shims with real service bridges.
- **Wayland app ecosystem is growing quickly**: wl-clipboard/mpv/foot/imv/slurp/fuzzel/grim and the rootless Xwayland XWM work are now on local commits. The package repo output is very dirty; coordinate before publishing. See **wayland-apps.md** for per-app status, the launch-in-iosc fixes (foot PTY, GTK3 wayland backend, mpv EGL shim, hitori schema — several verified only in code, pending device), and the `bin/iosc-capture*` debug tooling. grim screenshots WORK on device (classic mode); foot is root-caused (PTY + C locale).

## Key cross-cutting gotchas (all domains touching the app/device)
- **Deploy Xios.app**: `scp -r` DROPS the exec bit AND the bundle `_CodeSignature`. After scp: `chmod +x Xios.app/Xios`, then re-sign `ldid -e Xios.app/Xios > ents; ldid -S<ents> Xios.app/Xios` (keeps GPU entitlements). `scp -r` into an existing bundle NESTS → `rm -rf` the dest first. `uicache -p` after. Bundle id `com.max.xios`.
- **FrontBoard relaunch throttle**: rapidly killing+relaunching the app trips it (0 procs, empty status, no crash log). `sbreload` clears it. The app needs the screen AWAKE + foreground to launch (nil Metal when backgrounded). A home-screen icon TAP is far more reliable than SSH `uiopen -b`.
- **Zombie surfaces**: fixed in `iosc 0.9.4` by cleaning compositor surfaces on client disconnect. If stale panels reappear, first verify the installed package/hash and inspect `/var/jb/tmp/iosc.log`; restarting iosc still clears any residual state during diagnosis.
- **Per-compositor geometry**: iosc's output IOSurface is variable (logical×2, e.g. 3200×2400); Mutter's is HARDCODED 2160×1620. Anything mapping fb↔screen must read the size from `/var/jb/tmp/xios.json`, never a constant.
