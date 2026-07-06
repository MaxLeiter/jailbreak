# Geary / WebKitGTK feasibility

Status as of 2026-07-06: no Geary or WebKitGTK recipe has been added. A first
Geary package is not credible until the WebKitGTK 4.1 stack and several mail app
deps exist. This note is the handoff for that dependency lane.

## Decision

Do not add a Geary recipe skeleton yet.

Geary is not blocked by a small missing app dependency. It hard-requires
WebKitGTK's GTK3/libsoup3 API (`webkit2gtk-4.1`, `javascriptcoregtk-4.1`, and
the `webkit2gtk-web-extension-4.1` development interface) and builds a WebKit
web-process extension. The current repo has no `webkitgtk` recipe/build_info
and no matching runtime/dev packages, so a Geary recipe would fail at Meson
configure before exercising any useful Geary-specific code.

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

Missing for Geary/WebKitGTK:

- `webkitgtk` / `webkit2gtk-4.1` runtime, dev files, JavaScriptCoreGTK, and the
  web-extension development `.pc`/headers.
- Geary app deps: `gmime-3.0`, `folks`, `gnome-online-accounts`, `gspell-1`,
  `gsound`, `libpeas` (1.0 for Geary 46.0, 2.x on current main), `libstemmer`,
  `libytnef` if TNEF stays enabled, `sound-theme-freedesktop`, and probably
  `appstream-glib` if targeting the 46.0 tag.
- Vala binding coverage. Geary only vendors `icu-uc.vapi` and `libstemmer.vapi`;
  the rest of the `.vapi` surface must come from packages or the local vendored
  `linux-build/vapi` mechanism.

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

Primary upstream reference:

- WebKitGTK 2.52.4 GTK port CMake options:
  <https://raw.githubusercontent.com/WebKit/WebKit/webkitgtk-2.52.4/Source/cmake/OptionsGTK.cmake>

For Geary, build WebKitGTK with GTK3 API 4.1, not GTK4 API 6.0:

- `-DUSE_GTK4=OFF` makes WebKitGTK install `webkit2gtk-4.1`,
  `javascriptcoregtk-4.1`, and `webkit2gtk-web-extension-4.1`.
- Leave `-DENABLE_X11_TARGET=ON` and/or `-DENABLE_WAYLAND_TARGET=ON` only after
  confirming the staged GTK3 `.pc` advertises those backends.
- Set `-DENABLE_QUARTZ_TARGET=OFF`; Xios uses GTK's X11/Wayland backends, not
  native Quartz.

Minimum hard deps from upstream 2.52.4 include GLib 2.70, Cairo 1.16, libgcrypt,
libsoup3, libtasn1, HarfBuzz with ICU, ICU 70.1, JPEG, libepoxy, libxml2, PNG,
SQLite, zlib, WebP demux, and AT-SPI. Many are already available in the base
stack, but package/control coverage needs auditing before a recipe lands.

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

Likely porting blockers:

- WebKit is a very large C++/CMake build with code generators and cross-probes;
  expect target executables that upstream assumes it can run unless preseeded or
  replaced with host tools.
- JavaScriptCore on iOS needs a deliberate no-JIT/interpreter configuration and
  signing review. Do not assume desktop JIT behavior works under rootless iOS.
- WebKitGTK's process model will need on-device validation for `fork`/`exec`,
  subprocess paths under `/var/jb`, sandbox-off behavior, DBus/GIO expectations,
  and entitlements.
- If introspection is disabled, Geary still needs Vala bindings for the WebKitGTK
  API. If introspection is enabled to generate them, that reopens the GI
  cross-build/on-device scan problem.
- The repo's EDS build is intentionally minimal. Geary wants a mail-account
  ecosystem: GOA, EDS Vala bindings/introspection, and WebKitGTK-backed OAuth
  prompts may need a second EDS flavor or a carefully widened EDS package.

## Staged path

1. Add leaf/app deps before WebKitGTK where cheap: `gmime`, `libstemmer`,
   `libytnef`, `gspell`, `gsound`, `folks`, `gnome-online-accounts`, and
   `libpeas` in the version family chosen for Geary.
2. Add `webkitgtk.mk` only as a configure-only first milestone. Target
   WebKitGTK 2.52.x, API 4.1, docs/tests/media-heavy features off. Split runtime
   packages from the start: `libjavascriptcoregtk-4.1-0`,
   `libwebkit2gtk-4.1-0`, and matching `-dev` packages that expose the
   `webkit2gtk-web-extension-4.1` build interface.
3. Get JavaScriptCore/WebKitGTK to configure and compile off-device. Do not move
   to Geary until the installed `.pc` files and VAPIs exist.
4. Revisit EDS/GOA for mail-account setup and OAuth. Decide whether to widen the
   current EDS recipe or create a documented second-stage EDS rebuild.
5. Add `geary.mk` only after WebKitGTK 4.1 and the missing mail deps can satisfy
   Meson configure. Start with `-Dprofile=release`, `-Dtnef=false` if libytnef is
   not ready, and tests/docs off.

## Next commands

No long build should be run from this handoff.

Useful short inventory/probe commands before writing recipes:

```sh
rg --files linux-build/recipes linux-build/build_info | rg '(webkit|geary|gmime|folks|goa|gspell|gsound|libpeas|stemmer|ytnef)'
curl -LfsS https://gitlab.gnome.org/GNOME/geary/-/raw/46.0/meson.build | rg "dependency\\(|target_"
curl -LfsS https://raw.githubusercontent.com/WebKit/WebKit/webkitgtk-2.52.4/Source/cmake/OptionsGTK.cmake | rg "find_package\\(|WEBKIT_OPTION_DEFAULT_PORT_VALUE|USE_GTK4|WEBKITGTK_API_VERSION"
```

After a `webkitgtk.mk` recipe exists, the first build command should be a
configure/setup target, not a package build:

```sh
cd /Users/max/Documents/jailbreak/x11/linux-build
docker run --rm --platform linux/arm64 --cpus=2 \
  -v procursus-vol-gtk:/work/Procursus \
  -v "$PWD/build-gnome.sh:/work/build-gnome.sh:ro" \
  -v "$PWD/recipes:/work/recipes:ro" \
  -v "$PWD/../ports:/work/ports:ro" \
  -v "$PWD/build_info:/work/build_info:ro" \
  -v "$PWD/vapi:/work/vapi:ro" \
  -v "$PWD/out:/out" \
  -e TARGETS="webkitgtk-setup" \
  procursus-xbuild:bookworm-arm64 /work/build-gnome.sh
```

Only after `webkitgtk-setup` configures cleanly should a WebKit owner try:

```sh
cd /Users/max/Documents/jailbreak/x11/linux-build
docker run --rm --platform linux/arm64 --cpus=2 \
  -v procursus-vol-gtk:/work/Procursus \
  -v "$PWD/build-gnome.sh:/work/build-gnome.sh:ro" \
  -v "$PWD/recipes:/work/recipes:ro" \
  -v "$PWD/../ports:/work/ports:ro" \
  -v "$PWD/build_info:/work/build_info:ro" \
  -v "$PWD/vapi:/work/vapi:ro" \
  -v "$PWD/out:/out" \
  -e TARGETS="webkitgtk-package" \
  procursus-xbuild:bookworm-arm64 /work/build-gnome.sh
```

There is no Geary build command yet because no useful Geary recipe exists without
the WebKitGTK 4.1 package set.
