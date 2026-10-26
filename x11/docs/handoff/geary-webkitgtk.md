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

## 2026-10-25: WebKitGTK 2.54.0+ios3 device test plan

Branch `claude/webkitgtk-254` (from origin/main). Recipe `recipes/webkitgtk-modern.mk`, patch stack
`ports/webkitgtk-modern/patches` (0039 is the newest), driver `linux-build/build-webkit-modern.sh`,
volume `procursus-vol-gtk` (work dir `build_work/.../webkitgtk-modern`). Plan and port history:
`docs/webkitgtk-toolchain-plan.md`. Nothing here is published; prod still serves 2.44.4+ios1.

+ios3 is +ios2 plus patch 0039 (SQLite init deadlock). The two earlier iPad rounds found 0037
(SOCK_SEQPACKET socketpair assert in `createPlatformConnection`) and 0039; 0038 (executable path
without /proc) went in with 0037.

### What to install

Built 2026-10-25 from a full 2,790-step rebuild (the old tree's objects were all stale) at the
driver's `-j6`, peak about 3 GiB RAM, no OOM. Output is in `x11/linux-build/out-webkit-modern/` of
the `agent-abcd844133ebce204` worktree (gitignored):

```
8b2d0bcae4a3a722694733d028204fab04fa15a14c1ee62a7487f2f725c08063  libjavascriptcoregtk-4.1-0_2.54.0+ios3_iphoneos-arm64.deb    (5.2 MB)
17c492ed1743fff461101ccfd191fa073ded2035e5dad5c2f60791c57ac9f021  libjavascriptcoregtk-4.1-dev_2.54.0+ios3_iphoneos-arm64.deb  (62 KB)
8d75d9a06a60ccdea98b4576cc5b3d814f61420786fc2f864a3481de27f3223a  libwebkit2gtk-4.1-0_2.54.0+ios3_iphoneos-arm64.deb          (27 MB)
b558ea11f4cc8432c5f4f9580798f36c22abc773f4efbfdbe02c993943fb5155  libwebkit2gtk-4.1-dev_2.54.0+ios3_iphoneos-arm64.deb        (142 KB)
```

minos 16.0 on every Mach-O, and the stamp-minos
dry-run gives 16.0 for all four; the solvability gate passes on a scratch copy of `repo/Packages`
with these four stanzas swapped in.

The two `-dev` debs are only for building against it; they exact-pin the runtime, so install all
four or only the two runtimes. Then:

```sh
scp libjavascriptcoregtk-4.1-0_2.54.0+ios3_*.deb libwebkit2gtk-4.1-0_2.54.0+ios3_*.deb root@$IP:/var/jb/tmp/
ssh root@$IP 'cd /var/jb/tmp && apt install -y ./libjavascriptcoregtk-4.1-0_2.54.0+ios3_iphoneos-arm64.deb ./libwebkit2gtk-4.1-0_2.54.0+ios3_iphoneos-arm64.deb'
```

Check delivery by hash (`shasum -a 256` both ends) and record `dpkg -l | grep -E 'webkit|javascriptcore|epiphany|geary'`
before and after, so the test says which consumer bytes it ran. Keep the **published** consumers
first: `epiphany 43.1+ios4`, `epiphany-native 43.1+ios4`, `geary 46.0+ios1`. All 624 WebKit/JSC
symbols they import resolve in the 2.54 dylibs, and both dylibs keep compatibility version 0.0.0, so
no consumer rebuild should be needed. One difference to watch: 2.54's install names are
`@rpath/lib*-4.1.0.dylib`, while the 2.44-built consumers load the absolute
`/var/jb/usr/lib/lib*-4.1.0.dylib` (the same files). If anything looks like a library loaded twice
(duplicate GType registration warnings, `g_type_register_static` criticals at startup), that is the
cause, and the fix is the rebuilt consumers (`epiphany 43.1+ios5`, `geary 46.0+ios2`).

Rollback: `apt install libwebkit2gtk-4.1-0=2.44.4+ios1 libjavascriptcoregtk-4.1-0=2.44.4+ios1` from
the prod source (with the `-dev` packages too if installed).

Signing: the web process is signed with `iosc-gpu-client-ent.xml` (no `general.xml`). If a helper
dies with exit 137 and no output, or WebGL reports no GPU, re-sign on the device before blaming the
build (`host-ldid-signature-rejected` memory): `ldid -S/var/jb/tmp/iosc-gpu-client-ent.xml
/var/jb/usr/libexec/webkit2gtk-4.1/WebKitWebProcess`, same for `WebKitNetworkProcess`.

### Checks, in order

1. **JSC shell (JIT state).** This build is the C-loop interpreter: JIT, DFG, FTL and WebAssembly
   are all off at compile time, so `JSC_useJIT` and friends do nothing. Expect:
   `/var/jb/usr/libexec/webkit2gtk-4.1/jsc -e 'print(6*7)'` prints `42`, and
   `jsc -e 'typeof WebAssembly'` prints `undefined`. Record a baseline for the later JIT build:
   `jsc -e 'let t=Date.now(),s=0;for(let i=0;i<2e7;i++)s+=i%7;print(Date.now()-t)'` (ms).
2. **Process launch (0037/0038 regression).** Launch "Web" (`epiphany-native`). `WebKitWebProcess`
   and `WebKitNetworkProcess` must appear in `ps -A` and stay up; no `createPlatformConnection`
   assertion and no "could not find executable" in the app's stderr/`/var/jb/tmp` logs.
3. **SQLite deadlock (0039 regression).** This was a UI-process hang: `sqlite3_initialize()` waited on
   the main thread while the main thread waited on the favicon (IconDatabase) queue. Repro shape:
   start Web with a **fresh profile** (move `~/.local/share/epiphany` and `~/.cache/epiphany` aside),
   load a page that has a favicon (https://en.wikipedia.org), then open a second tab and a third
   page. Pass = the window keeps repainting and accepts input, the favicon appears in the tab, and
   after quitting and relaunching, History shows the visits and the favicon is still there (the
   databases were written). Fail = the window freezes within the first page load; grab
   `sample`/`lldb bt all` of the UI process if it does.
4. **Rendering.** https://example.com, a long Wikipedia article (scroll, zoom with ctrl +/-), a page
   with web fonts and SVG, and a form (type into a text field with the iOS keyboard). 2.54 is
   Skia-only; text must be crisp and scrolling must not leave stale tiles. Expect `wl_shm` buffers
   (software path, same as 2.44: accelerated compositing is still gated off, see the toolchain
   plan section 14).
5. **JavaScript.** https://html5test.co or any JS-heavy page loads; a page that uses
   `localStorage`/IndexedDB keeps data across a relaunch (IndexedDB is SQLite too, so this is the
   second half of check 3).
6. **WebGL (compiled in, never tested).** https://get.webgl.org: either a spinning cube or a clean
   "not supported". A crash of `WebKitWebProcess` here is a finding, not a blocker for the browser.
7. **Geary (inside a GNOME session, `xios-session -d gnome`; Geary has no native launcher).** Open
   Geary with the existing manual IMAP account (or the account setup dialog if none). Pass =
   message list loads, an HTML message renders in the viewer (that is the web process plus
   `libgeary-web-process.dylib`, the web extension), links are clickable, and Compose opens an
   editable body (the composer is a WebKit editor). Quit and reopen once (SQLite again).
8. **Memory.** With three tabs open in Web, note RSS of the UI and web processes (`ps -o rss,comm`).
   The A10 has 3 GB; anything that gets jetsam-killed at idle is a finding.

Report per check: pass/fail, the package versions from `dpkg -l`, and any stderr. If 1-3 pass and
4-7 show no regression against 2.44, the build is ready for the staging publish (by Max/main, not
this lane).

### Build notes (2026-10-25)

- The 2026-10-02 +ios3 attempt died in `build-gnome.sh`'s host-tool `apt-get install`. It did not
  recur: in the same image, DNS resolved and `apt-get update` fetched from deb.debian.org,
  security and apt.llvm.org in about a second. The cause cannot be recovered because that step sent
  all output to /dev/null. It now logs to `/tmp/xios-host-apt.log`, retries once, and prints the
  tail plus the container's nameserver on failure.
- Pre-existing, not new in 2.54 (the control template is shared with 2.44): `libwebkit2gtk-4.1-0`
  links `libsqlite3.1`, `libgpg-error.0`, ICU 78 and `libz.1` without naming `libsqlite3-1`,
  `libgpg-error0`, `libicu78` or `libz1` in Depends. Epiphany and Geary pull those in, so it only
  bites a bare install of the library. The only new link in 2.54 is `libwebpmux.3` (already in
  Depends) and the system `/usr/lib/libexpat.1.dylib`.
