# Build / sign / package scripts

The x11 tree has ~100 shell scripts. The repeated primitives — ldid signing,
`dpkg-deb` packaging, and extracting dev debs into a cross sysroot — now live in
one sourced library, `x11/lib/xlib.sh`, so callers stop hand-rolling (and
diverging on) them.

## Using the library

Source it with the walk-up idiom (works from any directory depth, host or
container):

```sh
_x="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"          # after this, $XLIB_ROOT is the x11 dir
```

### `xsign <bin> [entitlements] [required-marker...]`
ldid-signs `<bin>` (with an entitlements plist, or ad-hoc without one) and then
asserts every `required-marker` shows up in `ldid -e` — the verification the ~28
inline `ldid -S` sites lacked. Fails loud so `set -e` aborts. Prints only to
stderr (safe to call anywhere).

### `xmkdeb <staging_dir> <out_dir> [--minos]`
Assembles a root-owned, zstd `.deb` named from `DEBIAN/control`
(`<Package>_<Version>_<Architecture>.deb`) into `<out_dir>`, and echoes its path
(so `deb=$(xmkdeb ...)`). Builds directly when running as root inside the
container, else shells out to the cross-build image for the `chown 0:0` +
`dpkg-deb` (a macOS host has no `dpkg-deb`). Stamps MinimumOSVersion only with
`--minos` (the catalog otherwise stamps in one final `tools/stamp-minos.py` sweep,
done last because concurrent builds churn `out/`).

### `xdeb_extract <sysroot> "<deb-dir-list>" <pkg-stem>...`  /  `xdeb_find`
Extracts each dev deb (first dir in the space-separated list that has it wins)
into `<sysroot>`, failing loud and naming where it looked. This is the
"linux-build/out then repo/debs fallback" pattern `build-iosc.sh` uses.

## The DER-signing nuance (do not get this wrong when migrating)

The **host (Homebrew) ldid emits DER-encoded entitlements**; the **in-container
ldid does not**. iOS 15+/16 AMFI needs DER for IOKit/IOSurface/task_for_pid, so a
binary signed *inside* the container is provisional and must be re-signed on the
host (see `run.sh` re-signing Xios, and `build-iosc.sh` host-signing iosc).

When converting a site to `xsign`:
- **Host-side** signer (runs on the Mac) → real `xsign` with the entitlement set +
  markers. This is the win.
- **In-container** `ldid` → `xsign` still helps (adds marker-presence checks), but
  the host DER re-sign must still happen; don't delete it.
- **On-device** `ldid` over ssh (e.g. `gen-launchers.sh --deploy`) is a third
  context — that is the device's ldid, not `xsign`; leave it.

## Migration status

Converted + verified (each passes `bash -n`; the three references were run
end-to-end):

- Reference: `wayland/sign-iosc.sh`, `wayland/build-iosc.sh` (xdeb_extract + host
  xsign), `wayland/package-iosc.sh` (xsign + xmkdeb).
- Host-side signing → `xsign`: `apps/iosc-desktop/build-stub.sh`,
  `apps/iosc-desktop/gen-launchers.sh` (bundle binaries only; the `--deploy`
  on-device ldid stays), `apps/iosc-host/build-host.sh`,
  `apps/iosc-shell/build-panel.sh`, `apps/iosc-shell/package-shell.sh`,
  `ports/angle/package-angle-es3.sh`, `linux-build/run.sh` (host Xios re-sign),
  `linux-build/build-opentui-ios.sh`.
- Host-side packaging → `xmkdeb`: `apps/iosc-desktop/package-session.sh`,
  `apps/iosc-shell/package-shell.sh`, `packages/xios-fhs/package-fhs.sh`,
  `packages/xios-session-stubs/build.sh`, `packages/meta/build-meta.sh`.

### Intentionally NOT converted (with reasons — do not "fix" these blindly)

- **In-container build scripts** (`build.sh`, `build-gtk/kwin/mutter/qt/qt-modules/
  xwayland.sh`, `build-audio.sh`, `build-bun.sh`, `build-cogl-smoke.sh`,
  `build-gjs-manual.sh`, `build-qt-wayland-gl-smoke.sh`,
  `packages/xios-fhs/build-hwbridge.sh`, `recipes/relink-gtkintl.sh`,
  `wayland/build-session-stubs.sh`, `wayland/build-xios-glue.sh`, ...): their
  `ldid`/`dpkg-deb` run *inside* the container, where `x11/lib` is not mounted, so
  `xlib.sh` cannot be sourced. Their `docker run` mounts would each need
  `x11/lib` added before they could use the helpers — a separate, deliberate step.
  (Their in-container `ldid` is also DER-less; the real sign is the host re-sign,
  which IS converted.)
- **On-device / sh-only helpers** (`gir-ondevice.sh`, `gi-package.sh`,
  `wayland/run-gnome-shell.sh`, `wayland/run-mutter.sh`, `run-*` deploy blocks):
  the `ldid` runs on the device over ssh, or the script is `#!/bin/sh` (xlib.sh
  needs bash `BASH_SOURCE`).
- **`build-opencode.sh`**: packages with `dpkg-deb -Zxz` under `LC_ALL=C`/`TZ=UTC`
  for byte-reproducible output; `xmkdeb` uses `-Zzstd` + the procursus image, which
  would change the bytes. Left on purpose.
- **`ports/angle/package-angle-es3.sh` packaging**: deliberately uses
  `debian:bookworm-slim` for `dpkg-deb` (documented host-bash workaround);
  `xmkdeb` assumes the procursus image's bash entrypoint. Its signing IS converted.
- **`packages/xios-desktop-theme/build.sh`**: `dpkg-deb` is inside a bespoke
  in-container step that also generates the wallpaper — a restructure, not a swap.

### Notes

- The publish-time `finalize_x11_graphics_debs` step in `bin/publish-dev-repo.sh`
  references `X11/linux-build/resign-graphics-packages.py`, which does **not exist**
  in the tree — so that step is currently inert (its `[ -x "$signer" ] || return 0`
  guard returns early). It is not a live signing path. The `X11/` (vs `x11/`) case
  in that reference is also a latent non-macOS portability trap.
- To extend unification into the container, add `x11/lib` to the relevant
  `docker run -v` mounts, then the in-container scripts can source `xlib.sh` too.

## Version marking (`+iosN`)

Every upstream package we rebuild for iOS carries a build marker appended to its
deb version — the house style is `+ios1` (older tracks used `+wl1`, `+angle1`,
`+rootless1`, `+xios1`, `+es3-3`; all equivalent in intent). This makes our deb
unambiguously *our* build and sorts it above a same-named upstream deb
(`2.52.0+ios1` > `2.52.0` and > `2.52.0-3` upstream revision). Our own originals
(`iosc`, `iosc-shell`, `xios-*`, `com.max.*`, `libgtkintl`, `bun-preflight`,
`x11-fonts-sf`, `qt-wayland-gl-smoke`) keep their own versions and are **not**
marked.

Where it lives:
- **In recipes** (the source of truth): on the deb-version seam
  `DEB_<PKG>_V ?= $(<PKG>_VERSION)+ios1`. Never append to the upstream
  `<PKG>_VERSION` var itself — that drives the source-tarball URL/dir and would
  break the download. Revision-suffixed recipes keep the revision first
  (`$(QTBASE_VERSION)-3+ios1`). `xmkdeb` reads the resulting version straight
  from `DEBIAN/control`, so a rebuilt deb inherits the marker automatically.
- **In the shipped debs**: the ~300 already-published debs were back-filled once
  by a repack that re-tars each archive with the new `Version:` and renames the
  file. The payload (every Mach-O and its DER code signature) is byte-identical
  across the repack — only the deb wrapper and `DEBIAN/control` change — so
  signatures survive untouched. Dependency resolution is unaffected: the repo has
  zero `(= x)` / `(>= x)` version pins, and the `xios-*` metas depend on bare
  names.

When adding a new upstream port, set `DEB_<PKG>_V ?= $(<PKG>_VERSION)+ios1` in its
recipe and it ships marked from the first build — no repack needed.

Always **skip files with uncommitted changes** (concurrent edits); migrate a dirty
script the next time it is touched rather than sweeping it.
