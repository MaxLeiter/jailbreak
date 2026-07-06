# Repo fold-in: flavor meta-packages and the staged publish

Started 2026-07-01; refreshed after the first publish waves. How the built debs in `x11/linux-build/out/` become an installable
product on repo.maxleiter.com, with Sileo/Cydia as the flavor chooser. No
custom chooser or greeter ships: a user installs one `xios-<flavor>` package
and the package manager resolves the whole desktop, and hides or blocks
flavors the device cannot run.

Prod publish (`bin/publish-repo.sh`, which ends in `vercel deploy --prod`) is
gated on Max. Everything below it on the checklist is prep and can run now.

## The five meta-packages

Controls live in `x11/packages/meta/<pkg>/DEBIAN/control`; `build-meta.sh`
next to them builds all five control-only debs and copies them into
`linux-build/out/` so the stamping pass treats them like any other deb.
Sileo copy comes from `repo/meta/xios-*.json` (already written).

| Package | Pulls in (Depends) | Floor today | Publishable? |
|---|---|---|---|
| `xios-core` | iosc, angle, dbus, xios-desktop-defaults, xios-audio-server | **16.0.0** | published |
| `xios-gnome` | xios-core + gnome-shell, gnome-session, gnome-settings-daemon, libaccountsservice0, xios-session-stubs, xios-gnome-typelibs, xios-desktop-theme | **16.5.0** | published; CLI GNOME first-light works, daemon/app concurrency cleanup remains |
| `xios-kde` | xios-core + iosc >= 0.9.15, xios-session >= 1.0.46, kwin, plasma-workspace >= 6.1.5+ios10, plasma-desktop >= 6.1.5+ios5, plasma-mobile >= 6.1.5+ios13, plasma-nano >= 6.1.5+ios3, systemsettings, kscreen, qt6-wayland, kf6-breeze-icons, Ark, Gwenview, KWrite | 16.0.0 | built locally as 0.1.2; repo metadata not published yet |
| `xios-native` | xios-core + ioscd, xios-native-host | 16.0.0 | built locally; not published as a meta yet |
| `xios-x11` | xios-core + xwayland, xios-server, xauth | **16.5.0** | published; Xwayland glamor IOSurface smoke passed |

Redundant deps are trimmed: gnome-shell already pulls dconf, gjs, libmutter,
gsettings-desktop-schemas and the GTK stacks; xios-server already pulls
xkbcomp and xkeyboard-config; xios-desktop-defaults pulls x11-fonts-sf and
fontconfig. The meta lists only top-level components.

Recommends (not auto-installed by Sileo, shown as suggestions): xios-core
recommends pulseaudio and xios-desktop-theme; xios-gnome recommends
gnome-console, nautilus, gnome-text-editor, gnome-calculator; xios-x11
recommends x11-xvfb and tigervnc-standalone-server. PulseAudio/media packaging
is now part of the working GNOME first-light path; keep the exact dependency
choice in sync with `packages/meta/xios-gnome/DEBIAN/control`.

Names that settled since the original fold-in note: `xios-session-stubs` ships
the login1/polkit/accounts stub daemons, and `xios-gnome-typelibs` ships the
aggregated on-device-scanned typelibs GNOME Shell imports at boot. `ioscd` and
`xios-native-host` remain the native flavor package names in the meta control;
verify they are indexed before publishing `xios-native`.

## How the store does the gating

Three layers, no custom logic:

1. **MinimumOSVersion** in each control. Sileo and Zebra hide or block the
   package on older iOS. The value is recomputed at publish time by
   `tools/stamp-minos.py --apply` as the effective dependency-closure floor,
   so a meta's stamp IS its flavor floor. Verified today (dry run):
   core 16.0.0, gnome 16.5.0, kde 16.0.0, native 16.0.0, x11 16.5.0,
   matching an independent closure computation over out/ + repo/debs.
2. **`Depends: firmware (>= X)`** on each meta (the standard Procursus
   idiom). This makes apt/dpkg themselves refuse on older iOS, covering
   managers that ignore MinimumOSVersion. The firmware floor is written by
   hand in the control; publish checklist step 6 compares it against the
   fresh stamp and bumps it if the closure drifted.
3. **Rootless by construction**: every binary bakes /var/jb, so rooted
   jailbreaks cannot install a working set no matter what the metadata says.
   RootHide resolves its /var/jb symlink and works as-is.

Floor notes:
- gnome is dragged to 16.5 by gjs/libgjs0 (own minos 16.5, SDK-default
  drift, not real 16.5 API use). A rebuild with pinned `-mios-version-min`
  would drop the flavor to 16.2 (bounded by libgtkintl + g-i).
- x11 is dragged to 16.5 by libdrm2 and xwayland (same drift). A pinned
  rebuild would drop it to 16.0. Optional polish, not blocking.

### Known follow-up: SDK-drift floors (root cause found 2026-07-01)

iosc-shell traced the mechanism: link lines that omit
`-miphoneos-version-min` make ld64 stamp the build SDK's version as the
Mach-O LC_BUILD_VERSION minos, which stamp-minos then treats as the floor.
No recipe in linux-build passes the flag, so every deb's own floor is
whichever SDK epoch its builder image had: 16.0 for most, 16.2 for the
libgtkintl / gobject-introspection / libgirepository era, 16.5 for the
recent gjs / libgjs0 / libei1 / libdrm2 / libgtop-2.0-11 / iosc-shell
builds (iosc-shell has since pinned its own link line and will drop to
16.0 at next build).

Offending build steps, for the recipe owners:
- bare `$(CC) -dynamiclib` shim links (no `$(CFLAGS)`, no pin):
  `recipes/libdrm.mk:56`, `recipes/libei.mk:50`, `recipes/libgtop.mk:27`,
  `recipes/gtk+3.0.mk:102` (the libgtkintl shim). Fix: add
  `-miphoneos-version-min=16.0` to the link line.
- meson cross builds whose generated cross.txt has no
  c_args/c_link_args: `recipes/gjs.mk`, `recipes/gobject-introspection.mk`
  (every recipe's cross.txt shares this gap; these are the two whose debs
  currently drift). Fix: add the pin to c_args + c_link_args, or pin it
  once in the builder image's CC wrapper so no recipe can drift again.

Simulated floor effect through the real dependency graph (out/ debs +
DEPENDS_ADD, 2026-07-01):
- pin the 16.5 group only: xios-x11 16.5 -> 16.0 (via libdrm2/xwayland),
  xios-gnome 16.5 -> 16.2, gnome-shell/libmutter/gnome-console -> 16.2.
- pin the 16.2 group too (libgtkintl + g-i + libgirepository): the whole
  catalog and ALL flavor floors flatten to 16.0.
Not urgent (current floors are correct, just higher than necessary), but
each pinned rebuild permanently widens device compatibility; re-run
`tools/stamp-minos.py` after any of them to restamp.

## Version variants: exactly one per package in repo/debs

`make-repo.py` indexes every .deb in `repo/debs/`; two versions of one
package produce duplicate stanzas and duplicate landing-page rows. When
staging, replace, do not accumulate. The correct variant of each duplicate
currently in out/:

| Package | Publish | Drop |
|---|---|---|
| pulseaudio, libpulse0 (+client libs) | **17.0-1** (rpath fix) | 17.0 (dead rpath in client libs) |
| angle | **+es3-1** (compat symlinks) | +es3, plain |
| libepoxy0 / libepoxy-dev | +angle1 | plain |
| libgtk-4-1 / libgtk-4-dev / gtk-4-bin | +wl1 | plain |
| tigervnc-* | +rootless1 | plain |

## Fresh-install fixes (dyld-landmine audit, folded in 2026-07-01)

The dev iPad masks missing pieces because hand-installed files and libs are
already present; a stock device has none of them. Three classes of fix ride
this fold-in:

1. **ANGLE compat symlinks.** The angle deb shipped only libEGL.dylib and
   libGLESv2.dylib; the six names consumers actually resolve (libEGL.2.dylib,
   libEGL.so, libEGL.so.1, libGLESv2.2.dylib, libGLESv2.so, libGLESv2.so.2)
   were hand-made on-device and dpkg-unowned, so fresh installs cannot load
   libmutter or satisfy cogl's dlopen. Fixed at the source:
   `x11/ports/angle/package-angle-es3.sh` now ships the symlinks and builds
   `angle_...+es3-1`. That deb supersedes +es3 in the variant table above.
2. **Depends gaps** (binaries strongly link a lib their package never
   declared). Encoded as the `DEPENDS_ADD` table in
   `linux-build/tools/stamp-minos.py`, applied control-only during the same
   stamping pass and merged into the effective-floor graph: libgtk-4-1 and
   gtk-4-bin gain libxkbcommon0 + libwayland0 + libcairo-script-interpreter2;
   libgjs0 gains libcairo-gobject2; libgnome-autoar-0-0 gains libgtk-3-0;
   libtracker-sparql-3.0-0 gains libsoup-3.0-0; xwayland gains libxau6;
   libxkbcommon-dev gains libxcb1; libmutter-14-0 gains angle + libei1 +
   libatk1.0-0; libstartup-notification0 gains libxcb-util1 + libx11-xcb1;
   libxcb-render0 gains libxau6 + libxdmcp6; the tigervnc pair gains its
   X11/jpeg/gnutls closure. The Procursus-owned names (libxcb-util1,
   libx11-xcb1, libxau6, libxdmcp6, libsndfile1 - already a libpulse0 dep)
   resolve from apt.procurs.us, so no "install X first by hand" pre-steps
   remain in the flavor docs. Recipe owners should mirror these lines into
   their .control sources at next rebuild; the stamp keeps them correct in
   the meantime. Floor effect: libmutter-14-0's effective floor rises to
   16.5 via libei1 (another SDK-drift pin-and-rebuild candidate alongside
   gjs); no flavor floor changes, xios-gnome was 16.5 already.
3. **Unversioned libintl links, bridged via libintl-dev.** Six debs contain
   binaries linking `@rpath/libintl.dylib` instead of `libintl.8.dylib`:
   ibus (ibus-daemon, ibus-portal), libibus-1.0-5, libgee-0.8-2,
   libenchant-2-2, libgeocode-glib-2-0, libgweather-4-0. (libpulse0's 17.0-1
   rebuild fixed its two; the audit list predated it.) On the dev device the
   name resolves only because Procursus **libintl-dev** ships the
   `/var/jb/usr/lib/libintl.dylib -> libintl.8.dylib` symlink. We must NOT
   ship that symlink ourselves (dpkg file conflict with libintl-dev), so the
   `DEPENDS_ADD` table adds `libintl-dev` to those six packages as a bridge.
   The real fix stays with recipe owners: relink against the versioned
   libintl.8 at next rebuild, then drop the bridge dep. The loose
   xios-accounts/login1/polkit stubs have the same link and need
   `Depends: libintl-dev` (or a retarget) when they land in the
   xios-session-stubs deb.

## The fold-in procedure

Steps 1 through 8 are prep. Step 9 is the Max gate.

1. **Freeze the builds.** out/ is churned by concurrent flavor builds; a
   rebuild after stamping silently loses the stamp (it happened to
   libgtk-3-0 and libgtk-4-1 once already). Confirm with the lead that the
   debs being staged are final for this publish wave.
2. **Back up out/.** `out/*.deb` are gitignored, so stamping is not
   reversible via git: `tar cf /tmp/out-backup.tar -C x11/linux-build out`.
3. **Build the metas** (idempotent): `x11/packages/meta/build-meta.sh`.
4. **One-time legacy pass**: copy the repo-only debs (packages in repo/debs
   with no out/ counterpart: xios-server, x11-xvfb, xauth, libx11-6, the
   legacy X11 libs, x11-fonts-sf, xios-desktop-defaults, the two tweaks)
   into out/ so they get stamped too. Only packages with NO out/
   counterpart; never overwrite a newer out/ build with a repo copy.
5. **Stamp LAST**: `python3 tools/stamp-minos.py --apply` (needs Python
   3.14). Then `--json tools/pkg-minos.json` to refresh the floor map.
   This is the final mutation of out/.
6. **Verify floors**: each meta's stamped MinimumOSVersion vs the
   `firmware (>= X)` floor in its control; bump the control and rebuild the
   meta if the closure drifted upward.
7. **Stage per flavor** into repo/debs, replacing superseded versions per
   the variant table above. Completed publish waves include xios-core,
   xios-x11, xios-gnome, xios-session-stubs, and xios-gnome-typelibs. Remaining
   meta waves are xios-native and xios-kde once their complete closures are
   indexed. A meta never ships before its closure: apt on device would fail the
   install, and Sileo shows a broken package.
8. **Regenerate and check locally**: run `bin/lib/make-repo.py` via the
   .repo-venv, then sanity-check: every Depends of every staged deb
   resolves inside repo/debs + the live Procursus index (the externals we
   lean on today: libiosexec1, libpcre2-8-0, libmd0, libice6, libsm6,
   libffi8, libintl8, liblzma5, libbrotli1, libtiff5, libsndfile1,
   libxi6/libxrandr2/libxrender1/libxcb-shm0, libgcrypt20, libgpg-error0,
   libp11-kit0); no duplicate Package stanzas in Packages; the five
   xios-* depictions render; "Minimum iOS" shows on the depictions.
   `repo/vercel.json` must keep the `/./` rewrite (flat-repo fix).
9. **Publish (MAX-GATED)**: `bin/publish-repo.sh` regenerates, GPG-signs
   InRelease/Release.gpg with repo@maxleiter.com, and deploys to Vercel.
   Do not run without Max.
10. **Post-publish verification**: `curl --path-as-is
    https://repo.maxleiter.com/./InRelease` returns 200 (plain curl hides
    the /./ bug); on device, a clean `apt-get update` against only this
    repo, then `apt-get install -s xios-core` and `-s xios-x11` resolve;
    Sileo shows the Desktop section and hides xios-x11 on a sub-16.5
    device if one is available.

## Landing page

`make-repo.py` grew a "Desktop" section (first in SECTION_ORDER, open by
default, its own tile glyph). The five metas carry `Section: Desktop`, so
the flavors form the top block of repo.maxleiter.com with the big library
buckets collapsed below. The featured carousel includes every package
automatically; the metas will appear there once staged.
