# gtk4-typelibs — on-device GObject-Introspection (the last GNOME boot gate)

## Ownership
Producing the GIR typelibs GNOME Shell + gjs need, by running g-ir-scanner ON THE iPad (Procursus native toolchain — NOT qemu; that was Blocker #2, solved). This is the last prep before GNOME Shell can boot (see gnome-session.md).

## Key files / approach
- On-device scanner scripts: `x11/apps/*/gir-build-*-ondevice.sh` (each lib scanned via its own meson/build using the native toolchain). Trick: harvest the exact g-ir-scanner command lines via an off-device introspection config, then run them on-device.
- The 5-script closure-FIRST batch:
  1. `gir-build-shell-closure-ondevice.sh <gsettings-desktop-schemas tar>`
  2. `gir-build-mutter-ondevice.sh`
  3. `gir-build-gnome-shell-ondevice.sh <gnome-shell tar>`
  4. `gir-build-accountsservice-ondevice.sh <tar>`
  5. `gir-build-session-libs-ondevice.sh`
- The 15 GIR -dev debs (libmutter-14-dev, libgjs-dev, libaccountsservice-dev, libgdm-dev, libupower-glib-dev, libgeocode-glib-2-dev, libgweather-4-dev, libgeoclue-dev, libatk1.0-dev, at-spi2-core-dev, gcr4-dev, polkit-dev, libibus-dev, libgnome-desktop-dev, p11-kit-1-dev) were `dpkg -i`'d for the headers. Scans only need the unpacked headers/.pc, not full config.

## Current state — UNKNOWN, needs a status check
- The -dev debs were installed. The 5 gir scripts were handed off to run. The agent then went idle ~4h with no container — so the gir batch may have finished, partially finished, or stalled. **FIRST ACTION: check whether the typelibs are scanned + installed** (look for the .typelib files on-device / the script logs), report per-namespace pass/fail.

## Open items
1. **Confirm/finish the 5-script gir batch** (closure-first order above). Runs on-device (CPU/build only — does NOT disturb the live iosc desktop). Report per-namespace pass/fail.
2. If a scan fails on a missing -dev header → name the exact deb (team-lead/build owner can supply it).
3. When all typelibs are in → hand to gnome-session for Phase 3 (run-gnome-shell.sh).

## Prior gotchas (from the introspection track)
- mozjs-115-dev deb was dangling symlinks + no .pc (synthesized). ibus compose-table needs a host tool; glib-compile-resources was a cross wall (solved by scanning on-device). gtk4 typelibs (Gtk-4.0/Gdk/Gsk/Pango) already scanned natively via each lib's meson (gir-build-ondevice.sh) — a gjs GTK4 window renders under Xvfb.

## Verify
Device is free for gir (CPU/build only). SSH per INDEX.md.
