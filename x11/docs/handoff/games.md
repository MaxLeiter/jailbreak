# Handoff: games

Last checked against `repo/Packages`: 2026-10-25.

## Current state

**No game package is published.** None of `openttd`, `warzone2100`,
`wesnoth`, `crispy-doom`, `freedoom`, `xios-sdl2`, `libsdl3-0` or
`libsdl2-mixer-2.0-0` is in `repo/Packages`. Everything below runs from local
builds installed on the iPad.

| Game | Recipe revision | Device state |
|---|---|---|
| OpenTTD 15.3 (SDL2) | `+ios2` | playable: real main menu with `openttd-opengfx`, input works |
| Warzone 2100 4.7.0 (SDL3) | `+ios2` | reaches its 3D main menu on ANGLE Metal; audio stutters |
| Crispy Doom 7.1 + Freedoom 0.13.0 (SDL2) | `+ios3` | runs on the GPU with sound, ~55 fps timedemo; launches from the Home Screen |
| Battle for Wesnoth 1.18.5 (SDL2) | `+ios1` | builds; never run on device |
| 0 A.D. 27.1 | dropped | blocked on the broken mozjs dev package, see below |

They are ordinary Wayland clients. Touch, keyboard, pointer, scrolling,
PulseAudio and IOSurface presentation all come from the Xios app, iosc, SDL and
the audio layer; nothing here is game-specific plumbing. SDL2 and SDL3 both
reach iosc and ANGLE Metal on the A10 with touch
(`renderer=ANGLE (Apple, ANGLE Metal Renderer: Apple A10 GPU) version=OpenGL ES 3.0`).

Before publishing any of these:

- `crispy-doom` needs `libsdl2-mixer-2.0-0` published with it, and that has to
  clear the Procursus shadow gate.
- Only publish the game, its data packages, `xios-sdl2` and `libsdl3-0`. Never
  the `+ios1` stamps of stock Procursus libraries (see gotchas).
- Re-sign the final debs on the host (see gotchas).

Open:

- Warzone 2100 renders but stutters audibly with thermal pressure at 0. The
  live lead is the 2048x1536 render surface: iosc forces fullscreen toplevels
  and ignores `--window --resolution`.
- Wesnoth needs its first device run.
- Host gestures (keyboard-reveal pan, two-finger pan, pinch, rotate) still
  cancel multi-finger game input in the classic Xios app; there is no per-app
  opt-out there yet. Native mode has `X-Xios-RawTouch=true` (Crispy Doom uses
  it).

## SDL

- **SDL2 is vendored as `xios-sdl2`, never shipped as `libsdl2-2.0-0`.** Ours
  is Wayland-only and does not export `_SDL_UIKitRunApp` or
  `_SDL_OnApplicationDidChangeStatusBarOrientation`, which Procursus's 2.0.14
  does, and `libsdl2-2.0-0` has Procursus reverse dependencies (`ffmpeg`,
  `libavdevice59`, and `powder`, a UIKit SDL app). Publishing under that name
  would replace theirs repo-wide, the same shape as the openssl incident. It
  installs to `/var/jb/usr/lib/xios-sdl2` and the game wrappers reach it with
  `DYLD_LIBRARY_PATH`. I proved it by removing `libsdl2-2.0-0` from the iPad and
  watching OpenTTD still reach its menu. Do not add a `libsdl2-2.0-0` waiver to
  `bin/lib/shadow-waivers.json`.
- SDL3 (`libsdl3-0 3.2.30+ios2`) needs none of this; Procursus ships no SDL3.
- **SDL audio is PulseAudio only.** Both SDLs carry just the `pulseaudio` and
  `dummy` drivers. `xios-audio-server` 0.1.0 exported
  `SDL_AUDIODRIVER=coreaudio` to every login shell, so games started from the
  session were silent; 0.1.1 dropped it (2026-10-01). Wrappers default to
  `pulseaudio` anyway. Warzone and 0 A.D. use OpenAL (`ALSOFT_DRIVERS=pulse`),
  so the SDL setting never mattered for them.
- **SDL2's Wayland app_id is `SDL_App`** on this target. Native mode matches
  windows to hosts by app_id, so wrappers must set
  `SDL_VIDEO_WAYLAND_WMCLASS=<desktop id>`.

## Per game

### OpenTTD

The compatibility series applies cleanly to a pristine 15.3 tree: Unix-SDL on
Darwin, Clang 14 aggregate/template fixes, the Xios locale and desktop-media
paths, and `SDL_SetMainReady()` for the non-`SDL_main` entry point. With
`openttd-opengfx` installed it goes straight to the real main menu, and an
injected click dismissed the first-run survey while the demo world kept
moving, so the frame is live. A slot that refuses input is a stale slot:
`session stop` then `session iosc` on it.

### Warzone 2100

The patch drops the macOS bundle/AppKit path but keeps the Darwin ABI, and
selects the Unix SDL3/GLES path. `+ios2` fixed a packaging bug: the real
binary lives in `libexec/games`, so the data search it derives from its own
path never reached `share/warzone2100` ("Could not find game data"). The
wrapper now passes `--datadir` (override with `WZ2100_DATADIR`).
`libvorbisfile3` must come from Procursus.

### Crispy Doom

On-screen touch controls are `ports/crispy-doom/patches/0100-xios-touch-controls.patch`
(floating left stick, right-half drag to turn, FIRE/USE/NEXT/MENU/MAP buttons).
Home Screen launch needed `xios-launcher-tools` 0.1.11 (ioscd execs through
libiosexec, so `#!/bin/sh` wrappers work) and `pulseaudio 17.0-7+ios3` with
`xios-audio-server` 0.1.1 (native apps run as `mobile`, and the old PulseAudio
dir was root `0700`). Launching with `uiopen` while the iPad is locked leaves
IOSCHost suspended; unlock first.

### Battle for Wesnoth

Needs SDL2_image 2.8.12, SDL2_mixer 2.8.2 and the compiled Boost game
libraries. SDL2_image needs the `os/object.h` sendable backport (its
`IMG_ImageIO.m` pulls in the newer `xpc/session.h`) and
`-DSDL2IMAGE_BACKEND_IMAGEIO=OFF` (the Apple backend links macOS-only
`ApplicationServices`). Boost must build at C++17 for ICU 78's headers and must
include `graph`. Patches 0002-0004 in `ports/wesnoth/patches/` were needed
beyond the target patch.

### 0 A.D. (dropped 2026-08-03)

Everything on the 0 A.D. side works up to the SpiderMonkey headers. The wall
is our mozjs packaging:

- `libmozjs-115-dev 115.12.0+ios1` ships 545 headers that are all dangling
  symlinks into a build tree that no longer exists. Every `-I` variant fails
  the same way, which looks like an include-path bug for a long time.
- `libmozjs-115-jit-dev 115.12.0+ios2` has real headers but installs them flat
  at `usr/include/js/...` while its `mozjs-115.pc` says
  `${includedir}/mozjs-115`.

`mozjs.mk` and `mozjs-jit.mk` already carry the `cp -aL` that prevents the
first bug; the published deb is stale because `.build_complete` short-circuits
the build and `mozjs-package` repackaged old staging. Any mozjs repackage has
to force the stage step. Rebuilding means the full mozjs 115 cross (the
heaviest in the tree), and it wasn't worth it for one game. Keep the recipe and
patch; if mozjs is ever rebuilt, 0 A.D. should resume.

Fixed on the way and still in the tree: `DO_PATCH` had its arguments swapped
(`patch -sN` skipped silently, so the premake patch never applied; the recipe
now asserts it did), and the premake bootstrap built host tools with the cross
toolchain leaking in through MAKEFLAGS, exported CFLAGS/LDFLAGS and AR/RANLIB
(`XIOS_HOST_TOOLCHAIN` pins the host toolchain in one place). Alpha 27.1 is
deliberate: alpha 28 needs mozjs 128.

## Gotchas

- **Re-sign after every collect, not just every build.** The in-container
  `ldid` never writes the DER entitlement slot, and the wave's collect step
  copies fresh debs from `build_dist` over `out/`, silently replacing a
  re-signed deb. Without the slot ANGLE gets no Metal device and returns
  `EGL_NO_DISPLAY` with `EGL_SUCCESS`
  (`iosc_egl: ANGLE Metal display = 0x0 (err 0x3000)`). Bisecting by
  downgrading reproduced it and wrongly cleared the rebuild, because the older
  deb was also a fresh unsigned rebuild. Always run, on the host:

  ```bash
  python3 linux-build/resign-graphics-packages.py linux-build/out \
    --gpu-ent linux-build/build_info/iosc-gpu-client-ent.xml \
    --gl-ent linux-build/build_info/iosc-gl-ent.xml \
    --only <pkg> --verbose
  ```
- **Never publish the `+ios1` stamps of stock Procursus recipes.**
  `build-games.sh` stamps `+ios1` onto libogg, libvorbis, libopus, libtheora,
  libsodium, libzip and openssl. The device already has each from Procursus at
  the same upstream version, so they would be pointless shadows, including an
  openssl one, the package whose shadow bricked `sshd` and `apt` before.
- **Count iosc processes before theorising about geometry.** A "rotated"
  Warzone frame turned out to be a second iosc started with
  `run-shell.sh <slot>`: that script reads the slot from `WAYLAND_DISPLAY` and
  ignored the argument, so it ran on the default slot and overwrote
  `/var/jb/tmp/xios.json`. `run-shell.sh` now rejects positional arguments, and
  `xios_read_output_region` refuses an oversized rect instead of clamping it
  into a plausible-looking but sheared PNG.
- **A dropped download truncates instead of failing.** Procursus
  `DOWNLOAD_FILES` doesn't verify or re-fetch, so a partial archive gets reused
  forever. It showed up as a Boost CMake misconfiguration (`Boost::config` not
  found) and a Wesnoth bz2 error. `build-games.sh` now integrity-tests cached
  archives; on a flaky link, fetch big sources on the host with
  `curl --retry` and copy them into the volume.
- **No `#` comments inside a recipe's `cmake` invocation.** The backslashes
  make it one shell command, so a comment eats every argument after it. One in
  `boost-games.mk` dropped `BOOST_INCLUDE_LIBRARIES` and surfaced as
  `wordexp is unavailable` in `libs/process`.
- Collection into `linux-build/out/` happens after the whole target loop, so a
  late failure strands earlier packages in the volume. Re-run with only the
  built targets to collect them.
- Don't run two containers against `procursus-vol-wayland`; staging changes
  header mtimes and invalidates precompiled headers. `build-games.sh` takes a
  lock and exits 75 if another build holds it.
- `SKIP_GAME_DEP_STAGING=1` is only for an already-populated sysroot.

## Build

```bash
PROCURSUS_VOL=procursus-vol-wayland \
  TARGETS='openttd-package' JOBS=2 \
  bash linux-build/run-target-script.sh build-games.sh -- \
    -v "$PWD/../repo/debs:/repo-debs:ro"
```

Build codec and runtime dependencies before the game targets.

## Verify on device

Use the `codex-games` slot (socket `/var/jb/tmp/wayland-codex-games`) so the
selected desktop is never touched:

```bash
bin/xios-device status --slot codex-games
bin/xios-device app --slot codex-games openttd
bin/xios-device shot --slot codex-games game-openttd-proof
```

A host build or a clean install is not proof. Require a non-black compositor
capture plus a visible main menu or a game-specific startup log. If another
session switch leaves stale slot files, restart only `codex-games`.
