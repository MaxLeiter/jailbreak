# Xios — original scope, and the decisions that stuck

This is the founding scope note for the redo of <https://maxleiter.com/blog/X11>: cross-compiled
on a Mac instead of built on the device, patches managed reproducibly with quilt, targeting
rootless jailbroken iOS. It is kept for the decisions and the hard-won gotchas, not for status
— **current status lives at [xios.maxleiter.com](https://xios.maxleiter.com)** and, per
subsystem, in [`docs/handoff/INDEX.md`](docs/handoff/INDEX.md).

The staged plan this file used to track (X-over-VNC → native X server → IOSurface DDX →
per-window compositing → iOS-scene hosting) is finished or superseded. The display path is a
native app fed by an `IOSurface`, and the desktop path is a Wayland compositor rather than X:
the software Xvfb-derived `Xios` server that stages 1 and 2 built was **retired on
2026-07-29**, X11 apps now run through hardware Xwayland inside the compositor, and Xvnc and
Xvfb remain only for headless bring-up and debugging. The entitlement and prefix lessons
below outlived the server they were learned on, which is why this file is still here.

## What changed versus the 2019/2020 build

The original was an on-device BLFS-from-scratch build (gettext → glib → mesa → tigervnc → …),
compiled on the iPad, hand-patched in place, unreproducible.

The modern rootless bootstrap is **Procursus**, itself a cross-compile build system that
already ships an X11 stack and TigerVNC prebuilt for `iphoneos-arm64`. So the correction to
the original plan was: don't rebuild the stack — stand on it, and spend the cross-compile and
quilt effort on the pieces that don't exist, i.e. our own display servers.

## Decisions that stuck

- **Toolchain: extend Procursus** (rather than a standalone clang+sysroot+dpkg-deb stack),
  layering our own `ports/` patch series and `linux-build/recipes/*.mk` on top.
- **Build in a Linux container, not on macOS.** A macOS-hosted build was attempted and
  abandoned in June 2026: macOS 26 / Xcode 26 is newer than Procursus's macOS path supports,
  and the 2021-era X packages hit LTO+`nm` breaking libtool, clang promoting old warnings to
  errors, `ld64` rpath duplication, and stale URLs. Procursus's `cctools-port` Linux path
  builds the same stack reliably and keeps the Mac clean. See
  [`linux-build/README.md`](linux-build/README.md).
- **Our own DDX / compositor, not an embedded VNC viewer.** Good VNC clients already exist;
  the value was in getting pixels to the screen without a network hop.
- **Fonts point at the live iOS system fonts.** `x11-fonts-sf` adds `/System/Library/Fonts`
  to fontconfig and maps the generic families to `.SF UI` / `.SF UI Mono`, so no font file is
  ever copied or redistributed and the stack follows OS updates. (Procursus ships font
  engines but no font files, which is what broke XKB-era text rendering originally.)
- **Depend on Procursus package *names*** rather than vendoring, so one deb works across
  Procursus devices.

## The rootless blockers, and why they mattered

All three were `/var/jb` prefix mismatches, and they still explain shapes in the tree:

1. **A bogus dependency.** `tigervnc-standalone-server` hard-depended on
   `tigervnc-xorg-extension` → `xserver-xorg-core`, which Procursus does not ship (there is
   no Xorg DDX for iOS). Dropping it is why the deb installs with plain `dpkg -i`. Upstream
   proposal: [`docs/procursus-pr-tigervnc.md`](docs/procursus-pr-tigervnc.md).
2. **`/bin/sh` hardcode killed keyboard init.** xorg-server's `os/utils.c` execs
   `/bin/sh -c "xkbcomp …"`, and rootless has no `/bin/sh`. Fixed properly with a quilt patch
   pointing the spawn shell at `$(MEMO_PREFIX)/bin/sh`, applied during the cross-build — a
   no-op on rootful targets.
3. **No font files.** Fixed by `x11-fonts-sf`, above.

## Entitlement gotchas for fakesigned apps that need the GPU and `/var/jb`

These two cost days each and are still load-bearing for anything new that presents pixels:

1. **The GPU needs an explicit IOKit entitlement.** Without
   `com.apple.security.iokit-user-client-class` listing the GPU/IOSurface user clients
   (`AGXDeviceUserClient`, `IOSurfaceRootUserClient`, …), `MTLCreateSystemDefaultDevice()`
   returns **nil** and you get a black screen. Ad-hoc-signed apps do not get it by default.
2. **Use a sandbox path exception for `/var/jb`, not `no-container`.** Grant filesystem
   access with `com.apple.security.exception.files.absolute-path.read-write` (the mechanism
   Sileo uses). `com.apple.private.security.no-container` also strips the entitlement path
   that reaches the GPU IOKit user client, so the GPU dies along with the sandbox.

Related: the compositor-side surface share needs `IOSurfaceRootUserClient` **and**
`task_for_pid-allow`, because iOS 17 removed global `IOSurfaceLookup(id)` — the surface's mach
port is handed to the app over a rendezvous socket instead. The broad container-manager set
must stay off; it sandboxes the process away from IOKit and `IOSurfaceCreate` returns NULL.

## The quilt workflow (how patches stay reproducible)

```
ports/<pkg>/
  patches/
    series         # ordered list of patch files (quilt's index) — source of truth
    0001-*.patch
```

Pristine source is never committed; Procursus or a `fetch.sh` reproduces it, and only
`patches/` plus build scripts are version-controlled. Procursus applies a flat patch
directory, which a quilt `series` maps onto 1:1, so quilt stays the authoring UX. Local
source *injections* that aren't upstream patches (the compositor/app IOSurface glue) live
separately under `linux-build/patches/`.

`clone + fetch + quilt push -a + build` reproducing every artifact on any host is the
explicit fix for the original's "patched in place, on device" problem.

## Targeting jailbreaks beyond the reference device

- **Rootless (Dopamine, palera1n, modern)** — `/var/jb` prefix, Procursus,
  `iphoneos-arm64`. This is what everything here targets; the reference device runs Dopamine.
- **Rootful / legacy** — `/` prefix, different libc paths. Procursus can target it with an
  empty `MEMO_PREFIX`, and `linux-build/targets/rootful-1900.env` exists so a rootless binary
  can't be silently packaged as a rootful one, but rootless stays the shipped layout.
- **RootHide** relocates the jbroot and needs its own Theos fork; not supported here.
- **CFVER** — the reference device is on dist `1900`. Other iOS versions map to other dists,
  so a multi-version release means building per-CFVER.
