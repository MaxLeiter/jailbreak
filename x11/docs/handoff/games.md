# Xios strategy-game ports

Updated: 2026-07-30

## Scope

This lane adds four full desktop strategy/simulation games to Xios:

1. Warzone 2100 4.7.0 (SDL3)
2. Battle for Wesnoth 1.18.5 (SDL2)
3. OpenTTD 15.3 (SDL2)
4. 0 A.D. 27.1 (SDL2, ANGLE GLES, SpiderMonkey 115)

They are normal Wayland clients. UIKit touch, hardware keyboard, pointer,
scrolling, PulseAudio, and IOSurface presentation remain owned by the existing
Xios app, iosc, SDL, and audio layers.

## Current status

### Shared SDL foundation

- `libsdl3-0 3.2.30+ios2`, `libsdl2-2.0-0 2.32.10+ios2`, and
  `xios-sdl-smoke 1.0.1` are installed on the physical iPad.
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
- On-device launch reaches SDL2 Wayland and maps a live 1360x1000 window:
  `Successfully loaded video driver 'sdl'`. The visible bootstrap correctly
  reports that no base graphics set is installed and offers to download
  OpenGFX. Evidence:
  `game-openttd-20260730-1108/compositor.png`.
- The game process remained alive behind the bootstrap. Full-playability proof
  is gated on installing/downloading OpenGFX. The isolated compositor input
  socket refused the attempted injected tap, so this run does not claim menu
  interaction or gameplay.
- The final package must still be host-DER re-signed after every repack:

  ```bash
  python3 linux-build/resign-graphics-packages.py linux-build/out \
    --gpu-ent linux-build/build_info/iosc-gpu-client-ent.xml \
    --gl-ent linux-build/build_info/iosc-gl-ent.xml \
    --only openttd --verbose
  ```

### Warzone 2100

- `4.7.0+ios1` recipe, package, launcher, and target patch exist.
- The patch disables the macOS bundle/AppKit path while retaining the Darwin
  ABI and selects the Unix SDL3/GLES path.
- Required local dependency recipes include OpenAL Soft and PhysicsFS.
- Build and device proof remain open.

### Battle for Wesnoth

- `1.18.5+ios1` recipe, package, launcher, and target patch exist.
- SDL2_image 2.8.12, SDL2_mixer 2.8.2, and compiled Boost game-library
  recipes cover its additional closure.
- Build and device proof remain open.

### 0 A.D.

- Alpha 27.1 is deliberate: it uses SpiderMonkey 115, already built and
  device-proven in Xios. Alpha 28 requires a separate mozjs 128 port.
- The official 27.1 build archive is 153,554,512 bytes and the data archive is
  1,367,955,136 bytes. The iPad currently has about 61 GiB free.
- The premake target patch applies cleanly and selects the Unix sysdep layer,
  GLES, SDL2, system mozjs 115, ENet, and compiled Boost while excluding X11
  and unsupported Linux link flags.
- Recipe, ENet dependency, package metadata, launcher, and full data packaging
  exist. Configure/build/device proof remain open.

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
