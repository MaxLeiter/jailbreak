# Xios strategy-game ports

Updated: 2026-08-03

## Scope

This lane adds four full desktop strategy/simulation games to Xios:

1. Warzone 2100 4.7.0 (SDL3) -- builds, runs on device
2. Battle for Wesnoth 1.18.5 (SDL2) -- builds, device proof open
3. OpenTTD 15.3 (SDL2) -- builds, playable on device
4. 0 A.D. 27.1 -- DROPPED 2026-08-03, blocked on broken mozjs packaging

They are normal Wayland clients. UIKit touch, hardware keyboard, pointer,
scrolling, PulseAudio, and IOSurface presentation remain owned by the existing
Xios app, iosc, SDL, and audio layers.

## Current status

### Shared SDL foundation

- **SDL2 is VENDORED as `xios-sdl2`, not shipped as `libsdl2-2.0-0`
  (2026-08-02).** Built Wayland-only, it exports 836 symbols but none of
  `_SDL_UIKitRunApp` or
  `_SDL_OnApplicationDidChangeStatusBarOrientation`, both of which Procursus's
  2.0.14 exports -- and `libsdl2-2.0-0` has Procursus reverse-dependencies
  (`ffmpeg`, `libavdevice59`, and `powder`, a UIKit SDL app). Publishing under
  that name would replace theirs repo-wide, the shape of the openssl incident.
  It installs to `/var/jb/usr/lib/xios-sdl2` and the game wrappers reach it
  through `DYLD_LIBRARY_PATH`; nothing else can resolve to it.
  Proven by removing `libsdl2-2.0-0` from the iPad entirely and watching
  OpenTTD still reach its menu: `game-openttd-vendored-sdl2/compositor.png`.
  Do not re-add a `libsdl2-2.0-0` waiver; see `bin/lib/shadow-waivers.json`.
- `libsdl3-0 3.2.30+ios2` needs no such treatment -- Procursus ships no SDL3.
- `libsdl3-0 3.2.30+ios2` and `xios-sdl2 2.32.10+ios3` are installed on the
  physical iPad.
- SDL3 reached iosc/Wayland and ANGLE Metal with touch input:
  `api=SDL3 driver=wayland renderer=ANGLE (Apple, ANGLE Metal Renderer:
  Apple A10 GPU) version=OpenGL ES 3.0 touch=3`.
- SDL2 reached the same path:
  `api=SDL2 driver=wayland renderer=ANGLE (Apple, ANGLE Metal Renderer:
  Apple A10 GPU) version=OpenGL ES 3.0 touch=2`.
- Host evidence:
  `game-sdl3-proof-2/compositor.png` and
  `game-sdl2-proof/compositor.png`.

### OpenTTD

- `openttd 15.3+ios1` now cross-builds, links, installs, packages, host-DER
  signs, and installs on the physical iPad.
- The authoritative compatibility series applies in order to a pristine
  official 15.3 source tree with no rejects. It covers the Unix-SDL-on-Darwin
  target, Clang 14 aggregate/template compatibility, the Xios Unix locale and
  desktop-media paths, and `SDL_SetMainReady()` for OpenTTD's non-`SDL_main`
  iOS entry point.
- **Playable on device (2026-08-02).** With `openttd-opengfx` installed the game
  goes straight to its real main menu -- title logo, animated demo world, and
  the full New Game / Play Scenario / Multiplayer / Game Options list. Evidence:
  `game-openttd-opengfx-proof/compositor.png`.
- Menu interaction is proven too: an injected click on the first-run survey
  dialog's "No" dismissed it, and the demo world had advanced between captures,
  so the frame is live rather than a stale surface. Evidence:
  `game-openttd-menu-interaction/compositor.png`. The input socket that refused
  the 2026-07-30 tap works after a clean `session stop` + `session iosc` on the
  slot; a stale slot is what refuses input.
- The earlier bootstrap-only capture (`game-openttd-20260730-1108`) is kept as
  the record of the pre-OpenGFX state.
- The final package must still be host-DER re-signed after every repack:

  ```bash
  python3 linux-build/resign-graphics-packages.py linux-build/out \
    --gpu-ent linux-build/build_info/iosc-gpu-client-ent.xml \
    --gl-ent linux-build/build_info/iosc-gl-ent.xml \
    --only openttd --verbose
  ```

### Warzone 2100

- **Builds and runs on device (2026-08-02).** `4.7.0+ios2` cross-builds,
  packages, host-DER signs, installs, and reaches its full 3D main menu on
  hardware GLES: `OpenGL Renderer: ANGLE (Apple, ANGLE Metal Renderer: Apple
  A10 GPU)`, zero-copy IOSurface, cross-process GPU fence, instanced rendering.
  Evidence: `game-warzone2100-proof/compositor.png`.
- The patch disables the macOS bundle/AppKit path while retaining the Darwin
  ABI and selects the Unix SDL3/GLES path.
- `+ios2` fixes a packaging bug that made `+ios1` unusable as installed:
  `warzone2100.real` lives in `libexec/games`, so the data search it derives
  from its own location never reaches `share/warzone2100` and the game aborted
  with "Could not find game data" despite the 358 MB of data being installed
  correctly. The wrapper now passes `--datadir` (override: `WZ2100_DATADIR`).
- Needed `libvorbisfile3`, which came from **Procursus** -- do not install the
  local `+ios1` rebuild, see the shadow note below.
- **`+ios2` verified on device 2026-08-06**: launches from a bare `warzone2100`
  with no manual flag, reaches its main menu on ANGLE Metal. Evidence:
  `game-warzone2100-ios2-proof/compositor.png`.
- **RE-SIGN AFTER EVERY REBUILD, and re-sign AFTER collecting.** `+ios2` first
  failed with `iosc_egl: ANGLE Metal display = 0x0 (err 0x3000)` -- ANGLE
  returning EGL_NO_DISPLAY with EGL_SUCCESS, i.e. no Metal device, the
  fakesigned-GPU-entitlement signature. The cause was mundane: the wave's
  `collecting game-wave debs` step copies fresh debs from `build_dist` over
  `out/`, silently replacing an already-re-signed deb with an unsigned rebuild.
  Downgrading to `+ios1` to bisect reproduced the failure and wrongly implicated
  the environment -- that `+ios1` was itself a fresh unsigned rebuild, not the
  binary that had worked.
- OPEN: it renders but stutters audibly; thermal pressure is 0 and nothing else
  is running, so the live lead is the 2048x1536 render surface -- the compositor
  forces fullscreen toplevels and ignores `--window --resolution`.
- OPEN (compositor, not the game): when the Xios app's orientation disagrees
  with iosc's output geometry -- app presenting 2160x2880 while iosc serves
  2880x2160 -- the display pillarboxes with black borders and `xios-device shot`
  captures a sheared frame (bands offset horizontally, since the capture assumes
  the landscape stride). Restarting the slot and the Xios app does not clear it.
  Any runtime conclusion drawn from a capture in that state is unreliable.

### Battle for Wesnoth

- `1.18.5+ios1` recipe, package, launcher, and target patch exist.
- SDL2_image 2.8.12, SDL2_mixer 2.8.2, and compiled Boost game-library
  recipes cover its additional closure.
- SDL2_image needed two fixes: the `os/object.h` sendable backport (it compiles
  `IMG_ImageIO.m`, so any Foundation include pulls the newer `xpc/session.h`),
  and `-DSDL2IMAGE_BACKEND_IMAGEIO=OFF`, because the Apple backend links
  macOS-only `ApplicationServices`. System libpng/libjpeg cover the formats.
- Boost must build at C++17 (ICU 78's headers use `std::is_same_v` and
  `if constexpr`) and must include the `graph` component, which Wesnoth's
  `find_package` requires.
- Source is a 462 MB bz2 and truncated repeatedly on a flaky connection; see
  the download gotcha below.
- **Builds (2026-08-03):** `wesnoth 1.18.5+ios1` is in `linux-build/out/`.
  Patches 0002-0004 were needed beyond the existing target patch; see
  `ports/wesnoth/patches/`. Device proof remains open.

### 0 A.D. -- DROPPED 2026-08-03 (blocked on mozjs packaging, not on 0 A.D.)

**Do not restart this without rebuilding mozjs first.** Everything on the 0 A.D.
side works: the premake patch applies, `--xios` is accepted, workspaces
generate, and the engine compiles until it needs SpiderMonkey headers. It is
blocked by a defect in the published mozjs packages:

- `libmozjs-115-dev 115.12.0+ios1` ships **545 headers that are all dangling
  symlinks** into `/work/Procursus/mozjs-derisk/firefox-115.12.0/...`, a build
  tree that exists on no device and in no surviving volume. The package installs
  cleanly and every header is unreadable, so `-I`, `-isystem` and `-idirafter`
  all fail identically -- which reads as an include-path bug for a long time.
- `libmozjs-115-jit-dev 115.12.0+ios2` has **real, complete headers**, but
  installs them flat at `usr/include/js/...` while its own `mozjs-115.pc`
  advertises `-isystem ${includedir}/mozjs-115`. Consumers using pkg-config get
  a path that does not exist in that package.

`mozjs.mk` and `mozjs-jit.mk` both already carry the `cp -aL` deref that would
prevent the first bug. The broken deb is a STALE artifact: `.build_complete`
short-circuits the `mozjs:` target, so `mozjs-package` re-packaged pre-fix
staging without ever re-running the deref. Any mozjs repackage must force the
build/stage step, not just the package step.

Rebuilding is the only repair for the dangling-symlink deb, and
`procursus-vol-gjs` is pruned, so it means the full mozjs 115 cross (Rust
toolchain, two passes, the heaviest cross in the tree, gated in
`build-gjs.sh`). That was judged not worth it for one game. If mozjs is ever
rebuilt, 0 A.D. should resume cleanly -- keep the recipe and patch.

Historical notes on the port itself:

### 0 A.D. (port state at drop)

- Alpha 27.1 is deliberate: it uses SpiderMonkey 115, already built and
  device-proven in Xios. Alpha 28 requires a separate mozjs 128 port.
- The official 27.1 build archive is 153,554,512 bytes and the data archive is
  1,367,955,136 bytes. The iPad currently has about 61 GiB free.
- The premake target patch applies cleanly and selects the Unix sysdep layer,
  GLES, SDL2, system mozjs 115, ENet, and compiled Boost while excluding X11
  and unsupported Linux link flags.
- Recipe, ENet dependency, package metadata, launcher, and full data packaging
  exist. Fixed on the way to the mozjs wall, all still in tree:
  - `DO_PATCH` was called with its arguments SWAPPED (`zero-ad,0ad` instead of
    `0ad,zero-ad`), so the premake patch had never once applied -- `patch -sN`
    skips silently. The recipe now asserts `trigger = "xios"` reached
    premake5.lua and carries `ZERO_AD_PATCH_REV`.
  - The premake bootstrap builds HOST tools, and the cross toolchain reached it
    through three channels: CC/CXX via MAKEFLAGS (command-line variables
    outrank the environment in nested makes), CFLAGS/LDFLAGS exported, and
    AR/RANLIB exported -- the last archived host objects with the Darwin ranlib,
    giving `liblua-lib.a` an empty table of contents. `XIOS_HOST_TOOLCHAIN`
    pins the whole host toolchain in one place.
  - `update-workspaces` queries pkg-config for TARGET libraries but 0 A.D.
    calls bare `pkg-config`, which has none of the cross wrapper's config. It
    now exports the same `PKG_CONFIG_LIBDIR`/`PKG_CONFIG_SYSROOT_DIR`.

## Build entry point

Use the named Procursus cache and the existing package payload mount:

```bash
PROCURSUS_VOL=procursus-vol-wayland \
  TARGETS='openttd-package' JOBS=2 \
  bash linux-build/run-target-script.sh build-games.sh -- \
    -v "$PWD/../repo/debs:/repo-debs:ro"
```

Build codec/runtime dependencies before the Warzone/Wesnoth/0 A.D. game
targets. `build-games.sh` applies `+ios1` at each upstream package's deb-version
seam and collects the resulting packages in `linux-build/out/`.

## Device verification

Keep game testing isolated from the selected KDE session:

```bash
bin/xios-device status --slot codex-games
bin/xios-device app --slot codex-games openttd
bin/xios-device shot --slot codex-games game-openttd-proof
```

The slot is `codex-games`, with Wayland socket
`/var/jb/tmp/wayland-codex-games`. A successful host build or package install
does not count as game proof: require a non-black compositor capture plus a
game-specific startup log or visible main menu.

## Gotchas

- **Never publish the `+ios1` stamps of stock Procursus recipes.**
  `build-games.sh` blanket-stamps `+ios1` onto libogg, libvorbis, libopus,
  libtheora, libsodium, libzip and openssl. The device already has every one of
  those from Procursus at the same upstream version, so each is a shadow at a
  bumped deb revision that adds nothing -- including an openssl one, the exact
  package whose shadow bricked `sshd`/`apt` before. Warzone runs fine against
  the stock Procursus versions; they are build-time conveniences only.
- **A dropped download does not fail, it truncates.** Procursus'
  `DOWNLOAD_FILES` neither verifies nor re-fetches and skips any file that
  already exists, so an interrupted transfer leaves a partial archive that tar
  unpacks *partially* and every later run reuses. Boost presented as a CMake
  subset-build misconfiguration (`Boost::config` not found, because
  `libs/config` was never written) and Wesnoth as a bz2 error. `build-games.sh`
  now integrity-tests every cached archive up front and deletes the bad ones,
  but on an unreliable link prefer fetching large sources on the host with
  `curl --retry ... --speed-limit` and copying them into the volume.
- **Do not put `#` comments inside a recipe's `cmake` invocation.** The
  backslashes join it into one shell command, so a comment line silently eats
  every argument after it. One in `boost-games.mk` dropped
  `BOOST_INCLUDE_LIBRARIES`, built all of Boost, and surfaced as `wordexp is
  unavailable` in `libs/process` -- a failure that invites patching the wrong
  thing entirely.
- Collection into `linux-build/out/` happens *after* the whole target loop, so
  a run that dies on a late target leaves every earlier package stranded in the
  volume. Re-run with only the already-built targets to collect them.

- Do not run two containers against `procursus-vol-wayland`. Dependency staging
  changes header mtimes and invalidates live precompiled headers.
  `build-games.sh` now holds a non-blocking lock in the Procursus volume and
  exits with status 75 if another game build owns it.
- OpenTTD setup removes both its normalized source directory and any stale
  partially extracted version directory before unpacking a new patch revision.
- `SKIP_GAME_DEP_STAGING=1` is only for an already-populated sysroot during an
  incremental retry.
- The in-container `ldid` does not emit the DER entitlement slot needed by GPU
  clients. Always run `resign-graphics-packages.py` on the host before install.
- Do not replace the selected global desktop for game smoke; use
  `codex-games`. If another session switch leaves stale slot status/socket
  files, stop and restart only `codex-games` before drawing runtime conclusions.
- OpenTTD currently stops at its expected first-run OpenGFX bootstrap. The
  compositor capture is valid render proof, but not yet playable-game proof.
