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

The final gate before publication is the rebuilt Wayland-capable WebKit package
and the small `linux-build/tests/webkitgtk-smoke.c` multiprocess load test.

## Decision

Finish the Wayland WebKit process smoke and publish this Geary-focused lane
before widening account integrations or browser/media/GPU features.

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
4. Current: finish the Wayland-capable WebKit rebuild, repackage, and pass the
   multiprocess HTML/JavaScript smoke under GNOME.
5. Next: publish the exact tested debs. Treat OAuth/provider support and WebGL
   as separate revisions with their own runtime proof.

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
