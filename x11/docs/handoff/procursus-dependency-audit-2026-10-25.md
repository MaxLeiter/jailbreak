# Procursus runtime dependency audit (2026-10-25)

Question: what does our published stack actually load from Procursus at run time, and which of those pieces should we start building and shipping ourselves now that Procursus is effectively frozen (last commit 2026-05-30, "uikittools: Update to 2.1.8")?

This was a read-only audit. Nothing was built, published or pushed. The iPad was used only for `ls`, `dpkg -S`, `dpkg -L`, `dpkg-query` and one `scp` of the 480 KB dyld shared cache header (to get the system image list).

## Summary

- We scanned the newest version of every package in `repo/Packages` (642 packages, matched to the payloads in `repo/debs/` by `Filename:`, older payloads ignored). 393 of them contain Mach-O files: 1,712 Mach-O files, 29,084 load commands (`LC_LOAD_DYLIB`, `LC_LOAD_WEAK_DYLIB`, `LC_REEXPORT_DYLIB`, plus lazy/upward, deduplicated per binary).
- Every load resolved like this:

  | Resolves to | Load commands |
  |---|---|
  | a file shipped by one of our debs | 18,104 |
  | iOS system (`/usr/lib`, `/System`), 75 distinct images | 9,532 |
  | a Procursus package (or ellekit) | 1,365 |
  | nothing, by static rpath walk | 83 |

  All 75 system images exist in the device's dyld shared cache image list, so nothing we ship needs a system library this iPad lacks.
- **35 Procursus packages are loaded at run time** (34 distinct libraries, plus `libintl-dev`, which owns the unversioned `libintl.dylib` symlink). Add **6 more pulled in indirectly** by those libraries (`libidn2-0` through GnuTLS; `libflac8`, `libogg0`, `libopus0`, `libvorbis0a`, `libvorbisenc2` through libsndfile). That is far smaller than the 70 external names in our `Depends:` lines (66 of them Procursus packages, plus `firmware`, `mobilesubstrate`, `libexpat1`, `libexpat1-dev`). Most of the gap is `-dev`, build tools and stale declarations.
- **293 of our packages (1,146 binaries) load at least one Procursus library.** `libiosexec1` alone accounts for 260 packages and 1,097 binaries. Leaving libiosexec out, the real surface is **89 packages and 175 binaries**.
- Four Procursus libraries are loaded but declared by no package at all (`libxtst6`, `libcrypt2`, `libxcb-randr0`, `libxcb-res0`; the last two only weakly). Another 34 package/library pairs load a Procursus library that is not in their transitive `Depends` closure, so a fresh install can dyld-fail. Details under "Missing dependencies".
- The 129 Procursus names we already shadow are not repeated in the takeover list below. Nothing in the runtime set overlaps with them, which is by construction: a library we shadow resolves to our file.

**Wave 1 (security-relevant, known issues), in priority order:**

1. **libtiff5 4.2.0** (December 2020). Retire it: relink its four consumers (`libgdk-pixbuf-2.0-0`, `libgtk-4-1`, `gtk-4-bin`, `liblcms2-utils`) against our existing `libtiff6`, which itself should go from 4.7.0 to 4.7.2.
2. **libssl3 3.2.1** (the 3.2 branch has been end of life since 2025-11-23; 11 published CVEs fixed in 3.2.2 through 3.2.6) coupled with **openssh 9.7p1** (regreSSHion race, CVE-2025-26466 pre-auth DoS), because of the sshd version trap.
3. **The GnuTLS stack**: libgnutls30 3.8.5 (20 advisories fixed since, five rated High), libtasn1-6 4.19.0 (CVE-2024-12133), libnettle8/libhogweed6 3.9.1, libp11-kit0 0.25.3, libidn2-0 2.3.7. This is what every GLib/GTK TLS connection goes through (glib-networking).
4. **liblzma5 5.4.4** (CVE-2025-31115, use-after-free in the multithreaded decoder, 5.3.3alpha to 5.8.0). It is also ABI-critical, since dpkg and apt link it.
5. **libsndfile1 1.0.31** plus **libflac8 1.3.3** (pulseaudio decodes sound files through them).
6. **libfribidi0 1.0.10** (CVE-2022-25308/25309/25310; we already have `recipes/fribidi.mk` at 1.0.13, never published).
7. Base tools with known issues that our device management depends on: **sudo 1.9.15p5** (CVE-2025-32463 and CVE-2025-32462, fixed in 1.9.17p1) and openssh (item 2).

## Method

1. `extract.py` read `repo/Packages`, opened each indexed deb (a small ar reader, because some debs use GNU-style `name/` member names that macOS `ar x` silently skips), unpacked `data.tar.*` with `bsdtar`, recorded every file and symlink, and ran `otool -l` on every Mach-O. It also recorded `#!` lines.
2. `resolve.py` expanded `@rpath`, `@loader_path` and `@executable_path` from the binary's own `LC_RPATH` entries and tried candidates in dyld order: the first candidate that exists wins, whether we ship it or the device has it. A second pass searched the rpaths of every image above the binary in the load chain (dyld does this) and used the top executable for `@executable_path`. That second pass resolved the Ladybird.app bundle and the JDK `@rpath/libjvm.dylib` cases.
3. "Exists on the device" came from a read-only `[ -e ]` probe over all 2,056 `/var/jb` candidate paths, plus `ls /var/jb/usr/lib /var/jb/lib/angle`. Each device-resolved path (and its real file) went through `dpkg -S`. One symlink (`liblz4.1.dylib`) is listed by `dpkg -L liblz4-1` but missed by `dpkg -S`; it is owned.
4. System loads were checked against the image list in the device's `dyld_shared_cache_arm64` header.
5. Versions: device `dpkg-query` and the Procursus 1900 index (`apt.procurs.us/dists/1900/main/binary-iphoneos-arm64/Packages`) agree for every runtime package. Upstream versions came from `git ls-remote --tags`, the same method `x11/linux-build/tools/audit-upstream-versions.py` uses (it only walks our recipes, so it could not be pointed at Procursus packages directly), plus gnupg.org, gmplib.org and sudo.ws where git was unreachable or stale.
6. Security status came from the upstream advisory pages (OpenSSL 3.2 vulnerability list, GnuTLS security-new, OpenSSH security page) and distro trackers, fetched on 2026-10-25.

On the existing tools: `report-closure.py` answers a different question (`Depends:` closure over `out/`, not load commands over `repo/debs`), so we reused its closure idea and ran it over both indexes. `audit-deb-set.py` already parses load commands but has no rpath resolution or classification. The natural follow-up is to fold step 2 into `audit-deb-set.py` as a runtime-deps check. We did not do that here, because this was a read-only pass. The scripts and raw data live in the session scratchpad, not in the repo.

## Runtime Procursus dependencies

"Bins / pkgs" counts our binaries and packages that load the library directly. Class: **S** = security-relevant (parses untrusted input, or does crypto/TLS), **A** = ABI-critical core (a mismatched rebuild can take down the shell, ssh or package management), **O** = ordinary. "Base" means the base system also links it (apt, dpkg, sshd, shells, coreutils).

| Procursus package | Bins / pkgs | Our users (examples) | Procursus = device | Upstream now | Known issues in the Procursus version | Class |
|---|---|---|---|---|---|---|
| libiosexec1 | 1097 / 260 | almost everything | 1.3.1 | 1.3.1 (Procursus project) | none known; it is the shebang/exec rewriter that makes our `/bin/sh`, `/usr/bin/env python3` and `/usr/bin/perl` scripts work at all on rootless | A, base |
| libintl8 | 19 / 9 | libglib2.0-0, libgtkintl, libgdk-pixbuf, libcairo-gobject2, xios-fhs | 0.22 | gettext 1.0 | none known | A, base |
| libintl-dev (symlink only) | 71 / 20 | libwebkit2gtk-4.1-0, librsvg2-2, ibus, libgee, EDS, xfce libs | 0.22 | n/a | packaging bug, see below | A |
| libffi8 | 6 / 5 | libglib2.0-0, libgirepository, libgjs0, libwayland0, gobject-introspection | 3.4.6 | 3.8.0 | none known | A |
| libcrypt2 | 1 / 1 | libaccountsservice0 | 4.4.36 | libxcrypt 4.5.2 | none known | A, base (sshd, system-cmds) |
| libmd0 | 2 / 2 | x11-xvfb, tigervnc-standalone-server | 1.1.0 | 1.3.0 | none known | A, base (dpkg, openssh) |
| libssl3 | 10 / 5 | curl, libcurl4, transmission, kf6-archive, ladybird-tls fallback | 3.2.1 | 3.5.9 LTS, 3.6.5, 4.1.0 (3.2 line ended at 3.2.6) | **EOL 2025-11-23.** Fixed after 3.2.1: CVE-2024-12797 (High, RPK auth), CVE-2024-6119, CVE-2025-9230 (CMS KEK unwrap OOB read/write), CVE-2025-9231 (SM2 timing on arm64), CVE-2025-9232, CVE-2024-13176, CVE-2024-9143, CVE-2024-5535, CVE-2024-4741, CVE-2024-4603, CVE-2024-2511. The 2026 advisories (16 that hit both 3.0 and 3.5, including a High DTLS one and two Moderate CMS ones) are not even assessed for 3.2 any more. | S, A, base |
| libgnutls30 | 6 / 5 | glib-networking, libvte-2.91-gtk4-0, tigervnc-* | 3.8.5 | 3.8.13 | 20 advisories fixed in 3.8.9 to 3.8.13: High CVE-2026-42010 (RSA-PSK NUL username auth bypass), CVE-2026-33845 and CVE-2026-33846 (DTLS heap overruns), CVE-2026-42009; Medium name-constraint bypasses CVE-2026-42011/42012/42013, CVE-2026-3833, CVE-2025-32989 (SCT heap overread), CVE-2025-6395, CVE-2024-12243 | S, base (apt https, dirmngr) |
| libnettle8 | 6 / 3 | epiphany, libarchive13, libarchive-tools | 3.9.1 | 3.10.2 (4.0 has a new soname) | none we could confirm | S |
| libhogweed6 | 1 / 1 | epiphany | 3.9.1 | 3.10.2 | none we could confirm | S |
| libgmp10 | 4 / 4 | libmpfr6, libmpc3, kcalc, epiphany | 6.3.0 | 6.3.0 | none (current) | S, base (coreutils, hogweed) |
| libp11-kit0 | 6 / 4 | libgck-1-0, libgcr-3-1, libgcr-4-4, gnome-keyring | 0.25.3 | 0.26.5 | none known | S (trust store) |
| libtasn1-6 | 1 / 1 | libwebkit2gtk-4.1-0 (and via gnutls) | 4.19.0 | 4.21.0 | CVE-2024-12133, quadratic DER decoding DoS from a crafted certificate, fixed in 4.20.0 | S |
| libgcrypt20 | 10 / 5 | gnome-keyring, libsecret-1-0, libgcr-3-1, libgcr-4-4, libwebkit2gtk | 1.10.3 | 1.12.4 | CVE-2024-2236 (RSA PKCS#1 v1.5 timing, "Marvin"); distros carry patches, the vanilla 1.10.3 does not | S, A, base (apt via libapt-pkg, gpgv) |
| libgpg-error0 | 1 / 1 | libwebkit2gtk-4.1-0 | 1.48 | 1.61 | none known | A, base (gpgv) |
| libtiff5 | 4 / 4 | libgdk-pixbuf-2.0-0, libgtk-4-1, gtk-4-bin, liblcms2-utils | 4.2.0 | 4.7.2 | **Many.** 4.2.0 predates every libtiff fix since December 2020. Debian has had to backport dozens into its 4.2.0 package, through CVE-2022-1354 (heap overflow, TIFFReadRawDataStriped), CVE-2024-7006, CVE-2025-9900 (write-what-where on large image height) and CVE-2026-4775 (heap write overflow, April 2026). gdk-pixbuf runs it on any TIFF a GTK app or thumbnailer opens. | S |
| liblzma5 | 15 / 11 | libxml2, libarchive13, gimp, kf6-archive, libavcodec59, libxmlb2 | 5.4.4 | 5.8.4 | CVE-2025-31115, use-after-free/crash in the multithreaded decoder (`lzma_stream_decoder_mt`). Upstream fixed it on the 5.4 branch but cut no 5.4 release. (5.4.4 predates the 5.6.0/5.6.1 backdoor and is not affected by it.) | S, A, base (dpkg, apt, xz) |
| libzstd1 | 11 / 8 | curl, libcurl4, libarchive13, kf6-archive, libappstream5, libgl1-mesa-glx | 1.5.5 | 1.5.7 | none known | S, A, base (dpkg, apt) |
| liblz4-1 | 6 / 3 | libarchive13, libarchive-tools, libvte | 1.9.4 | 1.10.0 | none known | S, A, base (apt) |
| liblzo2-2 | 6 / 3 | libarchive13, libcairo-script-interpreter2 | 2.10 | 2.10 (upstream dormant since 2017) | none known | O |
| libsndfile1 | 4 / 3 | libpulse0, pulseaudio, pulseaudio-utils | 1.0.31 | 1.2.2 | CVE-2022-33065 (integer overflows, fixed in 1.2.2), CVE-2024-50612 (Ogg Vorbis OOB read), CVE-2026-37555 (IMA ADPCM WAV overflow, open even against 1.2.2); indirect libflac8 1.3.3 carries CVE-2020-0499/CVE-2021-0561 (fixed in 1.3.4) | S |
| libpcre2-8-0 | 4 / 4 | libglib2.0-0, libgtksourceview-5-0, libvte, libeditorconfig0 | 10.43 | 10.49 | none confirmed for 10.43 (CVE-2025-58050 is 10.45-only) | S (low), base (grep, less) |
| libpcre2-16-0 | 1 / 1 | qt6-base | 10.43 | 10.49 | as above | S (low) |
| libfribidi0 | 13 / 12 | libpango-1.0-0, libgtk-3-0, libgtk-4-1, libadwaita, libmutter, libass9 | 1.0.10 | 1.0.17 | CVE-2022-25310 (library NULL deref on crafted input), CVE-2022-25308/25309 (CLI); fixed in 1.0.12 | S |
| libice6 | 11 / 6 | gnome-session, thunar, libxfce4ui, libexo, tigervnc | 1.0.10 | 1.1.2 | none since CVE-2017-2626 | O |
| libsm6 | 11 / 6 | same as libice6 | 1.2.3 | 1.2.6 | none known | O |
| libxi6 | 6 / 5 | libgtk-3-0, libgtk-4-1, libmutter, gnome-control-center | 1.7.10 | 1.8.4 | none known | O |
| libxrandr2 | 6 / 5 | libgtk-3-0, libgtk-4-1, libmutter, tigervnc | 1.5.2 | 1.5.5 | none known | O |
| libxrender1 | 4 / 4 | libcairo2, libcairo-gobject2, libxcursor1 | 0.9.10 | 0.9.13 | none known | O |
| libxtst6 | 2 / 2 | libmutter-14-0, tigervnc-scraping-server | 1.2.3 | 1.2.6 | none known | O |
| libx11-xcb1 | 2 / 2 | libmutter-14-0, libstartup-notification0 | 1.7.3.1 | libX11 1.8.14 | the libX11 CVEs (CVE-2023-3138, CVE-2023-43785/43786/43787) live in libX11 proper, which we already shadow at the same 1.7.3.1 | O |
| libxcb-shm0 | 3 / 3 | libcairo2, libcairo-gobject2, libcairo-script-interpreter2 | 1.14 | 1.17.0 | none known | O |
| libxcb-randr0 | 1 / 1 (weak) | libmutter-14-0 | 1.14 | 1.17.0 | none known | O |
| libxcb-res0 | 1 / 1 (weak) | libmutter-14-0 | 1.14 | 1.17.0 | none known | O |
| libxcb-util1 | 1 / 1 | libstartup-notification0 | 0.4.0 | 0.4.1 | none known | O |
| ellekit (not Procursus) | 4 / 3 | com.max.hush, com.max.autolockpicker, com.max.pulltorespring2 | 1.2 (Dopamine's) | n/a | out of scope: this is the jailbreak's hooking runtime, not something we should own | n/a |

Indirect only (loaded by the libraries above, not by our binaries):

| Procursus package | Version | Pulled in by | Upstream | Notes | Class |
|---|---|---|---|---|---|
| libidn2-0 | 2.3.7 | libgnutls30 | 2.3.8 | none known | S |
| libflac8 | 1.3.3 | libsndfile1 | 1.5.0 | CVE-2020-0499, CVE-2021-0561 | S |
| libogg0 | 1.3.5 | libsndfile1 | 1.3.6 | none known | S (low) |
| libopus0 | 1.3.1 | libsndfile1 | 1.5.x | none known | S (low) |
| libvorbis0a, libvorbisenc2 | 1.3.7 | libsndfile1 | 1.3.7 | none known | S (low) |

The rest of their dependency closure is already ours (`ca-certificates`, `libbrotli1`, `libjpeg62-turbo`, `libunistring5`, `libuuid16`, `libx11-6`, `libxcb1`, `libxext6`).

## Interpreters are a runtime dependency too

Our debs carry 102 scripts. The ones that reach outside `/bin/sh`:

- `/usr/bin/env python3` or `/usr/bin/python3` (26 scripts, 10 packages): `gobject-introspection` (`g-ir-scanner`), `libglib2.0-dev-bin` (`gdbus-codegen`, `glib-mkenums`), `xios-session` (`/var/jb/usr/local/bin/xios-ios-apps`, a runtime tool), `plasma-workspace` (a kconf_update migration), `qt6-base`, `gnome-shell` (test tool), plus build-time helpers. They all resolve to Procursus **python3.9 3.9.9, which has been end of life since October 2025.**
- `/usr/bin/perl` or `env perl`: EDS `csv2vcard`, tigervnc `vncserver`, all on Procursus **perl 5.32.1** (long out of support).
- None of `/bin/sh`, `/usr/bin/env`, `/usr/bin/python3` or `/usr/bin/perl` exists on this device. These scripts work only because libiosexec rewrites the interpreter path when the parent process links it. That is one more reason libiosexec belongs in the ABI-critical wave.

## Missing dependencies found

Hard misses, where a load resolves to nothing:

1. **evolution-data-server: `@rpath/libedbus-private.dylib` is unreachable from 31 binaries** (all the factories in `libexec`, the `libedataserver`/`libecal`/`libebook*` dylibs and every backend module). The library ships at `/var/jb/usr/lib/evolution-data-server/libedbus-private.dylib`, but every rpath is just `/var/jb/usr/lib`, and no launcher sets a library path for EDS. EDS is not installed on this iPad, so we have not seen it fail, but nothing could load it. No published package depends on EDS yet (the `WITH_EDS` gnome-shell rebuild is still staged), so it bites the moment that lands. Fix: add `@loader_path`-relative rpaths (or `/var/jb/usr/lib/evolution-data-server`) in `build-eds.sh`.
2. **gnome-settings-daemon: `gsd-a11y-settings`, `gsd-housekeeping`, `gsd-keyboard` and `gsd-screensaver-proxy` cannot find `@rpath/libgsd.dylib`.** Their rpath is `@loader_path/../../gnome-settings-daemon`, which from `/var/jb/usr/libexec` points at `/var/jb/gnome-settings-daemon`. The library lives in `/var/jb/usr/lib/gnome-settings-daemon-46/`, and `launch-gnome-session.sh`'s `DYLD_LIBRARY_PATH` does not include that directory. These four plugins should dyld-abort under GNOME today. We did not run them (read-only), so this needs one on-device confirmation.
3. **libwayland-dev depends on `libexpat1-dev`, which exists nowhere**: we don't ship it and Procursus doesn't publish it. The package is uninstallable through apt. (`fontconfig` and `libfontconfig*` list `libexpat1` only as an alternative to `firmware`, so they are fine. The runtime loads go to the system `/usr/lib/libexpat.1.dylib`.)

Loads that resolve only through launcher environment or an already-loaded image (working today, but fragile):

- gnome-shell and libmutter load `libmutter-{clutter,cogl,cogl-pango,mtk}-14.0` and `libshell-14` through build-tree rpaths (`@loader_path/../cogl/cogl`, `/work/Procursus/.../mutter-14`). On device they resolve only because `launch-gnome-session.sh` puts `mutter-14` and `gnome-shell` on `DYLD_LIBRARY_PATH`. A real `/var/jb/usr/lib/mutter-14` rpath would remove that dependency.
- `gobject-introspection`'s `_giscanner.cpython-39-darwin.so` has no rpath at all and works only under the `DYLD_LIBRARY_PATH` the `gir-build-*-ondevice.sh` scripts set.
- OpenJDK's `@rpath/libjvm.dylib` (22 libs) resolves because the launcher has already loaded `lib/server/libjvm.dylib`. This is the standard JDK pattern and is fine.
- `ladybird-tls`'s own `libssl.3.dylib` has rpath `/var/jb/usr/lib`, so outside Ladybird's process it would bind Procursus libcrypto 3.2.1. Inside Ladybird it works, because the executables load the private libcrypto first and dyld reuses it. This is low risk, but an `@loader_path` rpath would make it independent of load order. Separately, `recipes-ladybird/openssl.mk` is now at 3.6.3, and **the 3.6 line loses support on 2026-11-01**. The next ladybird-tls should target 3.5 LTS or 4.x.

Undeclared runtime dependencies. In each pair below, a package loads a Procursus library that is not in its transitive `Depends` closure (walked through both our index and Procursus's). These work on this iPad because something else pulled the library in, but they can fail on a fresh install:

| Procursus library | Packages that load it without depending on it |
|---|---|
| libintl-dev (`libintl.dylib`) | evolution-data-server, ladybird-wayland, libenchant-2-2, libexo-2-0, libgee-0.8-2, libgmime-3.0-0, libgoffice-0.10-10, libgsf-1-114, libical3, librsvg2-2, librsvg2-bin, librsvg2-common, libwebkit2gtk-4.1-0, libxfce4ui-2-0, libxfce4util7, thunar, xfconf, xios-desktop-stublibs |
| libzstd1 | kf6-archive, libappstream5, libxmlb2 |
| libice6, libsm6 | libexo-2-0, libxfce4ui-2-0, thunar, tigervnc-common, tigervnc-scraping-server |
| libssl3 | kf6-archive, ladybird-tls |
| libgnutls30 | tigervnc-common |
| libcrypt2 | libaccountsservice0 |
| libxtst6 | libmutter-14-0, tigervnc-scraping-server |
| libx11-xcb1 | libmutter-14-0 |
| libxrandr2 | tigervnc-scraping-server |
| libxcb-randr0, libxcb-res0 | libmutter-14-0 (weak, so harmless) |

The libintl row is the known "libintl trap" from the portability notes. The `DEPENDS_ADD: libintl-dev` bridge reached only six packages, and 18 more now link the unversioned `@rpath/libintl.dylib`. The real fix is still to relink to `libintl.8.dylib`. That has to happen before we take over gettext, because otherwise our libintl package inherits the `-dev` symlink problem.

The same pass also found 56 package pairs that load one of *our* libraries without depending on it. The large ones: kwin needs kf6-kcmutils, kf6-xmlgui and libepoxy0 (29 binaries); ark needs kf6-pty (24); okular needs kf6-wallet (10). Some of these are plugins whose host already pulls the library in, so they need case-by-case review. They are out of scope here, and the full list is in the scratchpad `analyze.txt`.

Also noted: 300 binaries in 111 packages carry build-host rpaths (`/work/Procursus/build_base/...`). dyld probes these and they miss, so they are harmless, but they are noise worth stripping in the packaging step.

## Base system and tooling (not loaded by us, but needed to keep the device manageable)

These all come from Procursus on this iPad. Keeping ssh, apt, dpkg and a shell alive depends on them, and they pin several of the libraries above.

| Package | Device | Upstream now | Links (Procursus Depends) | Notes |
|---|---|---|---|---|
| openssh-server / -client / -sftp-server | 9.7p1-1 | 10.6p1 | libssl3, libcrypt2, libpam2, libmd0 | regreSSHion (8.5p1 to 9.7p1, signal-handler race; RCE confirmed only on glibc, "possible" elsewhere), CVE-2025-26466 pre-auth DoS (9.5p1 to 9.9p1), DisableForwarding bug (fixed 10.0). Runtime OpenSSL check, see wave 1. |
| apt, libapt-pkg6.0 | 2.9.4-1 | 3.3.4 | libgnutls30, libgcrypt20, liblz4-1, liblzma5, libxxhash0, libzstd1, gpgv | the https transport is GnuTLS 3.8.5 |
| dpkg | 1.22.6 | 1.23.11 | liblzma5, libzstd1, libz-ng2, libintl8, libmd0 | upstream fixed a dpkg-deb extraction cleanup DoS (CVE-2025-6297) in 1.22.21 |
| gpgv | 2.4.5 | gnupg 2.5.24 | libgcrypt20, libgpg-error0, libassuan0, libnpth0, libintl8 | verifies every repo signature, including ours |
| coreutils | 9.5 | 9.12 | libssl3, libgmp10, libintl8, libcrypt2 | links OpenSSL too |
| ldid | 2.1.5-procursus7 | same | libssl3, libplist3 | our on-device re-sign path depends on it |
| uikittools | 2.1.8 | same (Procursus-owned) | libiosexec1 | |
| sudo | 1.9.15p5 | 1.9.17p2 | libpam2, libintl8 | CVE-2025-32463 (chroot option local root), CVE-2025-32462; fixed in 1.9.17p1 |
| bash | 5.2.21 | 5.3 | libncursesw6, libreadline8 | |
| zsh (root's shell) | 5.9 | 5.9.2 | libncursesw6, **libpcre1** | PCRE1 has been dead since 2021 |
| dash (`/var/jb/bin/sh`) | 0.5.12 | not checked | libedit0 | |
| ncurses-bin, libncursesw6 | 6.4 | 6.5 | | ABI-critical for every shell |
| libreadline8 | 8.2 | 8.3 | libncursesw6 | |
| libssh2-1 | 1.11.0 | 1.11.1 | libssl3 | only Procursus consumers now (our curl does not load it) |
| libz-ng2 | 2.1.6 | 2.3.3 | | dpkg's zlib |
| libxxhash0 | 0.8.2 | 0.8.4 | | apt |
| libpam2 (openpam) | 20230627 | | libpam-modules | sshd, sudo, login |
| python3.9 | 3.9.9 | 3.14 | | EOL October 2025; see "Interpreters" |
| perl | 5.32.1 | 5.42 | | EOL |
| launchctl, system-cmds, debianutils, findutils, grep, sed, tar, gzip, xz-utils, zstd, less, procursus-keyring, libkrw0, libplist3 | Procursus | | | grep and less link libpcre2-8-0 |

Already ours in this list: `curl`/`libcurl4` 8.20.0, `libnghttp2-14`, `libxml2` 2.13.8, `libsqlite3-1` 3.52.0, `ca-certificates` 20261020, `libbrotli1`, `libunistring5`, `libbz2-1.0`, `libz1`. Note that our curl 8.20.0 still does its TLS through Procursus OpenSSL 3.2.1, so the curl bump did not move the TLS code.

## Already ours (the 129 shadowed names)

`check-procursus-shadow.py` covers 129 names our index shares with Procursus (`shadow-waivers.json` holds 58 waivers). By family: the X11 core (`libx11-6`, `libxcb1`, `libxcb-render0`, `libxcb-xkb1`, `libxau6`, `libxdmcp6`, `libxext6`, `libxfixes3`, `libxdamage1`, `libxcursor1`, `libxinerama1`, `libxkbfile1`, `libxmuu1`, `libxfont2`, `libfontenc1`, xkbcomp, xkeyboard-config, xauth, tigervnc); text and fonts (fontconfig, freetype, harfbuzz, graphite2, libass, icu, utf8proc); images (libpng16, libjpeg-turbo, libwebp, lcms2, pixman, cairo); media (ffmpeg 5.1.2 libav*); glib2.0; mesa GL/GLU/GLEW; network (curl, nghttp2, brotli, ca-certificates); data (libxml2, sqlite3, libarchive, libyaml, luajit, libsigc++, libfmt, mpfr/mpc, libltdl, libuuid, libunistring, libqrencode, libgeneral, transmission).

None of these is repeated below. We own them now, though, and several are stale enough to belong on the same security clock. The clearest cases: **libarchive13 3.7.2** (CVE-2024-26256 RAR RCE fixed in 3.7.4, CVE-2024-48957/48958 in 3.7.5, CVE-2025-5914 double free in 3.8.0), **libx11-6 1.7.3.1** (the 2023 libX11 CVEs above, fixed in 1.8.7), **libtiff6 4.7.0** (go to 4.7.2), **tigervnc 1.11.0** (its Xvnc is 2020-era X server code), and ffmpeg 5.1.2 (already under a policy hold).

## Takeover plan

Every library on this list already has a Procursus makefile (`makefiles/<name>.mk` in the Procursus tree that `build-procursus-target.sh` clones into the build volume), except gmp, lzo2 and xcb-util (not present under those names, so either named differently or missing) and fribidi, which is ours. So the work is mostly version bumps, re-running our toolchain edits, and the shadow gates, not writing new recipes. "Recipe here" means a file in `x11/linux-build/recipes/` or `recipes-ladybird/`.

Every replacement in waves 1 and 2 has to clear `check-procursus-shadow.py`: same dylib paths (parity), exported symbols a superset (symbols), and a written waiver for the version change. The sshd lesson says to treat a waiver as a claim we must test, not as permission.

### Wave 1: security-relevant libraries with known issues

| Item | Recipe here | Job size | What it takes |
|---|---|---|---|
| libtiff5 4.2.0 | no, and none needed | small | Don't take over libtiff5. Rebuild `libgdk-pixbuf-2.0-0`, `libgtk-4-1`/`gtk-4-bin` and `liblcms2-utils` against our `libtiff6` (built by `packages/gimp-stack/package.sh`), bump libtiff6 to 4.7.2, then drop `libtiff5` from their Depends. No shadowing, no soname risk. |
| libssl3 3.2.1 + openssh 9.7p1 | `recipes-ladybird/openssl.mk` (3.6.3, private prefix); Procursus `openssl.mk`, `openssh.mk` | large, coordinated | See the next subsection. |
| GnuTLS stack: libgnutls30, libtasn1-6, libnettle8/libhogweed6, libp11-kit0, libidn2-0 | no; Procursus mk for all | medium | gnutls 3.8.13 with libtasn1 4.21.0, nettle **3.10.2** (keep sonames `libnettle.8`/`libhogweed.6`; nettle 4.0 bumps them and would force rebuilding every consumer), p11-kit 0.26.x, libidn2 2.3.8. The gnutls soname stays at 30 and the symbol set only grows. apt links gnutls, so test `apt update` over https against both repos before publishing, with the old debs at hand to `dpkg -i` back. |
| liblzma5 5.4.4 | no (libtiff6 already carries a private `gimp-private/liblzma.5.dylib`); Procursus `xz.mk` | small build, careful rollout | Either 5.4.4 with the upstream CVE-2025-31115 backport (smallest blast radius) or 5.8.4 (same soname `liblzma.5`, symbol superset). dpkg links it, so a bad build breaks package management: test `dpkg-deb -x`/`-b` and an `apt install` on a snapshot first, and keep `xz-utils` in step (it pins `liblzma5 (>= 5.4.4)`). |
| libsndfile1 1.0.31 + libflac8 1.3.3 | no; Procursus mk | small to medium | libsndfile 1.2.2 keeps the `libsndfile.1` soname. flac 1.3.4 (same soname) or 1.4+/1.5 (libFLAC soname 12, which means taking over libflac and rebuilding its consumers). 1.3.4 is the cheap path. CVE-2026-37555 is still open upstream, so carry the patch. Test with pulseaudio playing a WAV (remember `libpulsecommon` needs libsndfile1 installed first). |
| libfribidi0 1.0.10 | **yes**, `recipes/fribidi.mk` at 1.0.13 | small | Bump to 1.0.17, build, run the shadow gate, publish. Pango, GTK and mutter are the consumers. |
| sudo 1.9.15p5 | no; Procursus `sudo.mk` | small | 1.9.17p2 against Procursus libpam2. Keep root-over-ssh working in parallel while testing, since `sudo` is not our recovery path anyway. |

#### OpenSSL and the sshd trap

Facts first. Procursus sshd 9.7p1 links `libssl3`, and on 2026-07-08 it refused OpenSSL 3.5.3 at startup with "OpenSSL version mismatch". The odd part is that upstream 9.7p1's `ssh_compatible_openssl()` only compares the major number and status nibble for 3.x, so on paper 3.2 to 3.5 should have passed. We never found what makes Procursus's build stricter (its only openssh patch is `build_patch/openssh/ios.diff`, which we did not dissect). Until we do, we assume any change to libssl3, even 3.2.1 to 3.2.6, can trip it. Since sshd is spawned per connection, a bad libssl3 kills the *next* login, not the current one.

So we never ship libssl3 alone. The safe sequence:

1. Build OpenSSL **3.5.x LTS** (supported to 2030-04-08) as `libssl3`/`openssl`, same `libssl.3.dylib`/`libcrypto.3.dylib` paths. 3.x keeps ABI compatibility within the major version, but the symbols rule must still pass against 3.2.1.
2. In the same batch, build **openssh 10.x** (`openssh-server`, `-client`, `-sftp-server`) against it, plus `ldid`, `coreutils` and `libssh2-1`. `libcurl4`, `curl`, `transmission` and `kf6-archive` are ours already and just need rebuilds or a re-check.
3. Make `libssl3` `Breaks: openssh-server (<< our version)` and have our openssh depend on `libssl3 (>= our version)`, so apt can only move them together.
4. Before installing on the device, keep a second way in: a second sshd on another port that links the *old* libcrypto from a private prefix (the ladybird-tls technique), or the lockdown/idevicesyslog path from the diagnostics notes. Install, open a new ssh connection, and only then close the old one.
5. Then retire the per-app OpenSSL in `ladybird-tls`, or at least move it to 3.5 to match. Its 3.6 line dies on 2026-11-01.

A cheap interim, if the full batch has to wait: `libssl3 3.2.6+ios1` (the final 3.2 release) clears the 11 published 3.2 CVEs with the smallest symbol delta. It is still EOL and still subject to the unexplained sshd behaviour, so it needs the same second-sshd precaution.

### Wave 2: ABI-critical core

These carry no urgent CVEs, but they sit under the shell, ssh and apt. Rebuilding them is about owning the build, not changing behaviour. So the first build of each should be the **same upstream version** as Procursus, built from our tree, with a byte-level symbol diff against Procursus's dylib. Only after that do we bump.

| Item | Recipe here | Job size | What it takes |
|---|---|---|---|
| libiosexec1 1.3.1 | no; Procursus `libiosexec.mk` (Procursus is upstream) | small build, highest stakes | Fork `ProcursusTeam/libiosexec`, build 1.3.1 unchanged. 1,097 of our binaries and every Procursus binary link it, and it does the rootful-shebang rewriting our scripts depend on. Exported symbol set must be identical, not merely a superset. Test from a dash shell: `apt`, `dpkg`, `sshd` new connection, a `#!/usr/bin/env python3` script. |
| libintl8 0.22 (+ libintl-dev) | no; Procursus `gettext.mk` | medium | First fix the 18-package `libintl.dylib` trap (relink to `libintl.8.dylib`). Then build gettext 0.22 for libintl8 only. Ship the unversioned symlink only in our own `libintl-dev`, never in the runtime package. dpkg, sed, tar and findutils link it. |
| libffi8 3.4.6 | no; Procursus `libffi.mk` | small build, careful test | Same soname `libffi.8`. The risk on iOS is the closure trampoline mode: a build that switches static versus dynamic trampolines can pass every link check and then crash gjs or GObject signal marshalling at run time. Test gjs, an introspected Python call and wayland. |
| liblzma5, libzstd1, liblz4-1 | no; Procursus `xz.mk`, `zstd.mk`, `lz4.mk` | small each | Package-management libraries. liblzma is in wave 1 for its CVE. Bump zstd to 1.5.7 and lz4 to 1.10.0 later, same sonames. Keep `zstd` and `xz-utils` (which pin exact library versions) in step. |
| libgcrypt20 1.10.3 + libgpg-error0 1.48 | no; Procursus mk | medium | apt (through libapt-pkg) and gpgv verify every repo signature with these. A broken libgcrypt means apt rejects every repo, ours included, and you cannot apt your way out. Stay on the 1.10 branch with the CVE-2024-2236 fix first; 1.11/1.12 later. Test `apt update` against both repos with the old debs at hand. |
| libgmp10 6.3.0 | no (no `gmp.mk` under that name in Procursus makefiles) | small | Already current. Own the build so coreutils, nettle/hogweed and mpfr have a maintained source. Same soname. |
| libcrypt2 4.4.36, libmd0 1.1.0, libpam2 | no; Procursus `libxcrypt.mk`, `libmd.mk`, `openpam.mk` | small each | sshd, sudo, system-cmds and dpkg. Build the same versions alongside the openssh batch so those link only our libraries. |
| ncurses 6.4, readline 8.2, libedit, dash, bash, zsh (+ drop libpcre1) | no; Procursus mk | medium | Every login shell. Keep a static or alternate shell reachable while testing. zsh needs a rebuild without PCRE1 (or against pcre2) to retire `libpcre1`. |
| apt, dpkg, gnupg/gpgv, coreutils, ldid, uikittools, launchctl, system-cmds | no; Procursus mk | large, later | Only once the libraries under them are ours. These are the last step to "everything our stack needs is ours". python3 (3.9 is EOL) belongs here too, or we move our few runtime Python scripts to another language. |

### Wave 3: the rest

| Item | Recipe here | Job size | What it takes |
|---|---|---|---|
| libx11-xcb1 | no, but we build libX11 already (shadow `libx11-6`) | small | Emit `libx11-xcb1` from the same libX11 build, and bump the whole set to 1.8.14 together. `libX11-xcb` must match `libX11`, so it cannot move separately. |
| libxcb-shm0, libxcb-randr0, libxcb-res0 | no, but we build libxcb already (shadow `libxcb1`) | small | Same source as our libxcb1. Ship all subpackages from one libxcb build, then bump to 1.17.0 as a set. |
| libxcb-util1, libice6, libsm6, libxi6, libxrandr2, libxrender1, libxtst6 | no (`libxfixes.mk`, `libxcomposite.mk`, `libxshmfence.mk` are the pattern) | small each | Plain autotools X libs. Same sonames across these bumps. |
| libpcre2-8-0, libpcre2-16-0 | no; Procursus `pcre2.mk` | small | 10.49, same sonames. grep and less (base) link pcre2-8 too, so test those. |
| liblzo2-2 2.10 | no | trivial | Upstream has been dormant since 2017. Rebuild once for ownership. |
| libogg0, libopus0, libvorbis0a/enc2 | no; Procursus mk | small | Comes along with the libsndfile work. |

## Loose ends from this pass

- The gsd and EDS rpath bugs above need one on-device confirmation each, followed by a fix in their build scripts. (Fixed in packaging, see below; the device confirmation is still owed.)
- `libwayland-dev`'s `libexpat1-dev` dependency should become `firmware | libexpat1-dev` like fontconfig's, or be dropped. (Dropped, see below.)
- The scanning scripts should become a gate (runtime-deps in `audit-deb-set.py`), so that undeclared and unresolved loads fail before publish rather than after a fresh install.

## Packaging fixes (2026-10-26)

Not published. 36 repacked debs, each at a new version, are in `x11/linux-build/out/loose-ends-20261025/` with a `FIXED.txt` (package, version, sha256, file, change, superseded deb). `tools/repack-loose-ends-20261025.py` made them from the published payloads; the same fixes are in the recipes and control sources, so a rebuild keeps them.

- Missing Procursus Depends: `build_info/*.control` and `stamp-minos.py` `DEPENDS_ADD` now name them (kf6-archive: libzstd1, libssl3; libappstream5, libxmlb2: libzstd1; libexo-2-0, libxfce4ui-2-0, thunar: libice6, libsm6; libaccountsservice0: libcrypt2; libmutter-14-0: libxtst6, libx11-xcb1, libxcb-randr0, libxcb-res0). The tigervnc entries were already in `DEPENDS_ADD` but the published debs were never stamped with them.
- The libintl trap: `recipes/relink-gtkintl.sh` retargets `@rpath/libintl.dylib` to `@rpath/libintl.8.dylib` and adds `Depends: libintl8`. Every one of the 71 loads was dead (no symbol bound from libintl), so the retarget changes nothing at run time beyond making the load resolvable. No package loads `libintl.dylib` any more.
- `libwayland-dev`: `libexpat1-dev` dropped. wayland-scanner links the system `/usr/lib/libexpat.1.dylib`, and no header or `.pc` in the package needs expat.
- EDS: `CMAKE_INSTALL_RPATH` adds `lib/evolution-data-server`.
- gsd: the four plugins' build-tree rpath is replaced with `lib/gnome-settings-daemon-46`.
- libmutter-14-0: `lib/mutter-14` added as an rpath, so its sublibs no longer depend on the launcher's `DYLD_LIBRARY_PATH`. gnome-shell has the same problem for its own binaries and is not fixed here.
- ladybird-tls: `libssl.3.dylib` loads `@loader_path/libcrypto.3.dylib`. There is no ladybird-tls packaging script in the tree, so the rule is a comment in `recipes-ladybird/openssl.mk`.

Each edited Mach-O is re-signed by `tools/resign-like.sh`, which first proves which signer made the shipped file (it re-signs the original and requires identical bytes), so only the load commands differ. The scan re-run over the full index with these 36 swapped in: in the fixed set, 0 unresolved loads (44 before) and 0 undeclared Procursus loads (41 package/library pairs before). Repo-wide, unresolved went from 83 to 39 (gnome-shell 9, gobject-introspection 3, ladybird-app 5, the expected OpenJDK libjvm 22), and the only undeclared Procursus loads left are the three tweaks' ellekit. `audit-deb-set.py`, `check-repo-solvable.py` and `check-ladybird-tls-rpath.py` pass on the set, and `dpkg-deb` extracts all 36 with clean md5sums.
