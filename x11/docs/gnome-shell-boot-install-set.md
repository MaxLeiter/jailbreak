# gnome-shell boot: the ordered install set

The exact set of debs to install on the iPad to boot gnome-shell under Mutter/MetaBackendIOS,
in dependency order. Computed from `linux-build/out/` deb metadata as the runtime dependency
closure of `gnome-shell` + `gnome-session` + `gnome-settings-daemon` + `xios-session-stubs`,
plus the `gi://` boot-blocker client libs the shell imports but does not `Depends:`
(libgdm, libaccountsservice, libupower-glib, libgeocode-glib, libgweather, libgeoclue, gjs,
mozjs). Regenerate with `linux-build/install-gnome-boot.sh` (itself generated from out/).

Pairs with `docs/gnome-session-plan.md` (the launch) and `docs/mutter-on-iosc.md` (the backend).

## How to install

```sh
scp x11/linux-build/out/*.deb root@ipad:/var/jb/tmp/boot/
scp x11/linux-build/install-gnome-boot.sh root@ipad:/var/jb/tmp/boot/
ssh root@ipad 'cd /var/jb/tmp/boot && sh install-gnome-boot.sh && apt-get check'
```

`install-gnome-boot.sh` runs `dpkg -i` over the 66 runtime debs in the order below. It does
**not** call `apt-get -f install` — on this device `--fix-broken` can *remove* libmutter (see
the libwayland note). Verify with `apt-get check` afterward.

## Runtime install order (66 debs, dependencies first)

Icons/base → GL/JS → toolkits → session libs → mutter → shell → gi:// client libs → stubs.

1–10: hicolor-icon-theme, adwaita-icon-theme, angle, dbus, libglib2.0-0, dconf,
libgirepository-1.0-1, gir1.2-freedesktop, gir1.2-glib-2.0, libgtkintl
11–20: libmozjs-115-0, libfontconfig1, libpixman-1-0, libxcb-render0, libcairo2,
libcairo-gobject2, libgjs0, gjs, libglib2.0-bin, libgdk-pixbuf-2.0-0
21–30: libgraphite2-3, libharfbuzz0b, libfribidi0, libpango-1.0-0, libatk1.0-0, libepoxy0,
libxfixes3, libxcursor1, libxinerama1, libgtk-3-0
31–40: libgraphene-1.0-0, libxml2, libxkbcommon0, libepoll-shim0, libwayland0,
libcairo-script-interpreter2, libgtk-4-1, gsettings-desktop-schemas, iso-codes,
libgnome-desktop-4-2
41–50: libjson-glib-1.0-0, gnome-session, libnotify4, libpolkit-gobject-1-0, libpulse0,
gnome-settings-daemon, liblcms2-2, libcolord2, libei1, libmutter-14-0
51–60: libatspi2.0-0, libatk-bridge2.0-0, libgcr-4-4, libpolkit-agent-1-0, libibus-1.0-5,
libstartup-notification0, gnome-shell, libaccountsservice0, libgdm1, libgeoclue-2-0
61–66: libpsl5, libsoup-3.0-0, libgeocode-glib-2-0, libgweather-4-0, libupower-glib3,
xios-session-stubs

`xios-session-stubs` (#66, now 0.1.2) also ships `xios-sysintd` (native-bundle's volume-button
+ iOS dark-mode bridge) alongside the three D-Bus stubs, and its launcher autostarts it; it
Recommends `pulseaudio-utils` (sysintd shells out to `pactl`). The authoritative, versioned
list is in `linux-build/install-gnome-boot.sh` (`$DEBS`).

## Phase-1 install gaps found on-device (2026-07-01), fixed in the script

- **libpulse0**: out/ has two builds — `17.0` and `17.0-1`. The `17.0` archive errors on
  `dpkg -i` ("error processing archive"); `17.0-1` is the fixed rebuild (lib/pulseaudio rpath).
  The script now pins `17.0-1`. gnome-shell + gnome-settings-daemon both hard-Depend libpulse0,
  so the bad `17.0` cascaded them (and the rest of the batch) to unconfigured. Delete the stale
  `libpulse0_17.0_*.deb` from the boot dir to avoid ambiguity.
- **libxcb-util1**: `libstartup-notification0` Depends it (gnome-shell Depends that), but we do
  not build it and it was absent on-device. The script now `apt-get download`s it from the
  device's Procursus sources if absent, and installs it before libstartup-notification0.
- **hicolor / adwaita-icon-theme**: adwaita Depends hicolor. Two issues: (1) an initial cascade
  from the bad libpulse0 archive, and (2) a real FILE conflict — both ship `index.theme` files
  under `/var/jb/usr/share/icons/hicolor/` that `xios-desktop-defaults 1.1.1` also carries. The
  icon-theme packages are the canonical owners and xios theming is applied via gsettings
  overrides (not by owning index.theme), so the script installs with `--force-overwrite`.
  FOLLOW-UP: `xios-desktop-defaults` should `Replaces: hicolor-icon-theme, adwaita-icon-theme`
  (or stop shipping those files) so the flag is not needed — tracked with that package's owner.

### On-device package conflicts (pre-installed xios tracks)

- **PulseAudio**: public installs use the real PA-17 `libpulse0`/`pulseaudio`
  stack. There is no Xios `libpulse-simple` compatibility package in the current
  artifact set.
- **libmozjs-115-0 vs libmozjs-115-jit-0**: EXPECTED, ignore — the JIT variant declares
  `Provides/Conflicts/Replaces libmozjs-115-0` (drop-in), so the dpkg "conflict" line is benign.

## The libwayland-server0 landmine (defused by ordering)

`libmutter-14-0` declares `Depends: libwayland-server0`. We ship no package by that name —
`libwayland0` (#35) `Provides: libwayland-server0` (and ships `libwayland-server.0.dylib`). So
libmutter is satisfiable **as long as libwayland0 installs first**, which this order guarantees.
The historical "libwayland-server0 not installable" break happened only because libmutter was
`dpkg -i`'d before libwayland0 existed on-device. Do not run `apt --fix-broken` to "resolve" it.

## -dev debs for the on-device gir/typelib scan (not needed for boot)

gnome-shell's St/Shell/Gvc/Shew typelibs and the `gi://` client typelibs (AccountsService,
Gdm, UPowerGlib, GWeather, Geoclue) are generated **on-device** by gtk4-gpu's gir batch, which
needs headers + pkg-config from these 8 -dev debs. Install them after the runtime set, before
running the gir batch (they are not required for the daemons to run, only for the scan):

libmutter-14-dev, libgjs-dev, libaccountsservice-dev, libgdm-dev, libupower-glib-dev,
libgeocode-glib-2-dev, libgweather-4-dev, libgeoclue-dev (`$GIR_DEV_DEBS` in the script).

## External Depends — must already be on-device (Procursus base / repo)

35 packages the boot set `Depends:` but that we do not ship (base libs assumed installed):
firmware, fontconfig-config, libffi8, libfreetype6, libgcrypt20, libgpg-error0, libice6,
libintl8, libiosexec1, libjpeg62-turbo, liblzma5, liblzo2-2, libnghttp2-14, libp11-kit0,
libpcre2-8-0, libpng16-16, libsm6, libsndfile1, libsqlite3-1, libtiff5, libuuid16, libx11-6,
libx11-xcb1, libxau6, libxcb-shm0, libxcb-util1, libxcb1, libxdamage1, libxdmcp6, libxext6,
libxi6, libxrandr2, libxrender1, xkeyboard-config (plus the dev-only libintl-dev, unused at
runtime). **`libintl8` is load-bearing**: every deb here `@rpath`-links `libintl.8.dylib`
(the session stubs were explicitly rewired to it, since the unversioned `libintl.dylib` is a
dev-only symlink not shipped at runtime). Confirm `libintl8` is installed before boot.

## Launch (after install + gir scan)

`launch-gnome-session.sh` (shipped by `xios-session-stubs` to `/var/jb/usr/bin`) starts the
login1/polkit/accounts stubs + `xios-hwbridged` (guarded with `-x`; from the xios-fhs hardware
bridge — **not in this set yet**, so the battery indicator stays dark until that deb lands) on
one `dbus-run-session` bus, writes a runtime `org.gnome.Shell.desktop` wrapper
for the requested Wayland display, then runs `gnome-session --builtin
--session=xios` with `RequiredComponents=org.gnome.Shell` only. gsd components
are added to the session file only after the shell is confirmed up. See
`docs/gnome-session-plan.md`.
