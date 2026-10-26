# Geary / WebKitGTK feasibility

Status as of 2026-07-30: WebKitGTK 2.44.4 builds, installs, and splits into
rootless iOS JavaScriptCoreGTK/WebKitGTK runtime and development packages.
JavaScriptCore executes on the iPad with the no-JIT C-loop interpreter. The
iOS Gigacage fallback permits the large virtual reservation to fail instead of
aborting. The GTK3 backend is configured for both X11 and Wayland; an earlier
staging bug selected an unmarked X11-only GTK development package and was fixed
by preferring Xios-marked dependency revisions.

Geary 46.0 and its dependency closure also build and package. The new gspell,
libpeas, Folks, gcr-3/gck-1, GOA client, WebKitGTK, JavaScriptCoreGTK, and
gnome-keyring runtimes load on the iPad. In an isolated GNOME slot, the
Secret Service owns `org.freedesktop.secrets`; Geary stays alive, owns
`org.gnome.Geary`, and exports its GTK window. The credible iOS account path is
manual IMAP/SMTP. The Linux GOA provider daemon and browser-backed OAuth setup
are deliberately not claimed.

The exact 21-package Geary/app wave was published to
`https://repo.maxleiter.com` on 2026-07-30. The production index, signatures,
and every package payload were independently fetched after deployment. The
remaining runtime gate is the small `linux-build/tests/webkitgtk-smoke.c`
multiprocess load test against the rebuilt Wayland-capable WebKit package. That
test could not be repeated before promotion because the iPad was offline; the
production publish was explicitly requested with that limitation understood.

## Decision

Keep the published manual-IMAP/SMTP lane as the baseline. Repeat the Wayland
WebKit process smoke when the iPad is reachable before widening account
integrations or browser/media/GPU features.

Geary hard-requires WebKitGTK's GTK3/libsoup3 API (`webkit2gtk-4.1`,
`javascriptcoregtk-4.1`, and `webkit2gtk-web-extension-4.1`) and builds a
WebKit web-process extension. Those headers, `.pc` files, libraries, helper
processes, and the Geary web extension are now packaged.

## Local dependency inventory

Already present or partially present in this tree:

- GTK3: `linux-build/recipes/gtk+3.0.mk`; recently rebuilt with X11 + Wayland
  backend according to `docs/handoff/wayland-apps.md`.
- GTK4/libadwaita: `linux-build/recipes/gtk4.mk`,
  `linux-build/recipes/libadwaita.mk`.
- libsoup3: `linux-build/recipes/libsoup3.mk`,
  `linux-build/build_info/libsoup-3.0-*.control`.
- EDS: `linux-build/recipes/evolution-data-server.mk`, but it is currently cut
  down for GNOME Shell calendar use: GOA, GTK prompt UI, WebKitGTK OAuth prompts,
  introspection, and Vala bindings are disabled.
- gcr 4: `linux-build/recipes/gcr.mk`, built without GTK4 UI and without
  introspection/vapi.
- libsecret, libgee, libical, iso-codes, enchant, appstream, json-glib, libxml2,
  libpsl exist locally.
- GMime, libstemmer, and libytnef: recipes/controls were added and these debs
  were built into `linux-build/out/`:
  `libgmime-3.0-0_3.2.7+ios1_iphoneos-arm64.deb`,
  `libgmime-3.0-dev_3.2.7+ios1_iphoneos-arm64.deb`,
  `libstemmer0d_2.2.0+ios1_iphoneos-arm64.deb`,
  `libstemmer-dev_2.2.0+ios1_iphoneos-arm64.deb`,
  `libytnef0_2.1.2+ios1_iphoneos-arm64.deb`, and
  `libytnef-dev_2.1.2+ios1_iphoneos-arm64.deb`.
- gspell and libpeas: fresh runtime/dev debs were produced on 2026-07-19.
  Their arm64 dylibs, signatures, pkg-config versions, load commands, and repo
  dependency closure passed host validation. `gspell` now links ICU 78.3;
  `libpeas` stages the published libgirepository 1.78 packages rather than
  rebuilding the unrelated target-Python/GI toolchain. Both runtimes load on
  the iPad.

Completed for Geary/WebKitGTK:

- WebCore and WebKit compile and install; `webkit2gtk-4.1`,
  `javascriptcoregtk-4.1`, and `webkit2gtk-web-extension-4.1` runtime/dev
  payloads are present in the split packages.
- Folks 0.15.9, gcr-3/gck-1 3.41.1, and the GOA 3.46 client API are packaged
  and device-loaded. The Geary recipe supplies the Vala binding surface needed
  for this cross build.
- `gnome-keyring 46.2+ios1` supplies the Secret Service runtime Geary requires.
  PAM, SSH agent, systemd, Linux capabilities, and SELinux integrations are
  disabled for the single-user iOS session.

## Upstream Geary requirements

Primary upstream references:

- Stable GNOME 46 tag:
  <https://gitlab.gnome.org/GNOME/geary/-/raw/46.0/meson.build>
- Current main branch:
  <https://gitlab.gnome.org/GNOME/geary/-/raw/main/meson.build>
- Flatpak manifest:
  <https://gitlab.gnome.org/GNOME/geary/-/raw/main/org.gnome.Geary.json>

The GNOME 46.0 tag requires:

- Vala >= 0.48.18, GLib >= 2.68, GTK3 >= 3.24.24.
- `webkit2gtk-4.1`, `javascriptcoregtk-4.1`, and
  `webkit2gtk-web-extension-4.1` >= 2.30.
- `gmime-3.0`, SQLite with FTS3 tokenizer + FTS5, `enchant-2`, `folks`,
  `gck-1`, `gcr-3`, `gee-0.8`, `goa-1.0`, `gsound`, `gspell-1`, ICU,
  `iso-codes`, `json-glib-1.0`, optional `libhandy-1`, `libpeas-1.0`,
  `libsecret-1`, `libsoup-3.0`, `libstemmer`, `libxml-2.0`, optional
  `libytnef`, and optional libunwind.

Current main keeps the same GTK3 + WebKitGTK 4.1 shape, but raises the build
floor and moves some deps:

- Meson >= 1.7, Vala >= 0.56, GLib >= 2.74.
- `gck-2`, `gcr-4`, `libpeas-2`, and `libhandy-1 >= 1.6`.

For the current Xios GNOME-46 package lane, `46.0` is the more coherent starting
point, but it means the repo needs gcr-3/gck-1 and libpeas-1.0 in addition to
the already-started gcr-4 direction.

## WebKitGTK requirements and blockers

Primary upstream references:

- Selected WebKitGTK 2.44.4 GTK port CMake options:
  <https://raw.githubusercontent.com/WebKit/WebKit/webkitgtk-2.44.4/Source/cmake/OptionsGTK.cmake>
- Newer WebKitGTK 2.52.4 options used for the initial dependency/configure
  audit:
  <https://raw.githubusercontent.com/WebKit/WebKit/webkitgtk-2.52.4/Source/cmake/OptionsGTK.cmake>

The first probe used 2.52.4 and reached a clean CMake configure, but compilation
failed immediately on C++23 constructs that the current iOS cctools Clang 14
misparses. WebKitGTK 2.46 and newer require C++23. Geary 46 only requires API
4.1 >= 2.30, so this lane pins 2.44.4, the newest C++20 release line. A newer
WebKit must wait for a separate compiler/toolchain upgrade.

For Geary, build WebKitGTK with GTK3 API 4.1, not GTK4 API 6.0:

- `-DUSE_GTK4=OFF` makes WebKitGTK install `webkit2gtk-4.1`,
  `javascriptcoregtk-4.1`, and `webkit2gtk-web-extension-4.1`.
- Leave `-DENABLE_X11_TARGET=ON` and/or `-DENABLE_WAYLAND_TARGET=ON` only after
  confirming the staged GTK3 `.pc` advertises those backends.
- Set `-DENABLE_QUARTZ_TARGET=OFF`; Xios uses GTK's X11/Wayland backends, not
  native Quartz.

The recipe stages the required runtime and development debs explicitly from
`linux-build/out/` and the top-level repo. This includes GLib/GTK3, Cairo,
libgcrypt, libsoup3, libtasn1, HarfBuzz + ICU, ICU, JPEG, libepoxy, libxml2,
PNG, SQLite, zlib, WebP, AT-SPI, Fontconfig/FreeType, libxslt, libsecret, and
Wayland. It normalizes the bootstrap `expat.pc` rootless prefix and supplies a
compatibility definition for the newer staged XPC header when the SDK lacks
`OS_OBJECT_DECL_SENDABLE_CLASS`.

Default WebKitGTK features would drag in a much larger graph: GStreamer media,
libmanette, libsecret, gobject-introspection/gi-docgen docs, libdrm/GBM,
Flite/Spiel, Enchant, X11/Wayland protocol deps, JPEG-XL, hyphen, WOFF2, AVIF,
LCMS2, libbacktrace, WebDriver, and journald/logging. A first Geary-oriented
build should aggressively disable browser/media/test/doc features unless Geary
actually needs them:

- likely off for first pass: documentation, introspection if VAPIs are vendored,
  WebDriver, Minibrowser, gamepad, speech synthesis, video/media stream/WebRTC,
  web audio, web codecs, AVIF, JPEG-XL, WOFF2, LCMS, journald, libbacktrace,
  PDFJS, bubblewrap sandbox, Vulkan, GBM/libdrm if the non-accelerated path is
  acceptable.
- keep or verify carefully: spellcheck may be useful but can be disabled
  independently of Geary's own `gspell`; libsecret is useful for credentials;
  JavaScriptCore and web extensions are non-negotiable.

WebGL is intentionally off in this package revision. Enabling it credibly on
iOS requires a separate ANGLE/graphics-context and WebKit GPU-process port,
entitlement review, accelerated compositing validation, and physical rendering
tests. It is not required by Geary's HTML message renderer. Ordinary HTML, CSS,
DOM, and JavaScript remain enabled.

Porting results and remaining blockers:

- WebKit's GTK release tarball prunes Apple-port sources that a real Darwin
  target still selects. `hydrate-webkit-apple-sources.sh` restores the narrow
  WTF/bmalloc set from immutable commit
  `e4715b88387c15a3ff8b7cc7a2efbde89c484710` before CMake.
- The quilt stack adds Darwin `ProcessCheck.mm`, exports
  `AbortWithReasonSPI.h` for the GTK WTF header tree, and supplies the missing
  compiler-rt `__muloti4` operation. These patches apply cleanly to a fresh
  2.44.4 source extraction.
- Host Ruby headers and `unifdef` are required by WebKit's generators. The
  driver installs both. The LLInt settings/offset extractors compile and link
  successfully in this cross configuration.
- JavaScriptCore deliberately uses `ENABLE_JIT=OFF`, all higher JIT tiers off,
  WebAssembly off, and `ENABLE_C_LOOP=ON`. The packaged `jsc` shell executes
  `print(6 * 7)` as `42` on the iPad without a runtime override.
- iOS cannot reserve WebKit's normal multi-gigabyte Gigacage address space. The
  patch stack detects the iPhoneOS compiler environment directly and keeps both
  allocation and assertion state consistent when the reservation fails.
- The first multiprocess smoke exposed an X11-only GTK staging error:
  `PlatformDisplayX11` dereferenced a missing X display in a Wayland GNOME
  session. The configure dependency selector now prefers marked Xios revisions,
  and the final CMake summary enables both Wayland and X11.
- Geary carries the required WebKit extension and its private libraries now use
  rootless runtime paths. A real Secret Service is provided by gnome-keyring.
- The repo's EDS build remains intentionally minimal. OAuth/provider integration
  would require a separate widening of EDS/GOA and is not part of the manual
  IMAP/SMTP package lane.

## Staged path

1. Completed: build/package/device-load the leaf mail dependencies, including
   gspell/libpeas, Folks, gcr-3/gck-1, and the GOA client API.
2. Completed: build/install/package WebKitGTK 2.44.4 API 4.1 and execute
   JavaScriptCore on-device.
3. Completed: build/package Geary 46.0 and gnome-keyring; verify the Secret
   Service and mapped Geary window in an isolated GNOME slot.
4. Completed host-side: rebuild and repackage WebKit with both Wayland and X11
   enabled. Pending device proof: pass the multiprocess HTML/JavaScript smoke
   under GNOME with these final bytes.
5. Completed 2026-07-30: publish the exact 21-package wave to production and
   independently fetch all package stanzas and payloads. Treat OAuth/provider
   support and WebGL as separate revisions with their own runtime proof.

## Build commands

Validated WebKit configure/engine command from the repository root:

```sh
cd /Users/max/Documents/jailbreak/x11
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

Use `TARGETS="webkitgtk-configure"` for configure only,
`TARGETS="webkitgtk-wtf"` for the smaller core compile proof, or
`TARGETS="webkitgtk-package geary-package"` after a completed engine install.
Compile-only targets skip deb collection/relinking. The build driver also
supports `gnome-keyring-package` for Geary's Secret Service runtime.

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
