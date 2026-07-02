# gnome-session — GNOME session layer + the Shell boot

## Ownership
Getting GNOME Shell to boot on-device: the session layer (gnome-session, dconf, gsd, stubs), the ordered install, and the run scripts. GNOME Shell IS Mutter (see mutter.md) + gjs UI on top.

## Key files
- `x11/linux-build/install-gnome-boot.sh` — the ordered 66-deb install; now does a ONE-PASS external closure fetch (`apt-cache depends --recurse` over the frontier → `apt-get download` the missing → `dpkg -i` with the set). Hard-gated on libsndfile1.
- `x11/wayland/run-gnome-shell.sh` — the boot: re-sign gnome-shell with GPU entitlements, stop the mutter smoke, start the session stubs, `gnome-shell --wayland`.
- `x11/wayland/run-mutter.sh` — the bare-mutter smoke (first-pixels).
- Stubs: xios-session-stubs deb (login1/polkit/accounts/logind stubs sharing xios-session-identity; libaccountsservice + libgdm client libs). Plan: `x11/docs/gnome-session-plan.md`.

## Current state — Phase 1 DONE
- gnome-shell + gnome-session + gnome-settings-daemon + libpulse0 + libsndfile1 all installed (`dpkg -l` = ii). The audio-closure dependency slog is finished.
- Both boot gates CLEARED (confirmed with mutter owner):
  1. `out/libmutter-14-0` = build10 (newest, all fixes); installs safely (upgrade/match, never downgrade); gnome-shell links it + inherits the working MetaBackendIOS + input pump.
  2. `gnome-shell --wayland` selects MetaBackendIOS via the compositor-TYPE branch (no --nested, no --display-server needed). run-gnome-shell.sh mirrors run-mutter.sh's env — correct as-is.
- No script changes needed from the gates.

## Open items
1. **Phase 2 (gtk4-typelibs.md) is the ONLY remaining gate** — the on-device gir typelibs (mutter/gnome-shell/etc namespaces). Once those are scanned+installed, proceed.
2. **Phase 3 = run `run-gnome-shell.sh`** (a full switch OFF iosc — MAX-GATED; coordinate the device). 
3. **Success signal — do NOT gate on xios.json** (Mutter writes it before the gjs shell loads = only proves the compositor came up). Two-stage read of `/var/jb/tmp/gnome-shell.log`:
   - COMPOSITOR up: xios.json + "MetaRendererIOS create_view".
   - SHELL PAINTED (the real win): the line **"GNOME Shell started at"** (prints only after the JS UI + stage load).
   - FAILED (report loudly): "Failed to load module" / "Requiring <NS> couldn't be found" / "JS ERROR" / "Execution of main.js threw exception" / "MTLCreateSystemDefaultDevice" nil / process exited.
   - compositor-only: xios.json but neither after ~15s → grab last 40 log lines.
4. Clicks in the shell inherit mutter's input pump → will work once the app-coord fix (xios-app a7da822) is deployed. So GNOME may be usable, not just viewable.

## Re-run install (if needed)
```
scp x11/linux-build/install-gnome-boot.sh root@ipad:/var/jb/tmp/boot/
ssh root@ipad 'cd /var/jb/tmp/boot && sh install-gnome-boot.sh && apt-get check'
```
Benign: a libmozjs "More than one copy unpacked" error (the JIT-variant conflict) is expected.
