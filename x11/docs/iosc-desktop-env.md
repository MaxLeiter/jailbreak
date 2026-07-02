# Linux apps as first-class iOS Home Screen apps (iosc desktop env)

Make a Linux/GNOME app that ships a `.desktop` file appear as an **icon on the
iPad Home Screen**. Tapping it launches that app inside an **iosc** Wayland
window and brings the **Xios** display to the front — so it feels like an ordinary
iOS app, but it is a real native Linux process.

This is a standalone feature. It borrows patterns from `bin/install-app.sh`
(build → ldid-sign → scp → `uicache`) and from `wayland/run-kgx.sh` (the client
launch environment), but it depends on **nothing** else in the repo and on no
other tweak (KitchenHub / carplayhost). Everything new lives in
`x11/apps/iosc-desktop/`.

---

## 1. The pieces

```
   Home Screen                       iOS                         Linux side (iosc desktop)
 ┌───────────────┐   tap      ┌───────────────────┐
 │  [Console]    │──────────► │ <appid>.app       │  one thin per-app bundle, but
 │  [Calculator] │            │  IOSCLaunch (stub)│  every bundle ships the SAME
 │  [Files]      │            │  + Info.plist     │  signed IOSCLaunch binary; the
 │   ...   [X11] │            │  + AppIcon*.png   │  launch target is in Info.plist
 └───────────────┘            └─────────┬─────────┘  (IOSCExec / IOSCAppID / IOSCName)
                                        │ LAUNCH\t<app_id>\t<exec>  (AF_UNIX)
                                        ▼
                              ┌───────────────────┐  root LaunchDaemon, OUTSIDE the
                              │ ioscd  (daemon)   │  app sandbox. On each request:
                              │ /var/jb/tmp/      │   1. ensure iosc is running
                              │   ioscd.sock      │   2. uiopen com.max.xios (show)
                              └───┬───────────┬───┘   3. raise existing OR exec new
                  exec client     │           │ uiopen
                  (dbus-run-session│           ▼
                   + wayland env)  │   ┌───────────────┐  Xios.app draws iosc's output
                                   │   │  Xios.app     │  IOSurface as a Metal texture
                                   │   │ (the display) │  (the only thing iOS shows)
                                   │   └───────▲───────┘
                                   ▼           │ output IOSurface (mach port)
                           ┌───────────────────┴───┐
                           │ iosc (Wayland compositor)│  the new app is a wl client;
                           │  GPU-composites clients  │  its window just appears in the
                           │  into the output surface │  Xios display
                           └──────────────────────────┘
```

New components (all in `x11/apps/iosc-desktop/`):

| File | Role |
|---|---|
| `src/IOSCLaunch.m` | the per-app Home Screen launcher stub (UIKit, Obj-C). Reused verbatim in every bundle. |
| `src/ioscd.c` | the root launch daemon. Bridges a sandboxed tap to a root-side app launch. |
| `gen-launchers.sh` | host-side generator: `.desktop` → `.app` bundle(s). |
| `gen-icons.py` | icon pipeline: resolve `Icon=` → the iOS Home Screen PNGs. |
| `build-stub.sh` | compile + ldid-sign `IOSCLaunch` and `ioscd` on the Mac. |
| `launcher-ent.xml`, `ioscd-ent.xml` | entitlements for the stub and the daemon. |
| `com.max.ioscd.plist`, `install-ioscd.sh` | LaunchDaemon + its on-device installer. |

It does **not** modify Xios or iosc to ship the basic experience. One small iosc
addition makes the *second-tap → raise the existing window* case exact; see §7.

---

## 2. Why a daemon (the privilege/sandbox reason)

The obvious design is "the launcher `.app` execs the `Exec` command itself." On
this rootless jailbreak that is fragile:

- A `/var/jb/Applications` app is launched by SpringBoard as **`mobile`, inside
  the iOS app sandbox.** Any process it `fork`/`exec`s **inherits that sandbox.**
- Today nothing in this project launches a Linux app from inside an app — every
  bring-up (`run-iosc.sh`, `run-kgx.sh`) runs as **root over SSH.** There is no
  proven in-app sandbox-escape path here to lean on.

So the launcher does **not** exec anything. It sends a one-line request to
**`ioscd`**, a tiny root `LaunchDaemon` that runs **outside** any app sandbox and
spawns the client exactly the way the working run-scripts already do. This:

- sidesteps sandbox inheritance entirely (the proven-good path stays root-side);
- centralizes lifecycle (start iosc, foreground Xios) and the *raise-vs-launch*
  decision in one place, instead of duplicating it in every launcher;
- keeps each launcher bundle trivial: connect, send, done.

The cost is one resident daemon (a few KB, `KeepAlive`). Worth it for robustness.

---

## 3. Launch mechanism: the two options, and the recommendation

The lead asked to compare two strategies. The bundle itself is **always** per-app
(each Home Screen icon is one `.app` with its own bundle id, label, and icon — a
single bundle id can only show one icon). The real question is how the *launch
target* and the *binary* are wired:

**Option A — one generic launcher binary, target in each bundle's Info.plist.**
Compile `IOSCLaunch` once. Copy that same signed Mach-O into every generated
bundle. Each bundle's `Info.plist` carries `IOSCExec` / `IOSCAppID` / `IOSCName`;
the binary reads its own bundle at runtime (`NSBundle.mainBundle`). N bundles, 1
binary, no per-app compile.

**Option B — a fully generated, standalone, per-app compiled binary.**
Generate and compile a unique binary per `.desktop` (target baked in as constants).

**Recommendation: Option A.** It gives identical UX with far less work: no
`xcrun`/`clang` invocation per app (the generator just copies a prebuilt binary +
writes a plist + renders icons — all of which are fast, dependency-light shell/
Python). One binary to audit and sign. Regenerating a launcher when a `.desktop`
changes is a plist edit, not a recompile. (A per-app URL-scheme variant — one
shared bundle id, route by `xios://run?...` — is rejected: one bundle id = one
Home Screen icon, so it cannot give N separate icons.)

`gen-launchers.sh` implements Option A.

---

## 4. Generating a launcher bundle

### 4.1 Scanning `.desktop` files

Source: `/var/jb/usr/share/applications/*.desktop` (and `~/.local/share/...`).
From the `[Desktop Entry]` group the generator reads:

| `.desktop` key | Use |
|---|---|
| `Name` | `CFBundleDisplayName` (the Home Screen label). |
| `Icon` | resolved to the app icon (see §4.3). |
| `Exec` | the command to run; freedesktop field codes (`%f %F %u %U %i %c %k %d %v %m`) are stripped. |
| `StartupWMClass` | the Wayland `app_id` (for raise-on-retap). Falls back to the `.desktop` basename, which for GNOME apps *is* the app-id, e.g. `org.gnome.Console.desktop` → `org.gnome.Console`. |
| `Type`, `NoDisplay` | filters: only `Type=Application`, skip `NoDisplay=true`. |

### 4.2 The bundle

`/var/jb/Applications/<sanitized-app_id>.app/` containing:

- `IOSCLaunch` — the shared signed binary (copied, then re-`ldid`-signed with
  `launcher-ent.xml` so the entitlements travel with the bundle copy).
- `Info.plist` — built from a static template; the dynamic strings
  (`CFBundleIdentifier`, `CFBundleDisplayName`, `IOSCExec`, `IOSCAppID`,
  `IOSCName`) are set with `PlistBuddy` so `&`/quotes in a `Name` or `Exec` are
  escaped correctly. Bundle id is `com.max.iosc.<sanitized-app_id>` (unique per
  app). `UIDeviceFamily=[2]` (iPad), landscape-only to match Xios, `UILaunchScreen`
  set so the transient splash never looks like a crash.
- The icon PNGs + `CFBundleIcons`/`CFBundleIcons~ipad` referencing them.

No Xcode project, no `xcodebuild`, no `actool`: the bundle is assembled by copying
a binary and writing files, so the generator is light and scriptable.

### 4.3 Icon pipeline (`gen-icons.py`)

1. Resolve `Icon=` (a name, or an absolute path). For a name, search the
   freedesktop dirs (`icons/hicolor/<size>/apps/<name>.{png,svg}`, largest raster
   first; then `pixmaps/`). SVG is rasterised with `rsvg-convert`.
2. Centre the source on a consistent dark, brand-blue-framed square (so
   transparent or odd-aspect Linux icons still look at home next to iOS icons).
3. Emit the iPad sizes referenced by `CFBundleIcons`:
   `AppIcon60x60@2x` (120), `AppIcon76x76@2x[~ipad]` (152),
   `AppIcon83.5x83.5@2x~ipad` (167), plus a 1024 master.
4. If nothing resolves, draw a branded placeholder tile with the app's initial.

Because the icons live on the **device** but the generator runs on the **host**,
`--icons-root` points at a host-readable mirror of `/var/jb/usr/share`. Get one by
`rsync`-ing it from the device, or by extracting the app's own `.deb`
(`dpkg-deb -x app.deb stage` → `--icons-root stage/var/jb/usr/share`). Falls back
to the placeholder when an icon is missing, so generation never blocks.

---

## 5. The launcher stub (`IOSCLaunch`)

A minimal UIKit app. On **every foreground** (`applicationDidBecomeActive` — fires
on first tap and on every re-tap):

1. read `IOSCExec` / `IOSCAppID` from its own `Info.plist`;
2. `connect()` to `/var/jb/tmp/ioscd.sock` and write
   `LAUNCH\t<app_id>\t<exec>\n`;
3. show "Opening <Name>…" (or the error if `ioscd` is unreachable).

It never `exec`s the Linux app and never calls `exit()` (a clean resident process
avoids any FrontBoard relaunch-throttle risk). `ioscd`'s `uiopen com.max.xios`
pulls Xios to the front, which backgrounds the launcher. Doing the work in
`applicationDidBecomeActive` is what makes a **second tap naturally become a
raise** — it just re-sends `LAUNCH`, and the daemon raises the live window.

Entitlements (`launcher-ent.xml`): `amfi.can-allow-non-platform` (AppSync runs
the unsigned app), `no-container` + a `/var/jb/tmp/` path exception (so the
sandbox permits the `connect()` to the daemon socket). That's all it needs.

---

## 6. The daemon (`ioscd`) and lifecycle

`ioscd` listens on `/var/jb/tmp/ioscd.sock` (mode 0666 so `mobile` launchers can
connect). For each `LAUNCH\t<app_id>\t<exec>`:

1. **Ensure iosc is up.** If the compositor pid is dead or `wayland-0` is gone,
   it clears the stale socket and starts `iosc` exactly like `run-iosc.sh`
   (`XDG_RUNTIME_DIR=/var/jb/tmp`, wait for `wayland-0` + `xios.json`, then chown
   the `iosc-ddx.sock` rendezvous to `mobile` so the Xios app can connect). The
   installed `iosc` is already signed with the GPU entitlement set, so the daemon
   just `exec`s it.
2. **Show the display.** `uiopen com.max.xios` foregrounds Xios.app (the same
   call the run-scripts use; `uiopen` is the entitled component, the daemon only
   `exec`s it).
3. **Raise or launch.** If a client we previously spawned for this `app_id` is
   still alive → ask iosc to raise it (§7) and reply `RAISED`. Otherwise `fork`
   and `exec` the client under the iosc environment — the same env `run-kgx.sh`
   proved good:
   `dbus-run-session -- bash -lc "<exec>"` with `WAYLAND_DISPLAY` = absolute
   `/var/jb/tmp/wayland-0`, `GDK_BACKEND=wayland`, `GSK_RENDERER=${IOSC_GSK_RENDERER:-ngl}`
   (GTK4 defaults to the ANGLE/Metal wl_egl_window shim; set `IOSC_GSK_RENDERER=cairo`
   for the old wl_shm fallback), `GSETTINGS_BACKEND=memory`, `GTK_A11Y=none`,
   `HOME=/var/jb/var/root`, and a private 0700 `XDG_RUNTIME_DIR` for the session
   bus. Records `app_id → pid`; reply `LAUNCHED`. A `SIGCHLD` reaper clears the
   entry when the app exits, so a later tap relaunches.

`ioscd` therefore subsumes the core of `run-iosc.sh`/`run-kgx.sh` for the Home
Screen path; those remain as manual dev tools.

---

## 7. Second tap → raise the existing window

`ioscd` already tracks `app_id → pid`, so it knows on a re-tap that the app is
live and should be *raised*, not *duplicated*. iosc stores `xdg_toplevel.set_app_id`
on each toplevel and serves `/var/jb/tmp/iosc-wm.sock`; `ioscd` sends
`raise\t<app_id>\n`, then iosc finds the mapped surface and runs the same
`surface_raise()` + `keyboard_set_focus()` path used by xdg-activation.

This remains best-effort: if the compositor is not running, the socket is absent,
or no mapped surface has that `app_id`, `ioscd` still foregrounds Xios and the
window remains mapped; it simply may not move to the top.
ships without any iosc change; this only sharpens multi-window focus.

Note on app_id matching: GTK reports the application-id as the Wayland `app_id`
(e.g. `org.gnome.Console`), which matches `StartupWMClass` / the `.desktop`
basename the generator stores in `IOSCAppID`. So the keys line up without
per-app tweaking for well-behaved GNOME apps.

---

## 8. Security / footprint notes

- `ioscd.sock` is world-connectable on a single-user device; the only verb is
  `LAUNCH`, which any local process could already do directly. Acceptable; can be
  tightened to a `mobile`-group socket later.
- `ioscd` runs as root but only ever `exec`s fixed binaries (`iosc`, `uiopen`,
  `dbus-run-session`/`bash -lc <exec>`). `<exec>` comes from an installed
  `.desktop` the user chose to make a launcher for — same trust level as running
  it from a shell.
- The launchers are unsigned and rely on AppSync (like every app this repo
  installs via `bin/install-app.sh`).

---

## 9. Building (host-side, no device)

```sh
# 1. compile + sign the shared stub + daemon (Mac: Xcode clang + ldid)
x11/apps/iosc-desktop/build-stub.sh

# 2. generate launcher bundles from .desktop files
#    --icons-root = a host mirror of /var/jb/usr/share (rsync or dpkg-deb -x)
x11/apps/iosc-desktop/gen-launchers.sh \
  --icons-root /path/to/share \
  --out x11/apps/iosc-desktop/out/bundles \
  /path/to/org.gnome.Console.desktop /path/to/org.gnome.Calculator.desktop
```

Bundles land in `out/bundles/<app_id>.app`. `gen-launchers.sh --deploy` will also
scp + `uicache` them (needs `device.env`); that step touches the device, so it is
opt-in and meant for on-device runs only.

---

## 10. Device deploy + test plan (for the lead)

Goal: prove two already-built apps (gnome-console on-device; gnome-calculator deb
in `wayland/out`/`linux-build/out`) appear as Home Screen icons and open in iosc
windows on tap.

**Prereqs on device:** Xios.app installed (`com.max.xios`), the `iosc` deb
installed (gives `/var/jb/usr/local/bin/iosc` signed with GPU entitlements),
`gnome-console` installed, and `gnome-calculator` installed (`dpkg -i` its deb).

1. **Install the daemon** (once):
   ```sh
   x11/apps/iosc-desktop/install-ioscd.sh
   # expect: /var/jb/tmp/ioscd.sock present; ioscd.log shows "listening on …"
   ```
2. **Get icons + .desktop host-side** (the device is the easiest source):
   ```sh
   rsync -a root@ipad:/var/jb/usr/share/icons     /tmp/share/
   rsync -a root@ipad:/var/jb/usr/share/pixmaps   /tmp/share/   2>/dev/null || true
   scp root@ipad:/var/jb/usr/share/applications/org.gnome.Console.desktop    /tmp/apps/
   scp root@ipad:/var/jb/usr/share/applications/org.gnome.Calculator.desktop /tmp/apps/
   ```
3. **Generate + deploy the launchers:**
   ```sh
   x11/apps/iosc-desktop/gen-launchers.sh --icons-root /tmp/share --deploy \
     /tmp/apps/org.gnome.Console.desktop /tmp/apps/org.gnome.Calculator.desktop
   ```
   Two new icons ("Console", "Calculator") should appear on the Home Screen.
4. **Tap "Console".** Expect: brief "Opening Console…" splash → Xios comes to the
   front → a GNOME Console window appears in the iosc desktop with a live shell
   (same result as `run-kgx.sh`, now icon-driven). Check `ioscd.log` for
   `launch app_id=org.gnome.Console …` and `iosc.log` for the mapped toplevel.
5. **Tap "Calculator".** Expect: a second window appears alongside Console (iosc
   stacks multiple toplevels).
6. **Second-tap test.** Go Home, tap "Console" again. Expect: Xios re-foregrounds
   and (with the §7 iosc change) the existing Console window raises; `ioscd.log`
   shows `raise app_id=org.gnome.Console (pid … live)` → `RAISED`. Without the
   iosc change yet, it should still re-show the display with the window present
   (no duplicate process — verify only one `kgx`/`gnome-console` in `ps`).

**Triage hooks:** `ioscd.log` (daemon decisions), `iosc.log` (compositor /
toplevel mapping), `ioscd-client.log` (the spawned app's stdout/stderr),
`xios-status.txt` (app present). If a tap shows the splash but no window: confirm
`ioscd.sock` exists, then check `ioscd-client.log` for the app's own error (a
missing dep or env issue is the app, not the launcher).

---

## 11. Open items / what to route where

- **iosc maintainer:** the `app_id` storage + `iosc-wm.sock` `raise` verb in §7
  (small, isolated; the raise/focus primitives already exist). Optional follow-on:
  a `list` verb so `ioscd` can re-sync its table to live windows after a restart.
- **Possible nicety:** generate one launcher per installed `.desktop` in bulk
  (`gen-launchers.sh --apps-root <dir>`), already supported, to populate the Home
  Screen with the whole installed app set at once.
- **Terminal=true entries:** not handled yet (would need a terminal wrapper);
  GNOME GUI apps don't set it, so it isn't needed for the current targets.
