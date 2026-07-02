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

Converted + verified end-to-end: `wayland/sign-iosc.sh`, `wayland/build-iosc.sh`
(xdeb_extract + host xsign), `wayland/package-iosc.sh` (xsign + xmkdeb).

Remaining `ldid`/`dpkg-deb` sites are being migrated in waves. **Skip files with
uncommitted changes** (they are under concurrent edit); migrate a script the next
time it is touched rather than sweeping a dirty file.
