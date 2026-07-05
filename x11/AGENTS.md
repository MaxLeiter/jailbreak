# Agent Notes for X11 / Xios

This directory contains the native X11/Wayland-on-iOS stack. Keep this file stable: use it for architecture, workflows, and invariants. Use `docs/handoff/` for current state and task-specific status.

## Before Editing

- Expect many generated files and local build outputs. Do not clean, revert, or delete unrelated files.
- Read the closest README or design doc before changing a subsystem.
- Prefer existing scripts over one-off command sequences; many scripts encode device, signing, rootless, or Procursus details.
- For current coordination status, start with `docs/handoff/INDEX.md`, then the domain file it points to.

## Directory Map

- `apps/Xios/`: iOS app that presents IOSurfaces with Metal and forwards UIKit input.
- `apps/iosc-host/`: native iPadOS host app track for presenting compositor output and app-side integration.
- `apps/iosc-desktop/`: session launcher, launch daemons, launcher generation, and device deployment helpers.
- `apps/iosc-shell/`: lightweight iosc shell pieces: panel, dock, overview, wallpaper, and preview/build scripts.
- `linux-build/`: Docker/Procursus cross-build pipeline for rootless iOS packages and native binaries.
- `wayland/`: `iosc` compositor, Wayland/iOS glue, test clients, session stubs, and runtime scripts.
- `packages/`: local package skeletons and packaging helpers for Xios desktop support packages.
- `docs/`: plans, handoffs, specs, and subsystem notes.

## Architecture Invariants

- The target install prefix is rootless `/var/jb`; packages and scripts should not assume rootful `/`.
- Native display output is passed to iOS as `IOSurface`s and presented by the app with Metal.
- Geometry is not globally constant. Read compositor/app-reported dimensions such as `/var/jb/tmp/xios.json` instead of hardcoding framebuffer sizes.
- `iosc` and the app communicate through small local protocols/sockets. Wire changes often require coordinated app and compositor deploys.
- GPU/IOSurface work depends on narrow entitlements. Do not broaden or swap entitlement sets casually; broad sandbox/container entitlements can break IOKit/GPU access.

## Build Workflows

- Build the core Procursus/X stack with `bash x11/linux-build/run.sh` from the repo root.
- Use the specialized `x11/linux-build/build-*.sh` scripts for GTK, Wayland, Qt, KDE, GNOME, audio, and related stacks rather than invoking Procursus targets ad hoc.
- Use Docker/Procursus named volumes as the build cache. Do not prune volumes during active or uncertain builds.
- Generated outputs usually land in `x11/linux-build/out/` or `x11/wayland/out/`; treat them as build artifacts unless a task explicitly asks to package/publish them.
- Recipe edits generally belong in `x11/linux-build/recipes/` or the generator that owns them, not directly inside a transient Procursus worktree.
- Reuse the shared script helpers in `x11/lib/xlib.sh` (`xsign`, `xmkdeb`, `xdeb_extract`) instead of hand-rolling `ldid`/`dpkg-deb`/deb-extraction. See `x11/docs/scripts.md` for the API and the host-vs-container DER-signing nuance.

## Device Deploy Workflows

- `device.env` at the repo root is the local, gitignored source for SSH device settings used by deployment helpers.
- Install/update the session daemon with `x11/apps/iosc-desktop/install-xios-session.sh`.
- Install/update `ioscd` with `x11/apps/iosc-desktop/install-ioscd.sh`.
- For packageable session artifacts, prefer `x11/apps/iosc-desktop/package-session.sh` over scp-only iteration.
- When deploying app bundles manually, preserve executable bits and re-sign after copying; `scp -r` can drop metadata and can nest bundles into existing destinations.
- Sign host-side binaries through `xsign` (from `x11/lib/xlib.sh`) so the entitlement markers are verified after signing; remember only the Mac `ldid` emits DER entitlements (the in-container `ldid` does not), so container-built binaries still need a host re-sign.

## Runtime / Verification

- Use the run scripts in `x11/wayland/` (`run-iosc.sh`, `run-mutter.sh`, `run-xwayland.sh`, etc.) and the packaged session launchers rather than reconstructing environment variables by hand.
- Session selection is mediated by the session launcher/daemon; prefer `xios-session ...` flows where available.
- On-device verification matters. Host syntax checks are useful but do not prove UIKit, IOSurface, Metal, launchd, or package-manager behavior.
- If a compositor or app restart behaves strangely, check for stale sockets, zombie surfaces, launchd state, and foreground/screen-awake requirements before changing code.

## Packaging and Publishing

- Build/package locally under `x11/`, then copy final `.deb`s into top-level `repo/debs/` only when they are meant to be published. Prefer `xmkdeb` (from `x11/lib/xlib.sh`) to assemble root-owned zstd debs named from `DEBIAN/control` rather than a bespoke `docker run … dpkg-deb`.
- Production repo publishing follows the root `AGENTS.md` rule: never replace public `.deb` bytes at the same filename.
- Metadata and depictions are generated by the top-level repo tooling; do not hand-edit generated files as the normal path.
- **Version marking**: every upstream package we rebuild for iOS carries an `+iosN` (or `+wl1`/`+angle1`/`+rootless1`/`+xios1`) marker appended to its deb version, so it is unambiguously our build and sorts above a same-named upstream deb. Our own originals (`iosc`, `iosc-shell`, `xios-*`, `com.max.*`, `libgtkintl`, `bun-preflight`, `x11-fonts-sf`) keep their own versions and are NOT marked. In Procursus recipes the marker lives on the deb-version seam (`DEB_<PKG>_V ?= $(<PKG>_VERSION)+ios1`), never on the upstream `<PKG>_VERSION` var (which drives the source-tarball URL). See `docs/scripts.md` for the convention and the one-time repack that back-filled the shipped debs.

## Where to Look for Current Context

- `README.md`: high-level architecture and stable path map.
- `SCOPE.md`: roadmap and historical rationale. Some status may be older; verify against handoff docs and code.
- `docs/handoff/INDEX.md`: current domain map and cross-cutting gotchas.
- `docs/handoff/*.md`: active handoff notes by subsystem.
- `linux-build/README.md`: stable build-pipeline runbook.
