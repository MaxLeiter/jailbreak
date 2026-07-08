# Rehosted Procursus dependencies

To make `repo.maxleiter.com` self-contained, the X11/font/desktop libraries our
published packages depend on are mirrored here from Procursus
(`apt.procurs.us 1900/main iphoneos-arm64`) instead of being resolved live from
that repo. This means a clean install of our X stack no longer breaks if
`apt.procurs.us` is down or drops an old version.

These debs are byte-for-byte the Procursus binaries, only **recompressed from
zstd to gzip** so `bin/lib/make-repo.py` can parse their control archives (its
`control_dict()` uses Python `tarfile`, which has no zstd support). Recompression
was done with the `procursus-xbuild:bookworm-arm64` container's `dpkg-deb`
(`dpkg-deb -R` then `dpkg-deb -Zgzip --build`); the unpacked file tree and all
control metadata (Depends, md5sums, maintainer scripts) are unchanged. Each ar
now contains `control.tar.gz` + `data.tar.gz` and validates with `dpkg-deb -I`.

## What's rehosted vs. what's not

The set below is the **runtime dependency closure** of our published packages
**minus the Procursus base bootstrap**. The base boundary was computed
empirically on-device as the recursive dependency closure of `apt` itself
(`apt-cache depends --recurse … apt`): anything `apt` needs is guaranteed
present on every Procursus/Dopamine jailbreak, so it is never rehosted.

Our published packages and their roots into this closure:

- **tigervnc-standalone-server** → xauth, libgl1 (→ libgl1-mesa-glx),
  libgeneral0, libjpeg62-turbo, libpixman-1-0, libx11-6, libxau6, libxdmcp6,
  libxdamage1, libxfont2, xkbcomp, xkeyboard-config
- **x11-fonts-sf** → fontconfig
- **x11-xvfb** → libxfont2, libpixman-1-0, libxau6, libxdmcp6, xkbcomp,
  xkeyboard-config, xauth
- **tigervnc-common** → (only base `libiosexec1`; nothing rehosted)

**Deliberately NOT rehosted** (base bootstrap — already on every jailbreak via
`apt`'s own closure): `libiosexec1`, `libmd0`, `libgnutls30`, `libpam2`,
`libpam-modules`, `libintl8`, `libbrotli1`, `libzstd1`, `liblz4-1`, `liblzma5`,
`libgmp10`, `libnettle8`, `libhogweed6`, `libidn2-0`, `libunistring5`,
`libtasn1-6`, `libffi8`, `libp11-kit0`, `ca-certificates`, and `firmware`.
Notably `fontconfig`'s alternative dep `firmware (>= 14.0) | libexpat1` is
satisfied by the base `firmware` package, so `libexpat1` is not needed.

**Not rehosted for a different reason — a real Procursus package, resolved
live**: `qt6-base`'s `Depends: libpcre2-16-0` is outside the X11/font closure
this doc tracks, but it's not a gap either. `libpcre2-16-0` is a genuine
Procursus binary (built by their `pcre2.mk`, `--enable-pcre2-16
--enable-pcre2-32`, one of five sibling packages alongside
`libpcre2-{8,32}-0`/`libpcre2-posix3`/`libpcre2-dev`/`pcre2-utils`), confirmed
present on the live index as of 2026-07-08:
`apt.procurs.us` dist `1900/main iphoneos-arm64`, `libpcre2-16-0` v10.43,
`Filename: pool/main/iphoneos-arm64-rootless/1900/pcre2/libpcre2-16-0_10.43_iphoneos-arm64.deb`,
`Depends: libiosexec1 (>= 1.3.1)` only (already in the apt-closure list above).
Any rootless-1900 device with the standard Procursus source configured
resolves it there; no repo action needed.

## Rehosted packages (26)

All `iphoneos-arm64` except `libx11-data` and `xkeyboard-config` which are
`all`. Versions are the current Procursus candidates as of fetch.

| Package | Version | Size | Pulled in by / role |
|---|---|---:|---|
| libx11-6 | 1.7.3.1 | 692 KB | Core Xlib — direct dep of tigervnc + transitively everything |
| libx11-data | 1.7.3.1 | 171 KB | Locale/Compose data for libx11-6 (`= 1.7.3.1`) |
| libxau6 | 1.0.9-1 | 9 KB | X11 authorization records; via libxcb1, xauth, xvfb, tigervnc |
| libxdmcp6 | 1.1.3 | 9 KB | X Display Manager Control Protocol; via libxcb1, tigervnc, xvfb |
| libxcb1 | 1.14 | 53 KB | X C Binding transport under libx11-6 |
| libxext6 | 1.3.4-1 | 26 KB | X11 misc extensions; via libgl1-mesa-glx, xauth |
| libxdamage1 | 1.1.5 | 5 KB | X Damage extension — direct dep of tigervnc |
| libxfixes3 | 5.0.3 | 9 KB | X Fixes extension; via libxdamage1 |
| libxfont2 | 2.0.4 | 98 KB | Server-side font handling — direct dep of tigervnc + xvfb |
| libfontenc1 | 1.1.4 | 11 KB | Font encoding tables; via libxfont2 |
| libxkbfile1 | 1.1.0 | 58 KB | XKB keymap file parsing; via xkbcomp |
| libxmuu1 | 1.1.3-1 | 7 KB | Mini-Xmu utility lib; via xauth |
| libfreetype6 | 2.12.1 | 317 KB | FreeType font rasterizer; via libxfont2 + fontconfig |
| libpng16-16 | 1.6.37-2 | 101 KB | PNG decode; via libfreetype6 |
| fontconfig | 2.14.0 | 78 KB | Font config tools — direct dep of x11-fonts-sf |
| libfontconfig1 | 2.14.0 | 155 KB | Fontconfig runtime lib; via fontconfig |
| fontconfig-config | 2.14.0 | 72 KB | Fontconfig config files; via fontconfig/libfontconfig1 |
| libuuid16 | 1.6.2-3 | 23 KB | UUIDs for fontconfig cache; via libfontconfig1 |
| libjpeg62-turbo | 2.0.6 | 127 KB | JPEG codec — direct dep of tigervnc (framebuffer encode) |
| libpixman-1-0 | 0.40.0 | 132 KB | Pixel compositing — direct dep of tigervnc + xvfb |
| libgl1-mesa-glx | 21.0.2 | 2.4 MB | Mesa GLX/libGL — satisfies tigervnc's `libgl1` |
| libglapi-mesa | 21.0.2 | 36 KB | Mesa GL dispatch; via libgl1-mesa-glx (`= 21.0.2`) |
| xauth | 1.1 | 23 KB | `xauth` cookie tool — direct dep of tigervnc + xvfb |
| xkbcomp | 1.4.5 | 85 KB | XKB keymap compiler — direct dep of tigervnc + xvfb |
| xkeyboard-config | 2.32 | 555 KB | XKB keymap data — direct dep of tigervnc + xvfb |
| libgeneral0 | 56-1 | 17 KB | Procursus support lib — direct dep of tigervnc |

Total ≈ 5.0 MiB across 26 debs.

### Notes on two borderline inclusions

- **libgeneral0** and **libuuid16** are not strictly X11/font libraries, but
  both are real runtime deps (libgeneral0 is a direct dep of
  tigervnc-standalone-server; libuuid16 is pulled by libfontconfig1) and neither
  appears in `apt`'s base closure. They are small and were rehosted for
  guaranteed self-containment rather than assumed present.

## Reproduce

```sh
# on the device (apt configured for Procursus); no install, no dpkg lock needed
apt-get download \
  fontconfig fontconfig-config libfontconfig1 libfontenc1 libfreetype6 \
  libgeneral0 libgl1-mesa-glx libglapi-mesa libjpeg62-turbo libpixman-1-0 \
  libpng16-16 libuuid16 libx11-6 libx11-data libxau6 libxcb1 libxdamage1 \
  libxdmcp6 libxext6 libxfixes3 libxfont2 libxkbfile1 libxmuu1 xauth \
  xkbcomp xkeyboard-config

# on the Mac, per deb: recompress zstd -> gzip (keeps tree + control unchanged)
docker run --rm -v "$PWD":/work procursus-xbuild:bookworm-arm64 -c '
  for f in /work/in/*.deb; do
    d=$(mktemp -d); dpkg-deb -R "$f" "$d"
    dpkg-deb -Zgzip --build "$d" "/work/out/$(basename "$f")"; rm -rf "$d"
  done'
```
