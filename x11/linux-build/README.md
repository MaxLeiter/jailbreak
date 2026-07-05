# `linux-build/` — cross-compiling the X stack for rootless iOS

This directory cross-compiles the patched X11 components for the jailbroken iPad
(`iphoneos-arm64`, **rootless** `/var/jb`, Procursus CFVER **1900** / iOS 16) inside a
Debian container, then ad-hoc-signs them for the device. One command on the Mac produces
installable `.deb`s and signed server binaries.

It exists because building Procursus packages **directly on macOS 26 / Xcode 26** fights the
bleeding-edge toolchain (LTO/`nm` breaking libtool, clang promoting old warnings to hard
errors, `install_name_tool` rpath duplication, …). Procursus's **Linux** path uses
`cctools-port` + an older clang and builds the 2021-era X stack reliably — so we run that in
a container, keep the Mac clean, and get reproducible artifacts.

> Track-B1 rationale, the on-device gotchas, and where this sits in the roadmap are in
> [`../SCOPE.md`](../SCOPE.md).

## What it produces (`out/`)

| Artifact | What it is |
|---|---|
| `tigervnc-standalone-server_*_iphoneos-arm64.deb` | Corrected **Xvnc** — installs with plain `dpkg -i` (no `--force`), keyboard/XKB init works |
| `tigervnc-common_*.deb` | Xvnc companion (`vncconfig`, `vncpasswd`, config) |
| `tigervnc-scraping-server`, `tigervnc-xorg-extension` debs | Built alongside; not needed on-device |
| `Xvfb` | Signed virtual-framebuffer X server for bring-up/debug; the app display path is IOSurface |
| `Xios` | The **same** binary carrying the IOSurface DDX, signed with a minimal IOKit/`task_for_pid` entitlement set (`-iosurface` activates the zero-copy backend) |
| `x11-xvfb_*_iphoneos-arm64.deb` | Packaged Xvfb server for rootless installs, built from target artifacts |
| `xios-server_*_iphoneos-arm64.deb` | Packaged IOSurface X server payload for the Xios app path |
| `xios-audio-server` | CoreAudio/RemoteIO audio daemon plus `xios-audio-play` smoke-test client |
| `libfribidi*`, `libpango*`, `gtk*`, … debs | The GTK3 desktop stack (from `build-gtk.sh`) |
| `iosc*`, `xios-session*`, GNOME/KDE/Wayland app debs | Built by their specialized `build-*.sh` and package scripts; see `docs/handoff/` for the current active lanes |

The `+rootless1`-revision debs are the rootless variants to publish.

## Prerequisites (one Mac action)

- **Docker running** (Docker Desktop is already installed — just start it). Nothing else is
  installed on the Mac; the whole toolchain lives inside the image.
- Your `iPhoneOS16.5.sdk` at `$HOME/theos/sdks/iPhoneOS16.5.sdk` (override with
  `SDK_SRC=...`). It is reused — no sketchy SDK downloads.
- A **macOS SDK** staged at `sdk/MacOSX.sdk` — Procursus's `setup` target harvests
  framework/legacy headers (FSEvents, Kernel, IOKit, Security, `sys/ttydev.h`, …) from it.

## Run

```bash
bash x11/linux-build/run.sh
```

What `run.sh` (Mac side) does:

1. Stages the iOS SDK into `sdk/iPhoneOS.sdk` (once; `rsync` only if missing).
2. `docker build` the toolchain image (slow first time — `cctools-port` + `ldid` from
   source — then cached).
3. `docker run` the image with `build.sh`, the `patches/` dir, the **named volume**, and
   `out/` mounted; this is where the actual package build happens.
4. **Re-signs `Xios` with the Mac's `ldid`** — the in-container `ldid` doesn't emit
   DER-encoded entitlements, which iOS 15+/16 AMFI requires to honor
   `iokit-user-client-class` (without DER, `IOSurfaceCreate()` returns NULL even though
   `ldid -e` reads the XML fine).
5. Builds the Xios audio package from `audio/`: `xios-audiod` mixes local PCM clients into
   iOS RemoteIO output, and `xios-audio-play` is the on-device smoke test. Real PulseAudio
   clients use the PulseAudio package and its native socket.

The tigervnc/Xvnc build is what `run.sh` drives by default. The GTK3 stack is a separate
container invocation (see below).

## Target-Aware Stub Libraries

The GNOME compatibility stublibs (`gudev`, `udev`, `pwquality`, `gsound`) can be built
through the target descriptor layer:

```bash
bash x11/linux-build/build-stublibs.sh rootless-1900 --package
bash x11/linux-build/build-stublibs.sh rootful-1900 --package
```

`build-stublibs.sh` loads `linux-build/targets/<target>.env`, passes the resolved
`MEMO_TARGET`, `MEMO_CFVER`, prefix, package payload prefix, and minimum iOS version into
the Procursus container, and stages runtime trees under the matching payload root:
`var/jb/usr/lib` for rootless, `usr/lib` for rootful. Use `--dry-run` to inspect the
Docker commands without starting a build. If the image already exists and Docker's BuildKit
cache is unhealthy, add `--skip-image-build` to run only the producer containers.

Rootful assembly requires rootful producer artifacts to exist first. If the package step
reports a missing `out/*-stub-tree/usr/lib`, run the producer through `build-stublibs.sh`
for the rootful target before assembling `xios-desktop-stublibs`.

## Target-Aware X Server Artifacts

`build-xserver-target.sh` drives the patched TigerVNC/Xorg build through
`linux-build/targets/<target>.env` and stages the resulting binaries under
`linux-build/out/targets/<target-id>/`:

```bash
bash x11/linux-build/build-xserver-target.sh rootless-1900 --package-xvfb
bash x11/linux-build/build-xserver-target.sh rootful-1900 --package-xvfb --package-xios
```

`packages/x11-xvfb/build.sh` packages `Xvfb` from that target artifact directory. It
keeps the committed rootless `Xvfb` as a fallback for `rootless-1900`, but refuses
rootful assembly until `linux-build/out/targets/rootful-1900/Xvfb` exists, so a
rootless binary cannot be accidentally shipped in a rootful package.

`packages/xios-server/build.sh` does the same for `Xios`. Rootless can fall back
to the committed package binary; rootful refuses to package until
`linux-build/out/targets/rootful-1900/Xios` exists. `build.sh` now renders
`xios-ent.xml` from the selected target prefix so rootful entitlement output does
not carry rootless `/var/jb` path exceptions.

## The named volume — why and how

```
-v procursus-vol:/work/Procursus
```

The cloned + already-built Procursus tree lives in a Docker **named volume**, not a host
bind-mount, for two reasons:

- **Correctness:** a macOS bind-mount over virtiofs breaks libtool's `ar`/`.lax` archive
  handling mid-build.
- **Speed:** the ~50 deps (mesa, libx11, gnutls, …) keep their `.build_complete` markers
  across runs and are reused; only the package you're iterating on rebuilds. The first run
  populates the volume (long); subsequent runs are fast.

`build.sh` force-rebuilds **just** tigervnc (`rm -rf build_work/.../tigervnc`) each run so
IOSurface-DDX changes take effect while everything else stays cached. Override the volume
name with `PROCURSUS_VOL=...`.

## The build (`build.sh`, in-container)

1. Clone Procursus fresh (into the volume, if not already there).
2. **Apply our changes portably** (python3, no host paths) into the clone:
   - inject the `/bin/sh`→`/var/jb/bin/sh` patch into `makefiles/tigervnc.mk`, gated to the
     rootless `/var/jb` prefix, applied right after tigervnc's own `xserverNNN.patch`;
   - drop our IOSurface DDX sources (`patches/xios/*`) into `xorg-server`'s `hw/vfb/`;
   - drop the bogus `tigervnc-xorg-extension` dependency from the standalone server's
     control file;
   - `--enable-xvfb` so the framebuffer server builds alongside Xvnc;
   - assorted toolchain fixes (mesa/libpng URLs + shader-cache, `-D_DARWIN_C_SOURCE`,
     `-stdlib=libc++`, `MacOSX.sdk` header copies) — see comments in `build.sh`.
3. Build `font-util` + `libxkbfile` (xserver build deps), then `tigervnc-package`, with
   `MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1`.
4. Extract + sign `Xvfb` (Procursus `general.xml` entitlements) and produce `Xios` from the
   same binary signed with a **minimal** set: `platform-application`,
   `iokit-user-client-class` (`IOSurfaceRootUserClient`/`IOSurfaceSendRight`),
   `task_for_pid-allow`, and a `/var/jb` path exception. `build.sh` asserts the signature
   carries the IOKit + `task_for_pid` entitlements and **not** the container-manager set
   (which would sandbox the process away from IOKit → `IOSurfaceCreate` NULL).
5. Collect `tigervnc-*.deb` to `/out` and print a sanity check that `/var/jb/bin/sh` is
   actually baked into the shipped `Xvnc`.

## The GTK3 stack (`build-gtk.sh`, in-container)

These recipes don't exist in Procursus, so `recipes/*.mk` are dropped into the clone's
`makefiles/` (the main Makefile globs `makefiles/*.mk`) and the dep chain is built; deps
that **do** exist in Procursus (glib/cairo/harfbuzz/freetype/fontconfig/libpng/…) cascade.

```bash
docker run --rm --platform linux/arm64 \
  -v procursus-vol:/work/Procursus \
  -v "$PWD/build-gtk.sh:/work/build-gtk.sh:ro" \
  -v "$PWD/recipes:/work/recipes:ro" \
  -v "$PWD/../ports:/work/ports:ro" \
  -v "$PWD/out:/out" \
  -e TARGETS="fribidi-package pango-package gdk-pixbuf-package atk-package gtk+3.0-package" \
  procursus-xbuild:bookworm-arm64 /work/build-gtk.sh
```

`TARGETS` defaults to the full fribidi→pango→gdk-pixbuf→atk→gtk3 chain; set it to build a
subset. Resulting `lib{fribidi,pango,gdk-pixbuf,atk,gtk}*` debs are copied to `out/`.

## Layout

```
linux-build/
  Dockerfile        # Debian + cctools-port (aarch64-apple-darwin) + ldid, native arm64
  run.sh            # Mac: stage SDK, docker build, docker run build.sh, re-sign Xios
  build.sh          # in-container: clone Procursus, patch, build tigervnc/Xvfb/Xios
  build-gtk.sh      # in-container: install recipes/*.mk, build the GTK3 stack
  patches/
    0001-xserver-popen-shell-rootless.patch   # /bin/sh → /var/jb/bin/sh (mirror of ../ports/)
    xios/{InitOutput.c,Makefile.am,xios_surface.c,xios_surface.h}  # IOSurface DDX
  recipes/*.mk      # new Procursus package makefiles (fribidi.mk, …)
  sdk/              # staged iPhoneOS.sdk + MacOSX.sdk        (gitignored)
  out/              # built debs + signed Xvfb/Xios          (gitignored)
  Procursus/, procursus-work/, *.log                          (gitignored)
```

## Install on the iPad

```bash
scp out/tigervnc-standalone-server_*_iphoneos-arm64.deb root@<ipad>:/var/jb/tmp/
ssh root@<ipad> 'dpkg -i /var/jb/tmp/tigervnc-standalone-server_*.deb'
```

No `--force` needed — the dependency fix makes it install cleanly. The on-device byte-patch
(`/var/jb/tmp/Xvnc.fixed` + `/var/sh` symlink) is obsolete; the rebuilt binary execs
`/var/jb/bin/sh` directly. For the native app, copy the re-signed `out/Xios` into the Xios
app bundle (see `apps/Xios/`).
