# X11 on iOS — Redux (scope)

Redo of <https://maxleiter.com/blog/X11>, "but right": cross-compiled on the Mac, patches
managed reproducibly (quilt), targeting the jailbroken iPad and ideally **all** jailbroken
devices. Interim display path was VNC; the endgame — a **native iOS X server app** — is now
live. This file tracks where each stage stands.

---

## Status at a glance

| Stage | What | State |
|---|---|---|
| **0** | X over VNC (Xvnc, reproducible deb) | **DONE** — cross-compiled deb published, installs clean, runs native |
| **1** | Native X server app ("Xios"): Xvfb → Metal → XTEST | **DONE & verified on-device** |
| **fonts** | `x11-fonts-sf` (San Francisco as default, no files copied) | **DONE & published** |
| **2** | IOSurface zero-copy DDX | **in flight** (landing now) |
| **3** | Per-window compositing (X Composite → per-window IOSurfaces) | planned |
| **4** | Host real iOS app scenes; iOS compositor *is* the desktop shell | planned |
| **audio** | Userspace CoreAudio bridge for X11/GTK apps | scoped — see `docs/audio-plan.md` |

Parallel in-flight work (other subagents): **GTK3 stack** (new Procursus recipes
fribidi→pango→gdk-pixbuf→atk→gtk3), **infra-hardening** (Xvfb deb + launcher), **dep
rehosting** (self-contained Sileo repo). See the [hardening backlog](#hardening-backlog).

---

## TL;DR — what changed since the original (2019/2020)

The original was a heroic on-device BLFS-from-scratch build (gettext → glib → mesa →
tigervnc → …), all compiled on the iPad, hand-patched in place, unreproducible.

**That entire build is obsolete.** The modern rootless bootstrap on this iPad is
**Procursus**, itself a *macOS-hosted cross-compile build system* that already ships the
full X11 stack **and TigerVNC**, prebuilt for `iphoneos-arm64`. So:

- **Stage 0 (X over VNC) needs almost no compilation** at the proof level — it's `apt
  install` + config. But the prebuilt debs carry rootless-prefix bugs (see below), so we
  **cross-compile a corrected `tigervnc`** ourselves; that is now the published deb.
- **Cross-compiling on the Mac (the user's actual ask) is the method for Stage 1+** — i.e.
  patching upstream source and building the **native server**, which Procursus does *not*
  provide. That is where quilt + a Mac/Linux toolchain earn their keep.

The key correction to the original plan: don't rebuild the stack — stand on it, and spend
the cross-compile/quilt effort on the custom server.

---

## Architecture — the five stages

### Stage 0 — X over VNC, reproducibly, from our own repo — **DONE**

Goal: a working X session on the iPad, installable as a clean package on any Procursus
device. Proven in a live spike (2026-06-28) and then made reproducible by a from-source
cross-compile (2026-06-29).

Three rootless blockers were found and fixed at the source level (all were `/var/jb`
prefix mismatches baked into the prebuilt debs):

1. **Broken dependency.** `tigervnc-standalone-server` hard-depended on
   `tigervnc-xorg-extension` → `xserver-xorg-core`, which Procursus does **not** ship (no
   Xorg DDX for iOS). The standalone `Xvnc` is self-contained and doesn't need the Xorg
   extension module. *Fix:* drop the bogus dep — the deb now installs with plain `dpkg -i`,
   no `--force`. (Upstream proposal: see [`docs/procursus-pr-tigervnc.md`](docs/procursus-pr-tigervnc.md).)

2. **`/bin/sh` hardcode = fatal keyboard init.** Xvnc died at `XKB: Failed to compile
   keymap`. Root cause: xorg-server's `os/utils.c` execs **`/bin/sh -c "xkbcomp …"`**, but
   rootless has no `/bin/sh` (the shell is `/var/jb/bin/sh`; `/` and `/bin` are read-only).
   *Spike workaround (now obsolete):* byte-patch the binary `/bin/sh`→`/var/sh` + symlink +
   re-sign. *Proper fix (shipped):* a one-line quilt patch to `os/utils.c` so the spawn
   shell is `/var/jb/bin/sh`, applied during the cross-build. The on-device byte-patch is
   gone — the rebuilt Xvnc starts cleanly.

3. **Zero fonts in Procursus.** Procursus ships the font *engines* (freetype/fontconfig)
   but no font files, and fontconfig scanned the non-rootless `/usr/share/fonts`. *Fix
   (shipped):* the `x11-fonts-sf` package (see [Fonts](#fonts)).

The working launch recipe is captured in `bin/x11-up.sh` (note: written for the spike's
byte-patched binary; being updated for the packaged Xvnc/Xvfb — see backlog).

**Viewing it (Stage 0):** any iOS VNC client pointed at `127.0.0.1:5901`. Touch→pointer and
an on-screen keyboard come for free over VNC, so Stage 0 needs no custom input handling.
This is superseded on-device by the native app (Stage 1), but VNC remains the
remote/debug path.

### Stage 1 — Native iOS X server app ("Xios") — **DONE & verified**

No Xorg display driver exists for iOS. Rather than ship an embedded VNC viewer (good VNC
clients already exist), Xios goes straight to a native server. The public app display path is
the IOSurface DDX:

```
Xios IOSurface DDX
   → typed app socket transfers the IOSurface mach port
   → app maps it as a Metal texture  → Metal display at RETINA 2160×1620
   → UIKit touches → X pointer events via XTEST
```

The X server is built from the same patched `xorg-server` tree we used for Stage 0 (the
`/var/jb/bin/sh` fix is what lets XKB keyboard init succeed), with the IOSurface backend
enabled by `-iosurface`. Xvfb remains useful for headless/debug X11 sessions, but it is not
the app display path. The app (`apps/Xios/`, Swift + Metal + a small C shim) presents the
shared surface and feeds input back in.

Two hard-won, non-obvious gotchas for **fakesigned (ad-hoc / non-App-Store) apps that need
the GPU and `/var/jb`**:

1. **GPU needs an explicit IOKit entitlement.** Without
   `com.apple.security.iokit-user-client-class` listing the GPU/IOSurface user clients
   (`AGXDeviceUserClient`, `IOSurfaceRootUserClient`, …), `MTLCreateSystemDefaultDevice()`
   returns **nil** → black screen. Fakesigned apps don't get the GPU client by default; you
   must request it.

2. **Use a sandbox path-exception for `/var/jb`, not `no-container`.** Filesystem access to
   `/var/jb` (libraries, fonts, xkb, runtime sockets) is granted with a
   `com.apple.security.exception.files.absolute-path.read-write` path exception — the same
   mechanism Sileo uses. Do **not** use `com.apple.private.security.no-container`: it also
   strips the process of the entitlements path that reaches the GPU IOKit user client, so
   the GPU dies along with the sandbox. Path-exception keeps both.

This is the multi-week custom piece the whole cross-compile/quilt investment was for.

### Stage 2 — IOSurface zero-copy DDX — **landed**

The IOSurface DDX removes per-frame file upload: the screen *is* an **IOSurface** the app
textures directly.

Implementation (sources in `linux-build/patches/xios/`, dropped into `xorg-server`'s
`hw/vfb` by the tigervnc recipe so the rebuilt `Xios` binary carries the backend):

- Server creates a BGRA8 IOSurface; X draws straight into its base address.
- iOS 17 killed global `IOSurfaceLookup(id)`, so the surface is shared by **handing its
  mach port to the app** over an `AF_UNIX` rendezvous socket: app sends `{pid, port name}`,
  server `task_for_pid()`s the app and `mach_msg()`s an `IOSurfaceCreateMachPort()` send
  right across; app does `IOSurfaceLookupFromMachPort()` → same backing memory.
- Server streams damage bounding-boxes over the socket; the app re-presents only on change.

This is why the Xios entitlement set needs `IOSurfaceRootUserClient` + `task_for_pid-allow`
(and explicitly **not** the broad container-manager set, which sandboxes the process away
from IOKit → `IOSurfaceCreate` returns NULL).

### Stage 3 — Per-window compositing — planned

Promote from one fullscreen surface to **one IOSurface per top-level X window**: enable the
**X Composite** extension, redirect each window to an offscreen pixmap backed by its own
IOSurface, and let the iOS side composite them as individual layers. This is the bridge
from "a Linux desktop in a box" to "X windows that look like iOS windows."

### Stage 4 — Real iOS app scenes; the iOS compositor *is* the desktop — planned

Host each X window (or app) in a real **iOS UIScene**, composited by our own iOS shell.
Keyboard input comes from the **native iOS keyboard → XTEST**. The "desktop environment" is
then our iOS compositor acting as the window manager/shell, running GTK/GNOME apps inside —
not an X WM rendered over VNC. This is the endgame: GTK/GNOME apps as first-class iOS
windows.

---

## Fonts — `x11-fonts-sf` — **DONE & published**

Procursus ships no font files. Rather than redistribute fonts, `x11-fonts-sf` points
fontconfig straight at the live iOS system fonts and makes **San Francisco** the default:

- A fontconfig conf (`/var/jb/etc/fonts/conf.d/09-x11-fonts-sf.conf`) adds `<dir>` =
  `/System/Library/Fonts` (scanned recursively, so Apple Color Emoji + PingFang CJK come
  for free) and maps the generic families (`sans-serif`/`serif`/`system-ui` → `.SF UI`,
  `monospace` → `.SF UI Mono`) with strong-bound prepends + aliases.
- `postinst` runs `fc-cache -f`.
- **No font files are copied or redistributed** — fontconfig tracks the OS, so it always
  follows system updates. `Depends: fontconfig`.

This closes Stage 0 blocker #3 cleanly and gives the whole stack a native-looking default.

---

## Build pipeline (Track B1 — extend Procursus, via a Linux container)

**Decision (locked):** use **Procursus as the cross-compile toolchain + dependency source**
(Track B1), layering our own `ports/` + `recipes/` with quilt-style patch series for the
components we customize. Best reproducibility per unit of effort; it is literally the tool
that already solved this problem. (Track B2 — a fully standalone clang+sysroot+dpkg-deb
toolchain — was considered and rejected as reinventing what Procursus provides.)

**Host: a Linux container, not macOS.** A macOS-host build was attempted then abandoned
(2026-06-28..29): macOS 26 / Xcode 26 is newer than Procursus's macOS path supports, and
the 2021-era X packages hit issue after issue (LTO+`nm` breaking libtool; clang promoting
old warnings to hard errors; `ld64` rpath duplication; stale URLs). All macOS changes were
reverted. Procursus's well-supported **`cctools-port` Linux path** builds the same stack
reliably and keeps the Mac clean.

The full kit + a reproducible runbook lives in **[`linux-build/`](linux-build/README.md)**:

- `Dockerfile` — Debian + GNU userland + `cctools-port` (aarch64-apple-darwin) + `ldid`,
  built natively for arm64 (no qemu). Reuses your staged `iPhoneOS16.5.sdk`.
- `run.sh` (Mac side) — stage SDK, `docker build`, `docker run build.sh`; then re-sign Xios
  with the Mac's `ldid` (the in-container ldid doesn't emit DER entitlements, which iOS
  15+/16 AMFI needs to honor the IOKit class entitlement).
- `build.sh` (in container) — clone Procursus, apply our patches portably (python3, no
  absolute paths), build `tigervnc-package` + `Xvfb` + `Xios`, collect debs to `/out`.
- `build-gtk.sh` (in container) — drop our `recipes/*.mk` into the clone and build the GTK3
  dep chain.

**Outputs** (`linux-build/out/`): `tigervnc-standalone-server` + `tigervnc-common` debs
(the corrected Xvnc), the signed `Xvfb` + `Xios` binaries, and the GTK3 stack debs
(`libfribidi*`, `libpango*`, `gtk*`, …). The published rootless variants carry the
`+rootless1` revision.

### Patches & recipes layout

```
ports/<pkg>/patches/{series,0001-*.patch}   # quilt series — source of truth, authoring UX
linux-build/patches/                        # mirror copied into the build context
  0001-xserver-popen-shell-rootless.patch   #   the /bin/sh → /var/jb/bin/sh fix
  xios/{InitOutput.c,Makefile.am,xios_surface.c,xios_surface.h}  # IOSurface DDX sources
linux-build/recipes/*.mk                    # NEW Procursus package makefiles (e.g. fribidi.mk)
```

`build.sh` does **not** carry the absolute-path overlay patch; it injects the patch + recipe
edits into the fresh Procursus clone via python so the build context has no host paths.

### Build gotchas (all solved in `build.sh`)

- `MEMO_TARGET=iphoneos-arm64-rootless` (plain `iphoneos-arm64` is rootful `/` and would not
  install on a `/var/jb` device); `MEMO_CFVER=1900`; `NO_PGP=1` for flaky tarball GPG.
- Build in a Docker **named volume** (`procursus-vol`) — a macOS bind-mount over virtiofs
  breaks libtool's `ar`/`.lax` handling.
- Force tigervnc to recompile (`rm -rf build_work/.../tigervnc`) so DDX changes take effect;
  all other deps keep their `.build_complete` markers and are reused (fast).
- Build `font-util` + `libxkbfile` before tigervnc (its bundled xserver needs them for
  autoreconf/configure but doesn't list them).
- Per-build: `CFLAGS += -D_DARWIN_C_SOURCE` and `CXXFLAGS += -stdlib=libc++`; mesa
  shader-cache disabled + `disk_cache.h` include fixups; stale mesa/libpng URLs rehosted;
  libpng APNG patch skipped; a real `MacOSX.sdk` staged for Procursus's `setup` header
  harvest.

---

## The quilt workflow (how patches stay reproducible)

Per upstream component we patch, regardless of track:

```
ports/<pkg>/
  fetch.sh         # download + checksum-verify the pristine upstream tarball/tag
  patches/
    series         # ordered list of patch files (quilt's index)
    0001-*.patch
  build.sh         # configure/make/install into the staging prefix (or a Procursus .mk)
```

- Pristine source is **never** committed — `fetch.sh`/Procursus reproduces it; only
  `patches/` + build scripts are version-controlled.
- Author/maintain patches with `quilt new / add / refresh`; `series` is the source of truth.
  Procursus applies a flat patch dir; a quilt `series` maps onto it 1:1, so the two are
  compatible — we keep quilt as the authoring UX even under Track B1.
- Result: `git clone + fetch + quilt push -a + build` reproduces every artifact on any host.
  This is the explicit fix for the original's "patched in place on-device" problem.

---

## Hardening backlog

Code-review and follow-up items, captured so they aren't lost (status in brackets):

- **Xvfb packaging** [in progress] — ship the signed `Xvfb` as a real deb (`x11-xvfb`,
  built; `postinst` makes `/var/jb/var/lib/xkb`) rather than a loose binary; same for `Xios`.
- **`build.sh` robustness** [open] — output deb globbing is loose (matches both `_1.11.0_`
  and `+rootless1`); revisit the Docker layer caching, add a `.dockerignore`, and tidy the
  Mac-SDK staging (`rsync --delete` runs only when `sdk/iPhoneOS.sdk` is absent — stale SDKs
  won't refresh).
- **`xios.json` handshake race** [fixed] — geometry/socket handshake file is now written
  before the app reads it.
- **`bin/x11-up.sh` stale** [in progress] — still references the byte-patched
  `/var/jb/tmp/Xvnc.fixed` + `/var/sh` symlink; update to the packaged Xvnc/Xvfb paths.
- **xauth vs `-SecurityTypes None`** [decision needed] — Stage 0 uses `-localhost
  -SecurityTypes None`; decide whether to require `xauth` cookies for the on-device server.
- **Self-contained repo** [in flight] — rehost the Procursus deps we depend on so the Sileo
  repo installs without `apt.procurs.us` reachable.

---

## Ground truth (probed 2026-06-28)

Device `10.0.0.74` / `MaxsiPad.local`:

| Field | Value |
|---|---|
| Device | iPad 7th gen (`iPad7,12`, A10) |
| OS | iPadOS 17.6.1 (Darwin 23.6.0, `xnu-10063.142.1`) |
| Jailbreak | palera1n rootless → `/var/jb` |
| Bootstrap | **Procursus** (`.procursus_strapped` present) |
| APT source | `https://apt.procurs.us 1900/main iphoneos-arm64` (**CFVER 1900**) |

Available to `apt install` from the configured repo (no building): TigerVNC 1.11.0,
`fluxbox`, `x11-apps`, `xterm`, `xkeyboard-config`, `xkbcomp`, `xfonts-utils`, software GL
(`libgl1-mesa-glx`/`libgles2-mesa`/llvmpipe — no GPU driver, fine for a VNC framebuffer),
~174 X/font/mesa/tigervnc packages. There is **no Xorg display driver for iOS** — which is
exactly why Xvnc (virtual framebuffer + VNC) was the Stage 0 path and why Xios writes its
own DDX.

---

## "All jailbroken devices" considerations

- **Rootless (palera1n/Dopamine, modern)**: `/var/jb` prefix, Procursus, `iphoneos-arm64`.
  Primary target — this iPad.
- **Rootful / legacy (Elucubratus/bingner, older iOS)**: `/` prefix, different libc paths.
  Procursus can target it (`MEMO_PREFIX` empty); our debs would need a rootful variant.
  Note but **defer** — get rootless solid first. (The shell-path fix is already prefix-aware
  in the upstream proposal: `$(MEMO_PREFIX)/bin/sh` is a no-op for rootful.)
- **CFVER**: this device uses dist `1900`. Other iOS versions map to other dists; a
  multi-version release means building per-CFVER (a Procursus flag).
- Keep packages depending on Procursus package *names* (stable) rather than vendoring, so
  one deb works across all Procursus devices.

---

## Open questions / risks

1. **Daemon vs on-demand**: always-running X server, or launch-on-connect? Battery vs
   convenience.
2. **Native server input fidelity** (Stage 4): soft keyboard → XKB mapping, modifiers, and
   pointer/trackpad semantics are the hard UX problems.
3. **GL**: software-only (llvmpipe) for X clients; the *compositor* is GPU (Metal). No
   accelerated GL inside X apps yet — acceptable for now.
4. **Heavy DEs (GNOME/KDE)**: need D-Bus/`dbus-launch` (no systemd), polkit, dconf, a large
   dep tree not yet in Procursus. The GTK3 stack build is the first step; treat full DEs as
   a milestone after the per-window compositor (Stage 3/4) makes them feel acceptable.

**Decisions locked:** toolchain = extend Procursus (B1), built in a Linux container; native
app = custom DDX (no embedded-VNC interim app); fonts = point at system SF (no redistribution).
