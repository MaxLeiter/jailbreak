# Repo fold-in: flavor meta-packages

How the Xios desktop becomes installable from repo.maxleiter.com. There is no
custom chooser or greeter: a user installs one `xios-<flavor>` package, apt
resolves the whole desktop, and Sileo/Zebra hide or block flavors the device
cannot run. This file is the source for what each flavor installs; the user
guide links here instead of repeating it.

Publishing itself follows the procedure in the top-level `AGENTS.md` (build,
stage into `repo/debs`, `bin/publish-staging.sh`, commit `repo/Packages`, then
`bin/publish-repo.sh`, usually with `--only`). Nothing below replaces it.

## The six meta-packages (as published, 2026-10-25)

Controls live in `x11/packages/meta/<pkg>/DEBIAN/control`, rendered from
`x11/packages/templates/<pkg>/DEBIAN/control.in`. `bump-versions.py` changes the
version in both; dependency floors are edited by hand on purpose.
`build-meta.sh` builds all six control-only debs into `x11/linux-build/out/`.
Depiction text comes from `repo/meta/xios-*.json`.

| Package | Version | Depends (top level) | Floor |
|---|---|---|---|
| `xios-runtime` | 0.1.4 | iosc, angle, dbus, xios-desktop-defaults, xios-audio-server, xios-fhs, pulseaudio, pulseaudio-utils | 16.0 |
| `xios-core` | 0.1.13 | xios-runtime, com.max.xios, iosc, iosc-shell, xios-session (>= 1.0.82), xios-launcher-tools (>= 0.1.12) | 16.5 |
| `xios-gnome` | 0.1.12 | xios-core + gnome-shell, libmutter-14-0, gnome-session, gnome-settings-daemon, the GNOME service libs, xios-session-stubs, xios-gnome-typelibs, xios-desktop-theme | 16.5 |
| `xios-kde` | 0.1.21 | xios-core + KWin, Breeze, Plasma Workspace/Desktop/Mobile/Nano, System Settings, KScreen, PowerDevil, kded, qt6-wayland, Breeze icons, and the apps (Konsole, Dolphin, Kate, KWrite, KCalc, Okular, Ark, Gwenview) | 16.5 |
| `xios-x11` | 0.1.12 | xios-core, iosc (>= 0.9.51), xwayland, xauth | 16.5 |
| `xios-native` | 0.1.8 | xios-runtime, xios-launcher-tools (>= 0.1.12), com.max.xiosprefs | 16.5 |

Things the table hides:

- `xios-session` (1.0.82) depends on `xios-session-stubs`, which ships
  `xios-sysintd` (volume, dark mode, brightness bridge) and `xios-setsid`
  (process-group isolation for slots). Before 1.0.82 only `xios-gnome` pulled the
  stubs in, so KDE and X11 sessions ran without them. `xios-launcher-tools`
  0.1.12 also depends on the stubs, because ioscd starts `xios-sysintd` on its
  own bus.
- `ioscd` is not its own package: it ships inside `xios-launcher-tools`.
- Recommends, which Sileo shows but does not install: `xios-runtime` recommends
  `xios-desktop-theme`; `xios-gnome` recommends gnome-console, nautilus,
  gnome-text-editor and gnome-calculator. `xios-x11` recommends nothing; Xvfb and
  TigerVNC are separate installs.
- `xios-runtime` is the shell-independent base. Native mode stops there plus the
  launcher tools and the Settings pane, so it never installs the fullscreen
  display app, iosc-shell or the session launcher.
- `xios-x11` only does something on the iosc desktop: `xios-session`'s iosc preset
  sets `IOSC_XWAYLAND=1` when Xwayland is installed, and iosc 0.9.51 runs it
  rootless under its own XWM. Details in `handoff/iosc-compositor.md`.

### The ioscd gap (GitHub issue #11)

`xios-core` 0.1.6 through 0.1.11 left out `xios-launcher-tools` when
`xios-runtime` was split off, so a clean GNOME, KDE or X11 install had no
`ioscd`, and every desktop pick in the app failed with "ioscd timed out".
`xios-core` 0.1.12 put the dependency back, and every flavor now pins
`xios-core (>= 0.1.13)` so reinstalling a flavor cannot keep the broken core.
`bin/lib/check-repo-solvable.py` fails any package that installs
`com.max.xios` without `xios-launcher-tools`, so this cannot come back silently.

## The display app is a package

`com.max.xios` (Home Screen icon "X11", 0.1.12 published) is built like the
other SwiftUI apps:

```
bin/package-app.sh x11/apps/Xios      # -> repo/debs/com.max.xios_<ver>_iphoneos-arm64.deb
```

The control is `x11/apps/Xios/packaging/control`, and the version comes from
`MARKETING_VERSION` in `project.yml`, so bump that or apt sees no upgrade. The
build needs Xcode, xcodegen, ldid and Docker, plus the staged `x11/apps/Xios/xlib/`
headers and dylibs. `ldid` signs the binary with `entitlements.plist` before
staging, so the GPU and IOSurface entitlements survive into the deb (check with
`ldid -e`). The app is unsigned, so AppSync Unified is a hard runtime
requirement. That is said in the description and depiction rather than as a
dependency, because AppSync lives on another repo.

## How the store does the gating

Three layers, no custom logic:

1. **MinimumOSVersion** in each control. Sileo and Zebra hide or block the
   package on older iOS. `x11/linux-build/tools/stamp-minos.py --apply`
   recomputes it as the effective floor of the dependency closure, so a meta's
   stamp is its flavor floor.
2. **`Depends: firmware (>= X)`** on each meta (the Procursus idiom), so apt and
   dpkg refuse on older iOS even in managers that ignore MinimumOSVersion. This
   floor is written by hand; compare it with the fresh stamp before publishing a
   meta and bump it if the closure drifted.
3. **Rootless by construction.** Every binary bakes in `/var/jb`, so a rootful
   jailbreak cannot install a working set whatever the metadata says. RootHide
   is untested; it hides `/var/jb`, so expect it to need its own build.

### Why the floors are 16.5

`xios-runtime` stays at 16.0. Everything else is 16.5, and none of it is real
16.5 API use. Link lines that omit `-miphoneos-version-min` make ld64 stamp the
build SDK's version as the Mach-O minos, and `stamp-minos.py` then treats that as
the floor. Most recipes still do not pass the flag, so each deb's floor is the SDK
its builder image had. The ones that pull flavors to 16.5 today include
`xios-launcher-tools` (and so `xios-core` and `xios-native`), gjs and libgjs0
(GNOME), libei1 (Mutter, KWin) and xwayland.

Known offenders, for whoever rebuilds them: the bare `$(CC) -dynamiclib` shim
links in `linux-build/recipes/libdrm.mk`, `libei.mk`, `libgtop.mk` and
`gtk+3.0.mk` (the libgtkintl shim), and the meson cross files in `gjs.mk` and
`gobject-introspection.mk`, which have no `c_args`/`c_link_args`. The cleanest
fix is pinning the flag once in the builder image's CC wrapper. In July a
simulation showed that pinning both the 16.5 and 16.2 groups would flatten every
flavor to 16.0. Not urgent, since the floors are correct, just higher than they
need to be. Re-run `stamp-minos.py` after any such rebuild.

## Fresh-install lessons

The dev iPad hides missing pieces because hand-installed files are already
there. These are the classes of bug a clean device found, and where the fix
lives:

- **Files consumers resolve but no package ships.** The angle deb once shipped
  only `libEGL.dylib`/`libGLESv2.dylib`; the `.2.dylib`/`.so` names libmutter and
  cogl load were hand-made on the device. `x11/ports/angle/package-angle-es3.sh`
  ships them now.
- **Depends gaps**, where a binary links a library its package never declared.
  These are patched at stamp time by the `DEPENDS_ADD` table in
  `linux-build/tools/stamp-minos.py`. Recipe owners should move each line into
  the recipe's control at the next rebuild.
- **Unversioned libintl links** (`@rpath/libintl.dylib` instead of
  `libintl.8.dylib`). They resolve only through Procursus `libintl-dev`'s symlink,
  which we must not ship ourselves (dpkg conflict). `recipes/relink-gtkintl.sh`
  now retargets them to `@rpath/libintl.8.dylib` and adds `Depends: libintl8`
  (ladybird-wayland and the stublibs do the same in their own packaging). The old
  `libintl-dev` bridge in `DEPENDS_ADD` is gone.
- **One version per package in `repo/debs`.** `make-repo.py` indexes every deb in
  the directory, so two versions of a package make duplicate stanzas. Replace,
  don't accumulate.

## Meta-specific publish checks

On top of the `AGENTS.md` procedure, when a meta changes:

1. Bump with `x11/packages/meta/bump-versions.py <pkg>=<ver>`, edit any
   dependency floors by hand, then `x11/packages/meta/build-meta.sh`.
2. Stamp last: `python3 x11/linux-build/tools/stamp-minos.py --apply`, then
   compare each meta's stamp with its `firmware (>= X)` floor.
3. A meta never ships before its closure. Ship `xios-runtime` and `xios-core`
   with or before the flavors that need them, and check with
   `bin/lib/check-repo-solvable.py`.
4. After a production publish, `curl --path-as-is https://repo.maxleiter.com/./InRelease`
   should return 200 (plain curl hides the flat-repo `/./` bug), and on a device
   `apt-get install -s xios-x11` should resolve against a clean `apt-get update`.

## Landing page

`make-repo.py` has a "Desktop" section, first in `SECTION_ORDER` and open by
default. The metas and `com.max.xios` carry `Section: Desktop`, so the flavors are
the top block of repo.maxleiter.com with the big library sections collapsed
below.
