# gnome-session — GNOME session layer + the Shell boot

## Ownership
Getting GNOME Shell to boot on-device: the session layer (gnome-session, dconf, gsd, stubs), the ordered install, and the packaged launcher. GNOME Shell IS Mutter (see mutter.md) + gjs UI on top.

## Key files
- `x11/linux-build/install-gnome-boot.sh` — the ordered 66-deb install; now does a ONE-PASS external closure fetch (`apt-cache depends --recurse` over the frontier → `apt-get download` the missing → `dpkg -i` with the set). Hard-gated on libsndfile1.
- `x11/packages/xios-session-stubs/var/jb/usr/bin/launch-gnome-session.sh` — the packaged full-session launcher: re-sign gnome-shell, start the session stubs/bridges on one bus, then run `gnome-session --builtin --session=xios`.
- `x11/wayland/run-mutter.sh` — the bare-mutter smoke (first-pixels).
- Stubs: xios-session-stubs deb (login1/polkit/accounts/logind stubs sharing xios-session-identity; libaccountsservice + libgdm client libs). Plan: `x11/docs/gnome-session-plan.md`.

## ★★ FIRST LIGHT ACHIEVED 2026-07-02 ~11:15 PDT ★★
GNOME Shell 46 BOOTS, PAINTS, and RUNS on the iPad (A10, palera1n rootless). Verified: log shows
`GNOME Shell started`, Xios adopts + Metal-presents the output IOSurface (`xios: client attached`),
and input connects (`MetaInputIOS: input client count 0 -> 1 (app connected)`). A synchronous
foreground run survives 90s+ (killed only by our own `timeout`, EXIT=124). The chain of fixes that
got here: rebuild gnome-shell (atk-bridge drop + Rsvg-ectomy + GDM promisify guard) → regenerate 9
stub/partial typelibs from source with introspection (Atk/Atspi/Gck/Gcr/GnomeDesktop/GWeather +
St-14/Shell-14 re-scan + Gdm-1.0) → ship Locations.bin + login-screen schema → **patch (8): volume
ectomy** (the final first-paint blocker — `Gvc.MixerControl` ctor hangs → blocks compositor →
watchdog SIGKILL; skipping it lets the shell paint).

**UPDATE 2026-07-03 04:25 PDT:** PulseAudio/media packaging fixed the old Gvc hang. Installed
`gnome-shell 46.0+ios2` boots with Gvc enabled, `new Gvc.MixerControl()` returns on-device
(`pre-construct` → `post-construct` → `post-open`), and GNOME sees both the `xios` output sink and
`xios_mic` source from the media bridge. Evidence: `artifacts/device-runs/20260703-042507/` and
`artifacts/device-runs/20260703-042830/` (Mutter/GNOME has no wlr-screencopy, so the latter is a
status/log bundle, not a compositor PNG).

**UPDATE 2026-07-03 12:37 PDT:** rebuilt and installed `gnome-shell 46.0+ios3` with patch (8b)
for `QuickSlider` accessibility. Direct `xios-session gnome` verified GNOME reaches `state=up` and
`GNOME Shell started`; the fresh log no longer has the prior
`Failed to setup quick settings: this.slider.get_accessible is not a function` or
`this._output is undefined` volume errors. Gvc still sees the `xios` sink. Evidence:
`artifacts/device-runs/20260703-123833/`.

**UPDATE 2026-07-03 16:18 PDT:** installed `xios-session 1.0.18` and rebuilt/reinstalled
`ioscd` so the daemon `SESSION` path invokes `/var/jb/usr/bin/bash /var/jb/usr/local/bin/xios-session`
instead of direct-execing the shell script from launchd. Root cause of the earlier daemon failure:
ioscd accepted `SESSION gnome` but the child exited 127 with `exec xios-session failed: No such
file or directory` before the script reached its own log. With explicit bash plus the new queued
request supersede guard, daemon `xios-session -d gnome` reached `state=up`, Xios adopted the
`2160x1620` Mutter surface, and `GNOME Shell started` was present. Evidence:
`artifacts/device-runs/20260703-161839/`. Later newer `stop`/`kde-mobile` requests switched the live
device away again; that is normal newest-request-wins behavior, not a GNOME boot failure.

**UPDATE 2026-07-04 00:19 PDT:** installed `xios-session 1.0.20` and rebuilt/reinstalled matching
slot-aware `ioscd` (`/var/jb/usr/local/bin/ioscd` sha256 `8388c38d...`). The audit first exposed a
real mismatch: `xios-session 1.0.19` sent the new slot-capable six-field `SESSION` line while the
device still had the older daemon, so ioscd treated the slot field as bad `dpi` and replied
`ERR session start failed`. After reinstalling ioscd, daemon `xios-session -d gnome` ACKed and
reached `state=up` / `GNOME Shell started` at 00:19:50 with the usual `2160x1620` Mutter surface.
A newer `stop`/`kde` request from a parallel agent replaced it seconds later; that remains
newest-request-wins behavior, not stale app-picker traffic.

**UPDATE 2026-07-04 22:14 PDT:** rebuilt/reinstalled `ioscd` with peer/payload logging for
`SESSION` requests. Daemon `xios-session -d gnome` logged
`ioscd: session request pid=15717 uid=0 gid=0 payload="SESSION gnome     "`, reached
`{"preset":"gnome","state":"up","message":"GNOME Shell started"}` at 22:14:02, and left
`dbus-run-session`, `gnome-shell --wayland --wayland-display wayland-0`, and Xios alive through the
dwell. A later direct `stop` at 22:14:35 did not have an ioscd `SESSION` peer log, so it was outside
the daemon/app-picker path.

**UPDATE 2026-07-04 23:15 PDT:** `xios-session gnome` now resolves the packaged
`launch-gnome-session.sh` instead of a direct Shell smoke path. Installed
`xios-session 1.0.22` + `xios-session-stubs 0.2.3`; direct `xios-session gnome` and daemon
`xios-session -d gnome` both reached `{"preset":"gnome","state":"up","message":"GNOME Shell started"}`
through `gnome-session --builtin --session=xios`. The launcher keeps the proven Shell
signing/env/socket setup, writes a runtime `org.gnome.Shell.desktop` wrapper so `gnome-session`
starts Shell with the requested `--wayland-display`, detaches, and returns for the existing status
poller. Evidence: `artifacts/device-runs/20260704-231534/`; screenshot attempt
`artifacts/device-runs/20260704-231559/` only logged `failed to create display`, expected for the
non-iosc capture path. A later explicit `stop` and KDE launch replaced GNOME; that is
newest-request-wins behavior, not a GNOME launch failure.

**UPDATE 2026-07-06 12:59 PDT:** the legacy direct Shell runner is removed from the shipped
session package and from the live device. Current device has `xios-session 1.0.46` and
`xios-session-stubs 0.2.4`; `/var/jb/libexec/xios-session`, `/var/jb/usr/bin`, and
`/var/jb/usr/local/bin` have no `run-gnome-shell.sh*` files. Daemon validation
(`xios-session -d gnome` through ioscd) reaped a stale KDE `app plasmawindowed` lock, switched
from `kde-desktop` to GNOME, and reached
`{"preset":"gnome","state":"up","message":"GNOME Shell started"}` with Xios presenting the
`2160x1620` Mutter IOSurface and `input-connected mutter(wayland)`. Evidence:
`artifacts/device-runs/20260706-125913/`.

REMAINING (polish, not blockers):
1. **Launch path — full-session preset verified.** Use **`xios-session gnome`** from
   an SSH shell/on-device terminal or **`xios-session -d gnome`** for the ioscd/app-picker path.
   With `xios-session 1.0.46`, `xios-session-stubs 0.2.4`, and `gnome-shell 46.0+ios3`, the daemon path
   reached `state=up` through `gnome-session`. Keep using ioscd's peer/payload log if a later
   requester replaces GNOME. Promoted on-device gir scripts: gir-build-lib-ondevice.sh, gir-build-gdm-ondevice.sh,
   gir-rescan-st-shell-ondevice.sh (for regen if a typelib is ever missing).
2. **Volume slider polish:** the old volume ectomy is removed in the recipe and in installed
   `gnome-shell 46.0+ios3`. Patch (8b) guards the missing QuickSlider a11y handoff while keeping
   the slider/menu/event path. Fresh `+ios3` logs clear the Quick Settings setup failure and the
   follow-on `_output is undefined` volume error. Remaining audio polish is functional UI testing
   of the slider itself plus fixing the harmless Gvc device lookup noise for xios network streams.
3. Nonfatal service polish from the full-session smoke: `dbus-run-session` warns because
   `XDG_RUNTIME_DIR=/var/jb/tmp` is world-writable; IBus warns about missing
   `/var/lib/dbus/machine-id` and `ibus-daemon`; GnomeDesktop looks for `iso-codes` under the build
   root instead of `/var/jb/usr/share/xml/iso-codes`; `org.gnome.Shell.Screencast` still logs missing
   `Gst-1.0.typelib`; CalendarServer, GeoClue, colord, and the polkit auth agent are absent; and
   `meta-barrier` runtime-check warnings remain because pointer barriers are unimplemented in
   MetaBackendIOS. "Error registering session with GDM" is harmless because there is no GDM on iOS.

## Current state — checked 2026-07-06 12:59 PDT
- `gnome-shell 46.0+ios3`, `xios-session 1.0.46`, `xios-session-stubs 0.2.4`, gnome-session,
  gnome-settings-daemon, libmutter-14-0/dev, libgjs0, gobject-introspection, and
  xios-session-stubs are installed (`dpkg-query` = `ii`).
- GTK4 typelibs are present and importable: `Gtk-4.0` imports under gjs.
- The GNOME Shell boot typelib batch is complete on the device. Live gjs import smoke passed for:
  - Mutter/shell core: `Meta-14`, `Clutter-14`, `St-14`, `Shell-14`, `Gvc-1.0`, `Shew-0`
  - Session/panel deps: `AccountsService-1.0`, `Gdm-1.0`, `UPowerGlib-1.0`, `GWeather-4.0`, `Geoclue-2.0`
  - Closure deps: `Gcr-4`, `PolkitAgent-1.0`, `GnomeDesktop-4.0`, `GnomeBG-4.0`, `IBus-1.0`, `Atspi-2.0`, `Atk-1.0`
- `gnome-shell` private dylibs are installed under `/var/jb/usr/lib/gnome-shell/` (`libshell-14.dylib`, `libst-14.dylib`, `libgvc.dylib`, `libshew-0.dylib`). The prior `/var/jb/tmp/gnome-shell.log` failure was dyld not finding `@rpath/libshell-14.dylib`; the packaged launcher includes `/var/jb/usr/lib/gnome-shell` in `DYLD_LIBRARY_PATH`.
- For the on-device Shell GIR build, `ports/gnome-shell/patches` disables the ATK bridge link on iOS. Reason: `libatk-bridge2.0-0 2.52.0` references ATK 2.52 document symbols, while the installed standalone `libatk1.0-0` is 2.38. This avoids the dyld abort during `Shell-14` scanning. Long-term fix is to align ATK/at-spi packaging if AT-SPI bridge support is needed.

## First launch attempt (2026-07-02) + the stale-binary root cause
The early manual Shell launch was run for real. The compositor came up cleanly — `MetaBackendIOS`
allocated the output IOSurface (`2160x1620 id=20`), served `wayland-0`, `MetaInputIOS`
started polling — but the JS shell then died at boot on **two separate dyld/gjs failures**.
Both trace to ONE root cause: **the deployed `gnome-shell` binary is stale relative to the
recipe.** It was built Jul 1 (05:06) from a source tree patched with the old
gnome-shell iOS patch helper, which predates two fixes now in the recipe:
- **Patch (4b) — atk-bridge drop** (commit bb9535a): the deployed binary still hard-links
  `libatk-bridge-2.0.0.dylib` and calls `atk_bridge_adaptor_init` (2 refs), so dyld aborts on
  the missing ATK 2.52 symbols (`_atk_document_get/set_text_selections`, `_atk_object_get_help_text`).
- **Patch (6) — Rsvg-ectomy** (commit 39dc902): the deployed binary's embedded (zlib-compressed)
  JS still `import`s `gi://Rsvg?version=2.0` at boot via `js/misc/dependencies.js`, and no
  `Rsvg-2.0.typelib` exists on device → `Gjs-CRITICAL ... Typelib for namespace 'Rsvg' not found`
  → `Execution of main.js threw exception`.

**Fix = rebuild gnome-shell from the current patched source and redeploy** (single action fixes
both). Rebuild only `gnome-shell-package` on `procursus-vol-shell` (all deps have
`.build_complete`); the driver wipes+re-extracts+re-patches. To verify the new deb: `otool -L`
its `gnome-shell` must show NO `libatk-bridge` link. Note St still renders SVG icons via the
gdk-pixbuf librsvg loader (`librsvg2-common`), NOT the Rsvg typelib, so the ectomy costs nothing
but the dead wacom padOsd path.

Device band-aids applied to the STALE binary during triage (moot after redeploy, harmless):
`gnome-shell`'s `LC_LOAD_DYLIB` for atk-bridge flipped to weak, and the three missing symbols
weak-imported in `libatk-bridge-2.0.0.dylib` via `tools/macho-chained-weaken.py` (chained-fixups
weak-import bit; the classic symtab `N_WEAK_REF` does NOT work on chained-fixups binaries).

**RESOLVED 2026-07-02:** rebuilt `gnome-shell_46.0` from patched source (`procursus-vol-shell`,
`TARGETS=gnome-shell-package`), verified no atk-bridge link + Rsvg-ectomied, installed on device.
Fresh boot now clears BOTH the atk-bridge abort and the Rsvg import. Also fixed a latent
`build-shell.sh` bug: it never staged `build_info/iosc-gl-ent.xml` into
`build_misc/entitlements/`, so a clean-volume gnome-shell/kwin build failed the ldid SIGN step
(`errno=2`); build-shell.sh now copies it (idempotent).

## Next wall (blocker #3, 2026-07-02): Gdm-1.0 typelib missing `_finish` bindings
With (4b)+(6) fixed, the shell boots much further (past dconf/bluetooth/NM/malcontent/switcheroo,
Xios client attaches) and dies in `gdm/util.js:22` at:
`Gio._promisify(Gdm.Client.prototype, 'open_reauthentication_channel', 'open_reauthentication_channel_finish')`
→ `has no method named open_reauthentication_channel_finish`. Root cause: the on-device
**Gdm-1.0.typelib** (scanned Jul 1 22:57) exposes `open_reauthentication_channel` (async) and
`get_user_verifier` but NOT their `_finish` / `_sync` pairs — even though `libgdm.dylib` DOES
export `gdm_client_open_reauthentication_channel_finish/_sync`. So it's a typelib-scan gap, not a
missing ABI. Two fixes: (A) re-scan Gdm-1.0 on device so `_finish`/`_sync` bind (root-cause
correct, no shell rebuild); or (B) source-patch `gdm/util.js` to guard the promisify (GDM
reauth is meaningless on iOS with no real login manager) — needs a shell rebuild.

**DECISION: went with (B)** (Max approved 2026-07-02). Reasons (A) was rejected: the `_finish`
drop is systematic (both `open_reauthentication_channel_finish` and `get_user_verifier_finish`
gone), so a naive re-scan likely reproduces it → g-ir-scanner async-pairing rabbit-hole; and GDM
has no daemon on iOS, so completing the typelib only moves the wall to the next GDM call
(screenShield unlock). (B) is deterministic and consistent with the existing iOS-absent-subsystem
ectomies (EDS/Rsvg/atk-bridge). (A) remains a worthwhile LATER cleanup if real lock-screen auth
is ever wanted.

**(B) IMPLEMENTED** in `ports/gnome-shell/patches`: wraps the four
`Gio._promisify(Gdm.Client/Gdm.UserVerifierProxy …)` calls in `js/gdm/util.js` in an
`_iosPromisify` helper that only promisifies when the `<name>_finish` method exists. Rebuild
gnome-shell + redeploy to pick it up (same pipeline as the 4b/6 rebuild above).
**DONE 2026-07-02:** rebuilt (deb mtime 00:38, GDM-GUARD-PRESENT verified), installed, relaunched.
Boot now clears the GDM wall and reaches `main.js start()` → `LayoutManager`.

## Blocker #4 (2026-07-02): four closure typelibs are empty STUBS
With #1/#2/#3 fixed, the shell reaches `LayoutManager` → `backgroundMenu.js` → `popupMenu.js:95`
and dies: `TypeError: (intermediate value).Role is undefined` — i.e. `Atk.Role` is undefined.
Cause: the on-device **Atk-1.0.typelib is a 200-byte STUB** (empty `<namespace>`; `Atk.Role`,
`Atk.StateType`, `Atk.Object` all undefined). It's not the only one — a size sweep of the Jul-1
scan batch shows FOUR stubs, all `--include`d by Shell-14 so all will bite in turn:
`Atk-1.0` (200 B) · `Gcr-4` (216 B) · `Atspi-2.0` (224 B) · `PolkitAgent-1.0` (224 B); plus
`GcrUi-4` missing. (Real ones for comparison: St-14 44 KB, IBus 322 KB, Gvc 19 KB.) St references
`Atk.Role` pervasively for accessible-role, so Atk canNOT be ectomied — it needs a REAL typelib.

Why the stubs exist: `gir-build-shell-closure-ondevice.sh`'s header-scan route (`scan_one`) is
fundamentally broken for these four. The on-device GI toolchain (clang-ios, sljit_shim, ninja2,
g-ir-scanner/compiler) and all dev headers + p11-kit-1.pc ARE present, but:
- Scanning the umbrella `atk/atk.h` alone → g-ir-scanner links the probe fine, then errors
  `Namespace is empty` (extracts zero symbols from the umbrella).
- Scanning the full `atk/*.h` glob → clang preprocess FAILS: `atk-autocleanups.h: error: "Only
  <atk/atk.h> can be included directly."` (the sub-headers `#error` on direct inclusion).

**Recommended fix (not yet done):** stop header-scanning these four; build each from its source
tarball with `-Dintrospection=enabled` and let its OWN meson/autotools drive g-ir-scanner over
the SOURCES — the exact proven pattern that produced the REAL St-14/Gvc/GTK4/mutter typelibs
(gir-build-gnome-shell-ondevice.sh / the "each lib's own meson build" route, memory
x11-gtk4-typelibs-ondevice). Order by Shell-14's include deps: Atk (also a mutter --include) →
Atspi → Gck → Gcr(+GcrUi) → Polkit → PolkitAgent. This is a distinct workstream from the shell
patches above; it's the long-standing "gir batch incomplete / gtk4-gpu gir pending" prereq.

### Blocker #4 — IN PROGRESS 2026-07-02: source-build introspection route WORKS
The header-scan route is broken (umbrella→empty, all-headers→`#error only <x.h>`); the fix is to
build each lib from source with introspection ON so its own meson drives g-ir-scanner over the
`.c` sources (correct annotations + no header-guard problem). Driver: a generic on-device
`gir-build-lib.sh` (currently in the session scratchpad — PROMOTE to `x11/linux-build/`) that
extracts a source tar under `/var/jb/tmp`, fixes `#!/bin/sh`→`/var/jb/bin/sh` shebangs (this
rootless device has NO /bin/sh), runs `meson setup -Dintrospection=… <flags>`, builds only the
typelib target(s), installs the .gir+.typelib. Per-lib gotchas learned:
- **Atk 2.38** (`-Dintrospection=true -Ddocs=false`) → real 74 KB (was 200 B stub). `Atk.Role`
  now resolves. DONE.
- **Atspi 2.52** (`-Dintrospection=enabled -Dx11=disabled`) → 56 KB. MUST match the installed
  lib's ABI: the recipe built `-Dx11=disabled`, so an x11-ON introspection build's dumper hits
  `_atspi_device_x11_get_type` missing in the installed libatspi. `ONLY_TL=atspi/Atspi-2.0.typelib`
  to skip the bundled-atk target (at-spi2-core 2.52 vendors atk 2.52, whose gir dumper links the
  installed 2.38 libatk → `_atk_live_get_type` missing). DONE.
- **Gcr 4.2.1** (`-Dintrospection=true -Dvapi=false -Dgtk4=false -Dgtk_doc=false -Dssh_agent=false
  -Dsystemd=disabled -Dgpg_path=/var/jb/usr/bin/gpg`) → Gck-2 32 KB + Gcr-4 35 KB. Needs
  build-time `gcrypt.h`+`gpg-error.h` (+.pc) copied from a build-volume sysroot (loose, removed in
  cleanup — no libgcrypt-dev deb exists and it's build-only; runtime libgcrypt is already present),
  and an unversioned `libgcrypt.dylib`→`libgcrypt.20.dylib` symlink for `-lgcrypt`. GcrUi-4 skipped
  (gtk4=false; not boot-critical). DONE.
- **gnome-desktop 44.1** (`-Dintrospection=true -Dbuild_gtk4=true -Dudev=disabled
  -Dlegacy_library=false -Ddesktop_docs=false -Dgtk_doc=false`) → GnomeDesktop-4.0 9.6 KB +
  GnomeBG/GnomeRR. The old 8.5 KB one had DROPPED the `(out)` annotations on
  `get_input_source_from_locale(locale, type OUT, id OUT)` → "3 args required". DONE.
- **libgweather 4.4.2** (`-Dintrospection=true -Denable_vala=false -Dtests=false -Dgtk_doc=false
  -Dsoup2=false -Dc_args=-Dalloca=__builtin_alloca`, PRE_SETUP seds `modules:['gi']`→`[]`,
  `ONLY_TL=libgweather/GWeather-4.0.typelib`) → 17.8 KB. gotchas: build wants PyGObject
  (`import gi`) only for locations-gen (patch it out — typelib doesn't need it); bundled kdtree.c
  needs `alloca` defined. DONE. **Also RUNTIME:** the installed libgweather4 deb DROPPED
  `/var/jb/usr/lib/libgweather-4/Locations.bin` (ships only Locations.xml) → GWeather aborts
  (`assertion failed: (db)`); copied the 643 KB compiled Locations.bin from the build volume. KEEP.
- **St-14 + Shell-14 RE-SCAN** (force-regen in the persisted gnome-shell gir tree at
  /var/jb/tmp/gnome-shell-gir): the Jul-1 scan ran against the STUB Atk, so g-ir-scanner dropped
  every St/Shell method with an `Atk.*` param (`st_widget_add/remove_accessible_state`). Re-scan
  after Atk is real → St-14 45 KB, methods restored. DONE.
- **login-screen schema**: gnome-shell deb dropped `org.gnome.login-screen.gschema.xml` (it ships
  from GDM); copied from the libgdm source tree + recompiled. KEEP.
- **Gdm-1.0 typelib**: NEXT wall — `Gdm.get_session_ids` (used by systemActions multi-session) is
  missing from the 40 KB Gdm-1.0 typelib, but `libgdm.dylib` DOES export `gdm_get_session_ids`. So
  it's the same incomplete-scan issue, NOT a real GDM gap — rebuild the Gdm-1.0 typelib from the
  patched libgdm tree (volume build_work/libgdm, client-only) with introspection.

### PACKAGING FOR USERS (raised by Max 2026-07-02)
**UPDATE 2026-07-06:** the clean-install GNOME boot payload is now package-backed instead of
hand-staged:
1. `xios-gnome-typelibs 0.2.0` ships the regenerated boot typelibs, including GWeather-4.0,
   St-14/Shell-14, and Gdm-1.0.
2. `libgweather-4-0 4.4.2+ios2` ships `/var/jb/usr/lib/libgweather-4/Locations.bin`.
3. `libgdm1 46.0+ios2` ships `org.gnome.login-screen.gschema.xml`.
4. `xios-gnome 0.1.1` depends on the GNOME JS-import runtime closure:
   libgdm, geoclue/geocode, libgweather, and upower, in addition to the session/shell/stub packages.

Remaining packaging polish: keep moving the on-device gir-generation steps into reproducible package
scripts instead of relying on captured device outputs, and add a libgcrypt development symlink package
only if a shipped consumer still needs `-lgcrypt` at build time.
GDM itself is NOT a blocker: libgdm (client-only) exports what the shell calls; it needs a complete
typelib, not a running gdm daemon.

### MILESTONE 2026-07-02 ~01:32: ALL typelib/JS walls cleared — shell reaches the daemon layer
After rebuilding Atk/Atspi/Gck/Gcr/GnomeDesktop(+BG/RR)/GWeather + re-scanning St-14/Shell-14 +
rebuilding **Gdm-1.0** (50 KB, `get_session_ids` now present — via the gated-generate_gir fix now
in `ports/libgdm/patches`), the main gnome-shell process boots with **zero JS/gi errors**. It gets
through Meta backend, Mutter service names (InputMapping/ServiceChannel), IBus, and into session
setup, then exits at the **daemon layer** (NOT a typelib issue):
- `Missing required core component Settings` — the gsd/Settings shell component isn't provided.
- AccountsService: `ActUserManager: waiting for user manager to load before finding user 'root'`
  then the process ends (no JS error → native exit) — our **accounts stub** never signals the user
  manager loaded / returns data the libaccountsservice client can complete on.
- (Separate, non-fatal: the `org.gnome.Shell.Screencast` HELPER process fails on `gi://Gst` not
  found — that's a distinct service, doesn't block the main shell; Gst-1.0 typelib is just absent.)

### UPDATE 2026-07-02: the "daemon layer" death is actually an external SIGKILL at first paint
Deeper diagnosis (foreground run capturing exit code): gnome-shell is NOT crashing at the daemon
layer and NOT exiting on a JS error — it runs ~3.5s (clean through Meta backend, Mutter service
names, IBus, GnomeDesktop, into QuickSettings/`system.js` `SettingsItem`) and is then **SIGKILL'd**
(exit 137, "Killed: 9") right after the `Missing required core component Settings` warning — i.e.
at FIRST PAINT, when the full UI + wallpaper allocate GPU textures. Key evidence:
- Exit 137 = SIGKILL (external), not SIGABRT/SIGSEGV (no crash `.ips` is generated for these runs).
- NOT jetsam: latest `JetsamEvent-*.ips` is from 2024; no per-process-limit event fired.
- NOT an entitlement gap: `ldid -e` on iosc vs gnome-shell is IDENTICAL (same GPU/task_for_pid/
  memory entitlements). iosc (same MetaBackendIOS + ANGLE/Metal) runs fine — it's just far lighter.
- Death is DETERMINISTIC at the same code point across many runs (memory varied), which argues
  against gradual memory pressure and FOR either a per-process resource ceiling hit at the big
  first-paint allocation OR the **iOS GPU-hang watchdog** killing the client when it submits the
  first full-desktop frame (2160x1620, possibly supersampled) through ANGLE/Metal.
- Device is memory-tight (`vm_stat`: ~24 MB free, ~894 MB inactive/reclaimable) but that's ambient.
- The `Missing required core component Settings` warning is a RED HERRING (non-fatal: just means
  `org.gnome.Settings.desktop` isn't installed → the settings button is inert). The AccountsService
  "waiting for user manager to load" lines are the last log lines only because SIGKILL truncates.
NEXT (the real blocker): isolate first-paint resource kill — (a) try a fresh-memory device (reboot)
to rule memory in/out; (b) check whether MetaBackendIOS supersamples (drop to native res to shrink
the GPU workload); (c) instrument the ANGLE/Metal first-frame path for a GPU command that trips the
watchdog. This is a graphics/resource workstream, distinct from the typelibs (all cleared) and the
session daemons. Tooling gotchas on device: no `bc`, `ps aux` col-6 is NOT rss, no `log` binary,
SIGKILL leaves no `.ips` — use `timeout ...; echo EXIT=$? >file` in a foreground run to read the
signal.

### ELIMINATION MATRIX 2026-07-02 (first-paint SIGKILL) — what it is NOT
Exhaustive bisection of the `EXIT=137` kill. It is DETERMINISTIC: dies ~3.5s in, right after
`system.js` builds the QuickSettings SystemItem (PowerToggle→Screenshot→Settings→Lock→Shutdown,
`Missing required core component Settings` is the last flushed line), external SIGKILL, NO crash
`.ips`, NO jetsam, NO `dmesg`. RULED OUT (each with a direct test):
- **NOT memory / jetsam** — `footprint` low; no JetsamEvent since 2024. (footprint hard to read:
  gnome-shell forks/re-execs so `$!` and `ps|grep|head-1` catch a 1.4 MB helper, not the compositor.)
- **NOT the GPU backend** — BARE MUTTER (`/var/jb/usr/bin/mutter --wayland`, same MetaBackendIOS +
  ANGLE/Metal, re-signed with the same ent) SURVIVES 30s (EXIT=124). So the backend/GPU/present path
  is fine; it's the gjs SHELL's richer scene.
- **NOT the JIT / JS execution** — standalone `gjs` running a hot loop JITs (2e9 iters in 6s =
  ~333M/s = JIT speed, baseline `b` frames seen) and SURVIVES (exit 0). JIT works on this device.
- **NOT a codesigning/JIT entitlement** — adding `dynamic-codesigning` to the Shell
  entitlement did NOT change the kill.
- **NOT the session stubs** — dies identically with the accounts stub removed, with ALL stubs
  removed, and with any Xios app actively kept from attaching. The AccountsService/`ActUserManager`
  "waiting for user manager to load" lines are concurrent async noise, not the trigger.
So the SIGKILL is intrinsic to gnome-shell assembling its rich St/Clutter scene (QuickSettings /
panel) — texture uploads (icons via gdk-pixbuf/librsvg→Cogl/ANGLE), offscreen FBOs / blur shaders —
GPU work bare Mutter's empty stage never does. Leading remaining hypothesis: a specific St/Clutter
GPU op (texture upload or offscreen-FBO/blur) faults the A10 GPU via ANGLE/Metal and the OS kills the
client with no report. This needs GPU-level tooling we don't have on-device — next attempts: disable
shell blur/offscreen (find the St/Cogl env or patch), force smaller/simpler textures, or Metal API
validation on the ANGLE path. dynamic-codesigning ent addition is kept (harmless, correct for JIT).

### ★ ROOT CAUSE FOUND 2026-07-02: the QuickSettings VOLUME control (Gvc/PulseAudio) blocks the compositor
`DYLD_PRINT_LIBRARIES` showed the LAST dylibs loaded before every kill are the audio stack —
`libgvc` → `libpulse` → `libpulsecommon` → `libsndfile` → `libFLAC/vorbis/opus/ogg` — pulled in by
the QuickSettings **volume** indicator (`js/ui/status/volume.js` → `Gvc.MixerControl`). Minimal
reproducer nails it: a gjs script doing `new Gvc.MixerControl({name})` **HANGS in the constructor**
(unbuffered `printerr`: "pre-construct" prints, "post-construct" never does — it never returns,
before `open()` is even called). So the mechanism is:
**gnome-shell constructs `Gvc.MixerControl` synchronously on the compositor main thread → it blocks
→ the compositor stops servicing the display → an unresponsive-compositor watchdog SIGKILLs it**
(clean SIGKILL, no crash `.ips`, deterministic, gjs-only, backend-independent — fits ALL prior
evidence). NOT signing (ad-hoc-signed the whole audio stack incl. libgvc — no change), NOT
shm/memfd (disabled via client.conf — no change), NOT the server connection (hangs in the
constructor, before connecting; also hangs with the PA socket up).

Contributing find: the **PulseAudio daemon is broken** — `pulseaudio -nF default.pa` fails to load
most modules (`Failed to open module ... libprotocol-native.dylib` not on the module rpath: the
"pulseaudio rpath latent-bug" in memory x11-audio-on-device). Starting PA with
`DYLD_LIBRARY_PATH=/var/jb/usr/lib/pulseaudio/modules:/var/jb/usr/lib/pulseaudio` DOES bring the
`module-native-protocol-unix` socket up (`/var/jb/tmp/pulse/native`), but stream/device-restore/
suspend-on-idle modules still fail (some are `.so`-named, wrong rpath). Even so, Gvc STILL hangs in
the constructor with the socket up — so a working server is necessary-but-not-sufficient; the hang
is inside `Gvc.MixerControl` construction itself (likely `pa_glib_mainloop`/`pa_context` setup in
`gvc_mixer_control_init` blocking on this iOS/libpulse-17 build). `sample` absent; `spindump` present
but needs entitlements to stackshot (got CS-killed) — didn't capture the native frame.

**FIX PATHS (decision needed):**
- (A) **Patch gnome-shell to not block on Gvc** — the ectomy pattern (like Rsvg/EDS/GDM): in
  `ports/gnome-shell/patches`, make `js/ui/status/volume.js` construct the MixerControl lazily/async
  or skip it (lose the volume slider). Rebuild + redeploy → first light. Fastest, loses audio UI.
- (B) **Fix why `Gvc.MixerControl` construction hangs** — debug libgvc/libpulse-17 on iOS (get a
  stackshot via an entitled spindump, or add prints to gvc_mixer_control_init). Keeps audio. Deeper.
Also fold in: the GNOME launcher should start the PA daemon (with the module DYLD path) before the
shell, and the PA module rpath bug + `.so`/`.dylib` module naming should be fixed in the pulseaudio
package. The whole audio stack was ad-hoc unsigned on device — sign it in packaging.

This is the session-daemon integration layer (accounts/gsd/settings), the same area as the
gnome-session stubs — a DIFFERENT workstream from the typelib walls, now cleared. Next:
make the accounts stub complete enough for ActUserManager to load, and provide the `Settings`
component (gsd-or-shim). Also GOTCHA seen: something reverted the deployed gnome-shell to the
pre-4b binary + reverted the libatk-bridge weak-import band-aid mid-session; had to reinstall the
deb + re-run `tools/macho-chained-weaken.py` on libatk-bridge. Durable fix for the atk-bridge skew
(affects ALL GTK apps, not just the shell): ship atk 2.52 OR bake the 3-symbol weak-import into the
at-spi2-core package — track in packaging.
- Mutter-side readiness is still good: bare Mutter has first pixels, the Xios app can adopt the surface, and the app-side scale/tap mapping is fixed. Current device state during this check was iosc (`/var/jb/tmp/xios.json` advertised `/var/jb/tmp/iosc-ddx.sock`) with stale standalone Mutter processes still alive; clean them before a GNOME attempt.

## Open items
1. **Keep launch validation tied to the full packaged launcher:** run `xios-session gnome` and
   `xios-session -d gnome`, then confirm no later requester superseded it.
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
