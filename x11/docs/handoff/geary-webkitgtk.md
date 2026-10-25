# Handoff: Geary and WebKitGTK

Last checked against `repo/Packages`: 2026-10-25.

## Current state

- `libwebkit2gtk-4.1-0` and `libjavascriptcoregtk-4.1-0` **2.44.4+ios1** (plus
  `-dev`) are published. API 4.1 (GTK3, libsoup3), X11 and Wayland targets both
  enabled, JavaScriptCore on the C-loop interpreter (no JIT, no WebAssembly),
  WebGL off.
- `geary 46.0+ios1` is published with its closure: gspell, libpeas, Folks
  0.15.9, gcr-3/gck-1 3.41.1, the GOA 3.46 client library, gmime, libstemmer,
  libytnef, and `gnome-keyring 46.2+ios1` for the Secret Service. In an
  isolated GNOME slot Geary stays alive, owns `org.gnome.Geary`, and maps its
  window; gnome-keyring owns `org.freedesktop.secrets`.
- `epiphany 43.1+ios4` (GNOME Web) uses the same WebKit. `epiphany-native` is
  the Home Screen app called "Web". It renders through `wl_shm` in software,
  not `iosc_iosurface` (seen in a `WAYLAND_DEBUG=1` trace on 2026-08-02).
  Geary has no native host package; it only runs inside a GNOME session.
- Accounts: manual IMAP/SMTP is the supported path. The Linux GOA provider
  daemon and browser OAuth setup are not claimed. Our EDS build stays minimal;
  widening it for OAuth would be a separate project.

**Still open:** the small multiprocess HTML/JavaScript load test
(`linux-build/tests/webkitgtk-smoke.c`) has not been rerun against the final
Wayland-capable WebKit bytes. The iPad was offline when the 21-package wave was
published on 2026-07-30, and Max asked for the publish anyway. Run it under
GNOME before widening account support or turning on browser, media or GPU
features.

## Security

2.44 is the newest WebKitGTK line that builds here: 2.46 and later need C++23
that the iOS cctools Clang 14 misparses. Upstream no longer patches 2.44, so
every advisory since the 2.46 branch is unapplied. The depictions for
`libwebkit2gtk-4.1-0`, `geary` and `epiphany` carry a security notice saying so
(`repo/meta/<pkg>.json`, `securityNotice`). Moving off 2.44 needs a newer
compiler in the cross toolchain first.

## Root causes and gotchas

- **The GTK release tarball drops Apple-port sources** that a real Darwin
  target still selects. `linux-build/recipes/hydrate-webkit-apple-sources.sh` restores the
  narrow WTF/bmalloc set from commit
  `e4715b88387c15a3ff8b7cc7a2efbde89c484710`, and it has to run before the
  patch series is applied.
- The quilt stack adds Darwin `ProcessCheck.mm`, exports `AbortWithReasonSPI.h`
  for the GTK WTF header tree, and supplies the missing compiler-rt
  `__muloti4`.
- WebKit's generators need host Ruby headers and `unifdef`; the driver
  installs both.
- **Gigacage.** iOS cannot reserve WebKit's normal multi-gigabyte cage. The
  patch detects the iPhoneOS compiler environment directly and keeps allocation
  and assertion state consistent when the reservation fails.
- **X11-only GTK staging.** The first multiprocess run crashed in
  `PlatformDisplayX11` (no X display in a Wayland GNOME session) because the
  dependency selector had picked an unmarked X11-only GTK dev package. It now
  prefers Xios-marked revisions, and CMake reports both Wayland and X11.
- Configure flags that matter: `-DUSE_GTK4=OFF` (gives the 4.1 API Geary
  needs), `-DENABLE_QUARTZ_TARGET=OFF`, and enable the X11/Wayland targets only
  after checking the staged GTK3 `.pc` advertises those backends.
- The recipe stages its runtime and dev debs explicitly from
  `linux-build/out/` and `repo/debs`, normalizes the bootstrap `expat.pc`
  rootless prefix, and supplies `OS_OBJECT_DECL_SENDABLE_CLASS` when the SDK
  lacks it (the newer staged XPC header needs it).
- WebGL needs a separate ANGLE graphics-context and GPU-process port,
  entitlement review and real rendering tests. Geary's HTML renderer does not
  need it.

## Geary requirements (GNOME 46.0 tag)

Vala >= 0.48.18, GLib >= 2.68, GTK3 >= 3.24.24, `webkit2gtk-4.1`,
`javascriptcoregtk-4.1` and `webkit2gtk-web-extension-4.1` >= 2.30, plus gmime
3, SQLite with FTS3/FTS5, enchant-2, folks, gck-1, gcr-3, gee-0.8, goa-1.0,
gsound, gspell-1, ICU, iso-codes, json-glib, libpeas-1.0, libsecret, libsoup-3,
libstemmer, libxml2, and optionally libhandy-1, libytnef and libunwind. Geary
main raises the floor (Meson 1.7, Vala 0.56, GLib 2.74) and moves to gck-2,
gcr-4 and libpeas-2, so 46.0 is the right pin for the GNOME 46 lane.

## Build

From `x11/`:

```sh
docker run --rm --platform linux/arm64 --cpus=4 \
  -v procursus-vol-gtk:/work/Procursus \
  -v "$PWD/linux-build/target-env.sh:/work/target-env.sh:ro" \
  -v "$PWD/linux-build/build-gnome.sh:/work/build-gnome.sh:ro" \
  -v "$PWD/linux-build/recipes:/work/recipes:ro" \
  -v "$PWD/ports:/work/ports:ro" \
  -v "$PWD/linux-build/build_info:/work/build_info:ro" \
  -v "$PWD/linux-build/vapi:/work/vapi:ro" \
  -v "$PWD/linux-build/out:/out" \
  -v "$PWD/../repo/debs:/repo-debs:ro" \
  -e TARGETS="webkitgtk-jsc" \
  procursus-xbuild:bookworm-arm64 /work/build-gnome.sh
```

Other targets: `webkitgtk-configure` (configure only), `webkitgtk-wtf` (small
compile proof), `webkitgtk-package geary-package` after a completed engine
install, and `gnome-keyring-package`. Compile-only targets skip deb collection
and relinking.

## History

The first probe used WebKitGTK 2.52.4: CMake configured cleanly, then the
compile died on C++23 constructs. That is why the lane pins 2.44.4. JSC first
ran on the iPad (`print(6 * 7)` printed 42) before the GTK side was finished.
The wave was published on 2026-07-30 and the security notices were added on
2026-08-02.
