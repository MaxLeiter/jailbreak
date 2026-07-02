# gnome-session — GNOME session layer + the Shell boot

## Ownership
Getting GNOME Shell to boot on-device: the session layer (gnome-session, dconf, gsd, stubs), the ordered install, and the run scripts. GNOME Shell IS Mutter (see mutter.md) + gjs UI on top.

## Key files
- `x11/linux-build/install-gnome-boot.sh` — the ordered 66-deb install; now does a ONE-PASS external closure fetch (`apt-cache depends --recurse` over the frontier → `apt-get download` the missing → `dpkg -i` with the set). Hard-gated on libsndfile1.
- `x11/wayland/run-gnome-shell.sh` — the boot: re-sign gnome-shell with GPU entitlements, stop the mutter smoke, start the session stubs, `gnome-shell --wayland`.
- `x11/wayland/run-mutter.sh` — the bare-mutter smoke (first-pixels).
- Stubs: xios-session-stubs deb (login1/polkit/accounts/logind stubs sharing xios-session-identity; libaccountsservice + libgdm client libs). Plan: `x11/docs/gnome-session-plan.md`.

## Current state — checked 2026-07-01 23:55 PDT
- gnome-shell + gnome-session + gnome-settings-daemon + libmutter-14-0/dev + libgjs0 + gobject-introspection + xios-session-stubs are installed (`dpkg-query` = `ii`).
- GTK4 typelibs are present and importable: `Gtk-4.0` imports under gjs.
- The GNOME Shell boot typelib batch is complete on the device. Live gjs import smoke passed for:
  - Mutter/shell core: `Meta-14`, `Clutter-14`, `St-14`, `Shell-14`, `Gvc-1.0`, `Shew-0`
  - Session/panel deps: `AccountsService-1.0`, `Gdm-1.0`, `UPowerGlib-1.0`, `GWeather-4.0`, `Geoclue-2.0`
  - Closure deps: `Gcr-4`, `PolkitAgent-1.0`, `GnomeDesktop-4.0`, `GnomeBG-4.0`, `IBus-1.0`, `Atspi-2.0`, `Atk-1.0`
- `gnome-shell` private dylibs are installed under `/var/jb/usr/lib/gnome-shell/` (`libshell-14.dylib`, `libst-14.dylib`, `libgvc.dylib`, `libshew-0.dylib`). The prior `/var/jb/tmp/gnome-shell.log` failure was dyld not finding `@rpath/libshell-14.dylib`; `run-gnome-shell.sh` now adds `/var/jb/usr/lib/gnome-shell` to `DYLD_LIBRARY_PATH`.
- For the on-device Shell GIR build, `gnome-shell-ios-fixes.sh` disables the ATK bridge link on iOS. Reason: `libatk-bridge2.0-0 2.52.0` references ATK 2.52 document symbols, while the installed standalone `libatk1.0-0` is 2.38. This avoids the dyld abort during `Shell-14` scanning. Long-term fix is to align ATK/at-spi packaging if AT-SPI bridge support is needed.
- Mutter-side readiness is still good: bare Mutter has first pixels, the Xios app can adopt the surface, and the app-side scale/tap mapping is fixed. Current device state during this check was iosc (`/var/jb/tmp/xios.json` advertised `/var/jb/tmp/iosc-ddx.sock`) with stale standalone Mutter processes still alive; clean them before a GNOME attempt.

## Open items
1. **Phase 3 = run `run-gnome-shell.sh`** (a full switch OFF iosc — MAX-GATED; coordinate the device).
2. **Success signal — do NOT gate on xios.json** (Mutter writes it before the gjs shell loads = only proves the compositor came up). Two-stage read of `/var/jb/tmp/gnome-shell.log`:
   - COMPOSITOR up: xios.json + "MetaRendererIOS create_view".
   - SHELL PAINTED (the real win): the line **"GNOME Shell started at"** (prints only after the JS UI + stage load).
   - FAILED (report loudly): "Failed to load module" / "Requiring <NS> couldn't be found" / "JS ERROR" / "Execution of main.js threw exception" / "MTLCreateSystemDefaultDevice" nil / process exited.
   - compositor-only: xios.json but neither after ~15s → grab last 40 log lines.
3. Clicks in the shell inherit mutter's input pump and the app-coord fix is deployed, so GNOME may be usable once the shell paints.

## Re-run install (if needed)
```
scp x11/linux-build/install-gnome-boot.sh root@ipad:/var/jb/tmp/boot/
ssh root@ipad 'cd /var/jb/tmp/boot && sh install-gnome-boot.sh && apt-get check'
```
Benign: a libmozjs "More than one copy unpacked" error (the JIT-variant conflict) is expected.
