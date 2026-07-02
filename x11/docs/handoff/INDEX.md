# Xios / X11-on-iOS — team handoff index

One file per domain. Each is a self-contained charter for an independent agent: ownership, current state (as of 2026-07-01 evening), key files/commits/gotchas, open items, and how to verify on-device. Spin up one agent per file and point it at that file.

## Device
- iPad7,12 / A10 / iOS 17.6.1, rootless jailbreak (/var/jb).
- SSH: `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@MaxsiPad.local`
- Repo: /Users/max/Documents/jailbreak/x11 (this dir).

## The product
"Install one `xios` meta-package → pick your desktop flavor": iosc (lightweight Wayland shell, WORKS today) · GNOME Shell/Mutter · KDE Plasma · native-iPadOS per-window. Chooser = Sileo + the in-app Desktop Session picker (four-finger tap in Xios); three-finger tap switches already-running X/Wayland displays.

## Domains (files here)
1. **xios-app.md** — the Xios iOS app (Metal present + touch/keyboard input + IOSurface adopt). THE active bug area. HIGHEST PRIORITY: verify/finish the display+touch scale fix.
2. **iosc-shell.md** — the iosc lightweight shell (panel/dock/overview/wallpaper) + the tablet-DE redesign vision (awaiting approval).
3. **iosc-compositor.md** — the iosc Wayland compositor (iosc.c) + the wire protocol (input/present/clipboard/etc).
4. **mutter.md** — MetaBackendIOS (Mutter on iOS, = GNOME Shell's compositor).
5. **gnome-session.md** — GNOME session layer + the shell boot (Phase 3 pending).
6. **gtk4-typelibs.md** — on-device GObject-Introspection typelibs (the last GNOME boot gate).
7. **kde-kf6.md** — Qt6 modules (DONE) + KF6/KDE Plasma build (in progress).
8. **native-ipados.md** — the native per-window iPad flavor.
9. **session-launcher.md** — the flavor switcher (CLI + daemon + in-app picker).
10. **polish.md** — smaller tracks: touch-scroll/gestures, clipboard sync, rotation, native-feel (volume/dark/haptics), gsd plugins.

## Current headline status
- **iosc desktop WORKS interactive on-device**: GPU-composited, panel with launchers, GNOME apps launch as windows, auto-keyboard + typing.
- **THE recurring bug (being fixed in xios-app):** the app scaled the desktop with a stale factor → desktop overflowed the right edge AND taps landed offset. One root cause was fixed by resetting zoom on every surface adopt (commit a7da822); the deeper geometry-resync fix is now implemented locally and deployed for verification (see xios-app.md). VERIFY THE PHYSICAL TAP FIRST.
- **Portrait sizing path exists now:** the in-app Desktop Session picker can attach display dimensions to a session request; the updated session daemon applies them to iosc via `IOSC_LOGICAL`. Verified `1080x1440` logical → `2160x2880` framebuffer for full-height portrait. Latest Xios build removes visible debug chrome: three-finger tap switches existing displays, four-finger tap opens the session/dimension picker, pinch app-zooms in/out to fit, lower-screen one-finger swipe opens the keyboard.
- **GNOME Shell is boot-ready**, gated only on gtk4-typelibs finishing the gir scans.
- **KDE**: Qt6 modules done; KF6 build underway.

## Key cross-cutting gotchas (all domains touching the app/device)
- **Deploy Xios.app**: `scp -r` DROPS the exec bit AND the bundle `_CodeSignature`. After scp: `chmod +x Xios.app/Xios`, then re-sign `ldid -e Xios.app/Xios > ents; ldid -S<ents> Xios.app/Xios` (keeps GPU entitlements). `scp -r` into an existing bundle NESTS → `rm -rf` the dest first. `uicache -p` after. Bundle id `com.max.xios`.
- **FrontBoard relaunch throttle**: rapidly killing+relaunching the app trips it (0 procs, empty status, no crash log). `sbreload` clears it. The app needs the screen AWAKE + foreground to launch (nil Metal when backgrounded). A home-screen icon TAP is far more reliable than SSH `uiopen -b`.
- **Zombie surfaces**: iosc keeps compositing dead-client surfaces; restarting a shell client many times stacks stale panels. Kill by PID (pkill-by-name can miss); restart iosc to clear all zombie surfaces.
- **Per-compositor geometry**: iosc's output IOSurface is variable (logical×2, e.g. 3200×2400); Mutter's is HARDCODED 2160×1620. Anything mapping fb↔screen must read the size from `/var/jb/tmp/xios.json`, never a constant.
