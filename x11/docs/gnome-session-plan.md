# GNOME session layer on iOS: build notes and launch plan

This document covers the packages that turn the bare `gnome-shell` binary into a full,
usable GNOME session on jailbroken iOS (rootless `/var/jb`), and the exact steps to launch
that session under Mutter with the MetaBackendIOS backend.

It pairs with:
- `docs/mutter-on-iosc.md` (the compositor and MetaBackendIOS backend)
- the memory notes `x11-mutter-backend-code`, `x11-distribution-chooser`, `x11-gnome-desktop-feasibility`

## What a GNOME session needs above gnome-shell

`gnome-shell` is the Wayland compositor (Mutter) plus the JS shell UI. On its own it starts,
but a real login session also wants:

1. A session manager that owns `org.gnome.SessionManager`, tracks the running components,
   handles logout/inhibit, and starts the other pieces. That is `gnome-session`.
2. A settings daemon (`gnome-settings-daemon`, gsd) that applies desktop policy: keyboard,
   accessibility, media keys, power, color, and so on. gsd is a set of D-Bus-activated helper
   daemons, one per plugin.
3. A session D-Bus bus and the small services the shell talks to at runtime: dconf (settings
   persistence), the accessibility bus, and a `org.freedesktop.login1` provider.

gnome-shell does not hard-require gsd. The session boots and is usable without it; you lose
media-key handling, automatic idle dimming, and the XSETTINGS bridge for legacy X clients.

## Packages built for the session layer

All cross-built for `iphoneos-arm64` (rootless) on `procursus-vol-shell`. Recipes live in
`linux-build/recipes/`, debs in `linux-build/out/`.

| Package | Version | Role |
|---|---|---|
| `gnome-session` | 46.0 | session manager (`gnome-session-binary` + wrapper + inhibit/quit) |
| `dconf` / `dconf-dev` | 0.40.0 | GSettings dconf backend + `dconf-service` (settings persistence) |
| `libnotify4` / `libnotify-dev` | 0.8.3 | desktop notification client (used by gsd housekeeping and by apps) |
| `gnome-settings-daemon` | 46.0 | minimal gsd (a11y-settings, housekeeping, keyboard, screensaver-proxy) |
| `libaccountsservice0` / `-dev` | 23.13.9 | **BOOT-CRITICAL** client lib — gnome-shell imports gi://AccountsService at boot |
| `libgdm1` / `libgdm-dev` | 46.0 | **BOOT-CRITICAL** client lib — gnome-shell imports gi://Gdm at boot (5 files) |

Three D-Bus stub daemons stand in for the freedesktop services that have no daemon on iOS
(pure GLib/GIO, built by `x11/wayland/build-session-stubs.sh`, packaged as `xios-session-stubs`
to `/var/jb/usr/libexec` alongside `launch-gnome-session.sh` in `/var/jb/usr/bin`):

| Stub | Provides | Why |
|---|---|---|
| `xios-login1-stub` | `org.freedesktop.login1` | session/seat/user/inhibitors for gnome-session/gsd/Mutter; reports the real user |
| `xios-polkit-stub` | `org.freedesktop.PolicyKit1` | auto-allow (single-user root); shell polkit agent registers, no auth hang |
| `xios-accounts-stub` | `org.freedesktop.Accounts` | one user, so the shell shows a real name (else it degrades to blank) |

The login1 and accounts stubs share `xios-session-identity.c`, which resolves the logged-in
user once (uid/username from passwd, display name from the MobileGestalt device name, home,
`~/.face` avatar, locale) so the shell shows a real identity across the login1 `User` object
and the Accounts `RealName`/`IconFile`/`Language`.

### libgdm: the fifth boot-blocker

gnome-shell statically `import Gdm from 'gi://Gdm'` in five boot-path files (`js/misc/
dependencies.js`, `js/misc/systemActions.js`, `js/ui/unlockDialog.js`, `js/gdm/loginDialog.js`,
`js/gdm/util.js`), so the Gdm-1.0 typelib must exist or the shell throws at module load. We
build ONLY gdm's client library, `libgdm` (clean client/daemon split): the top-level
`meson.build` is replaced with a client-only one (the daemon hard-probes udev/pam/gtk3/xcb/
logind), and the sd-login C API the client uses (`libgdm/gdm-sessions.c`, `common/gdm-common.c`)
is satisfied by a single-session shim compiled into `libgdmcommon` — the same pattern as
libaccountsservice. Built with no version-script (Apple ld) and no cross gir; the **Gdm-1.0
typelib is generated ON-DEVICE**. At runtime there is no display-manager daemon, so `Gdm.Client`
simply fails to connect and the shell's greeter/lock paths degrade, which is correct for a
jailbreak session. Recipe: `recipes/libgdm.mk` + `ports/libgdm/patches`.

### libaccountsservice: the hidden boot-blocker

gnome-shell's `js/ui/panel.js` -> `status/system.js` -> `js/misc/systemActions.js` has a static
top-level `import AccountsService from 'gi://AccountsService'`. panel.js loads at boot, so in
gjs the missing typelib throws at module load and the shell crashes building the top panel.
accountsservice is NOT a gnome-shell build dependency (it is a runtime gi:// import only), so
the gnome-shell build never pulled it and the sysroot had no libaccountsservice at all.

We build the client library only. The accounts-daemon is Linux-only (utmp/crypt/shadow) and
is dropped; the library's systemd sd-login use (seat/session enumeration, no #ifdef) is
satisfied by a single-session shim compiled straight in (session id "1", seat "seat0", uid
getuid(), class "user", state "active"), so it links with no libsystemd. Built
`-Dintrospection=false`; **the AccountsService-1.0 typelib is generated ON-DEVICE** (the
St/Shell/Mutter pattern), so the on-device gir pipeline must scan AccountsService-1.0 from the
shipped lib + headers. Without that typelib on-device the shell still will not boot.

### gnome-session: the non-systemd build

Upstream gnome-session 46 hard-requires systemd/libsystemd (no meson toggle) and drives the
session through `systemd --user` units. iOS has no systemd. The recipe applies
`ports/gnome-session/patches/0001-ios-no-systemd.patch`, which is the FreeBSD-ports non-systemd
patch set (it reverts upstream's "Drop consolekit backend and hard depend on systemd" commit)
adapted to the 46.0 tree, built with:

```
-Dsystemd=false -Dsystemd_session=disable -Dsystemd_journal=false
-Dconsolekit=false -Dsession_selector=false -Ddocbook=false -Dman=false
```

With `systemd_session=disable`, `ENABLE_SYSTEMD_SESSION` is undefined, so `main()` skips the
systemd-unit launch path and falls straight to the classic manager: `gsm_manager_new(...,
FALSE)` reads `RequiredComponents` from the chosen `.session` file and spawns each component
as a child process (the XSMP plus autostart way). A `--builtin` flag is also compiled in.

Two more iOS edits in the same patch:
- `gnome-desktop-3.0` is retargeted to `gnome-desktop-4`. We ship only the GTK4/base
  gnome-desktop library; it exports the two symbols gnome-session uses
  (`gnome_idle_monitor_new`, `gnome_start_systemd_scope`), verified in the built dylib.
- the three `gnome-session-check-accelerated*` GL helpers are dropped. They need desktop GL
  (`gl.pc`), GLX and xcomposite, none of which exist on the iOS ANGLE-Metal stack. They are
  also dead code in a Wayland session: `main.c:check_gl()` returns early when `DISPLAY` is
  unset, so the helper is never spawned.

The main `gnome-session-binary` never calls `gtk_init`. GTK3 is linked only by the separate
`gnome-session-failed` fail-whale binary, which is an error-path dialog. So a normal Wayland
boot never touches our X11-only GTK3.

### gnome-settings-daemon: the minimal build

The gsd core daemon links only `gio`. Every heavy top-level dependency (geocode-glib,
gweather4, libcanberra, libgeoclue, upower-glib) is consumed only by plugins. We keep the
plugins that make sense on a Wayland tablet and drop the rest:

- KEEP: `a11y-settings`, `housekeeping`, `keyboard`, `screensaver-proxy`
- DROP: `power` (no upower/backlight), `color` (no colord/geoclue), `datetime` (no
  geoclue/gweather/timedated), `media-keys` (gvc/upower/canberra), `sound` (canberra/alsa),
  `xsettings` (X11-only, no display in a Wayland session), `sharing` (NetworkManager), plus
  the option-gated `print-notifications` (CUPS), `rfkill`, `wwan`, `smartcard`, `wacom`,
  `usb-protection`.

The dropped plugins are the only consumers of geocode-glib, gweather4, libcanberra and
upower-glib, so `ports/gnome-settings-daemon/patches` makes those deps `required:false`
and adds the heavy plugins to `disabled_plugins`. It also retargets gnome-desktop-3.0 -> 4 and
removes gsd's malformed macOS `bundle_loader` ldflag in `plugins/common/meson.build`. Built
with `-Dsystemd=false -Dalsa=false -Dgudev=false -Dwayland=false` and the feature options off.

Only `libnotify` remains to build (housekeeping needs it); `recipes/libnotify.mk` provides it.

gsd is optional for first boot. Its `keyboard` plugin links GTK3-x11 and does X calls; under
a pure Wayland session (no Xwayland) it may warn or no-op. Keep it out of the initial
`RequiredComponents` if the session fails to reach `RUNNING` with it in.

### Disabled gsd plugins — resolution backlog

The seven dropped plugins are tracked here so they are not silently degraded. Status is one of
IN PROGRESS, QUEUED (a re-enable follow-up), or LEAVE (documented, intentionally not shipped).
The disable itself lives in `ports/gnome-settings-daemon/patches`.

| Plugin | Status | Plan |
|---|---|---|
| `power` | IN PROGRESS | Battery + brightness. UPower comes from `xios-hwbridged` (IOKit shim, xios-fhs) already wired into the launch; the brightness slider needs the `power` plugin un-dropped. That un-drop is a real port, not a flip: gsd-power hard-includes `libgnome-desktop/gnome-rr.h` (RandR, removed from our GTK4 `gnome-desktop-4`) and `gtk/gtk.h` (its GTK daemon skeleton). Section 5 of the ios-fixes script already excises the plugin's libcanberra (no-op stub) and raw-X11 screensaver/DPMS (gated behind `!__APPLE__`) as dormant groundwork; finishing means gating all `gnome_rr_*` out of gsd-backlight.{c,h} + gpm-common.c + gsd-power-manager.c (the Darwin backlight backend reading `/var/jb/sys/class/backlight/xios_backlight/{brightness,max_brightness}` replaces the RandR fallback) and resolving the GTK skeleton. Coordinate with xios-fhs (task #15). |
| `media-keys` | RESOLVED (stays dropped) | The iPad's only hardware media keys are the volume buttons, and `xios-sysintd` (native-bundle, bundled + autostarted in `xios-session-stubs`) bridges them straight to the PulseAudio `xios` sink via `pactl`, so gvc/panel volume tracks the buttons end-to-end without gsd. `gsd-media-keys` stays dropped (it would only add its libcanberra dep back for no gain). The one thing the bridge doesn't draw is the on-screen volume OSD popup — a cosmetic follow-up if ever wanted, not a re-enable. |
| `sound` | QUEUED | Event sounds + volume feedback. The PA daemon exists (audio-desktop track, `libpulse0`/`pulseaudio` shipped), so re-enable `gsd-sound` once a canberra sound backend routes to PA (it links libcanberra + ALSA; we build `-Dalsa=false`, so it needs a PA/canberra path). |
| `datetime` | QUEUED (low) | Read the iOS timezone + a simple NTP sync. Stock gsd-datetime hard-needs timedated + geoclue (for auto-timezone); the lightweight path is to skip geoclue and just surface the iOS timezone, so this is a small custom bit rather than the full plugin. |
| `color` | LEAVE | No colorimeter hardware; colord/geoclue absent. Nothing to manage. |
| `xsettings` | LEAVE | X11-only (bridges XSETTINGS to legacy X clients). A pure Wayland session has no X display; not needed. |
| `sharing` | LEAVE | Drives NetworkManager-based network sharing; no relevant iOS sharing target. |

## Session component graph and the custom .session

The stock `gnome.session` lists these `RequiredComponents`:

```
org.gnome.Shell;org.gnome.SettingsDaemon.A11ySettings;...Color;...Datetime;...Housekeeping;
...Keyboard;...MediaKeys;...Power;...PrintNotifications;...Rfkill;...ScreensaverProxy;
...Sharing;...Smartcard;...Sound;...UsbProtection;...Wacom;...XSettings;
```

gnome-session shows the fail-whale (and can abort the session) if any RequiredComponent fails
to start. We do not ship most of those gsd components, so do NOT launch the stock session.

Instead launch a custom `xios.session` that lists only what we ship. Minimal first-boot form:

```ini
[GNOME Session]
Name=Xios GNOME
RequiredComponents=org.gnome.Shell;
```

Once gsd is confirmed to start cleanly, extend it:

```ini
[GNOME Session]
Name=Xios GNOME
RequiredComponents=org.gnome.Shell;org.gnome.SettingsDaemon.A11ySettings;org.gnome.SettingsDaemon.Housekeeping;org.gnome.SettingsDaemon.ScreensaverProxy;
```

`org.gnome.Shell` resolves to `org.gnome.Shell.desktop` (shipped by gnome-shell,
`Exec=/var/jb/usr/bin/gnome-shell`); each gsd component resolves to
`org.gnome.SettingsDaemon.*.desktop` (shipped by gsd). gnome-session searches
`$XDG_CONFIG_DIRS/gnome-session/sessions` then `$XDG_DATA_DIRS/gnome-session/sessions` for
`<name>.session`, and the component `.desktop` files under the autostart / applications dirs.

Drop `xios.session` into a runtime config dir and point `XDG_CONFIG_DIRS` at it (the launch
script below writes it), so no repackage of gnome-session is needed to change the component
list.

## Runtime D-Bus session services: what the shell needs, what provides it

| D-Bus name | Needed by | Provider | Status |
|---|---|---|---|
| `org.gnome.SessionManager` | gnome-shell | gnome-session | built |
| `org.freedesktop.login1` | shell, gsd | `xios-login1-stub` | built |
| `ca.desrt.dconf` | GSettings writes | `dconf-service` | built now |
| `org.a11y.Bus` | shell, GTK | at-spi2-core (`at-spi-bus-launcher`) | present |
| `org.freedesktop.Notifications` | apps | gnome-shell itself | provided |
| `org.gnome.Mutter.*` (DisplayConfig, IdleMonitor) | shell, gsd | Mutter (in gnome-shell) | provided |
| `org.gnome.ScreenSaver` | apps | gnome-shell / gsd screensaver-proxy | provided |
| `org.freedesktop.PolicyKit1` | shell polkit agent | `xios-polkit-stub` (auto-allow) | built |
| `org.freedesktop.Accounts` | shell user widget + libaccountsservice | `xios-accounts-stub` | built |
| `org.freedesktop.UPower` | shell battery indicator, gsd-power | `xios-hwbridged` (IOKit-backed, from xios-fhs) | optional |

`org.freedesktop.UPower` is optional for a bare boot (the shell just hides the battery
indicator without it) but cheap: `xios-hwbridged` from the xios-fhs hardware-bridge package
claims UPower itself with a GDBus shim backed by IOKit `IOPSCopyPowerSourcesInfo`, exposing the
`DisplayDevice` + `battery_BAT0` + `line_power_AC0` objects with the full `UpDevice` property
set the shell's `UpClient` and gsd-power read (no upower daemon; the `UPowerGlib` client lib is
unchanged). The launch script starts it if installed.

The MUST-HAVES for a first boot are all covered. The polkit + accounts stubs are optional for
a bare boot (the shell degrades: no auth dialogs, blank user name) but are cheap and remove
the warnings / possible auth hangs, so the launch script starts them. Note the libaccountsservice
CLIENT LIBRARY (above) is NOT optional: the shell imports its typelib at boot regardless of
whether the accounts daemon is running.

## Environment

A GNOME session on our stack runs as a set of Wayland clients of Mutter/MetaBackendIOS, which
presents into the Xios IOSurface. The environment:

```sh
# Runtime dir (private, 0700) and the Wayland socket that MetaBackendIOS/Mutter listens on.
export XDG_RUNTIME_DIR=/var/jb/tmp/xios-run     # mkdir -p, chmod 700
export WAYLAND_DISPLAY=wayland-0                 # Mutter is the display server

# GNOME is a Wayland session. Leave DISPLAY UNSET (gnome-session check_gl() and the GTK3
# fail-whale key off it; unset keeps everything on the Wayland path).
unset DISPLAY

# Toolkit backends.
export GDK_BACKEND=wayland
export CLUTTER_BACKEND=wayland
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=GNOME
export XDG_SESSION_CLASS=user

# Schemas + data. XDG_DATA_DIRS must include our prefix so the shell/gsd find schemas,
# .desktop, icons, and the session/component files.
export XDG_DATA_DIRS=/var/jb/usr/share:/var/jb/usr/local/share
export GSETTINGS_SCHEMA_DIR=/var/jb/usr/share/glib-2.0/schemas

# Our custom session lives in a runtime XDG_CONFIG_DIRS entry.
export XDG_CONFIG_DIRS=$XDG_RUNTIME_DIR/xdg:/var/jb/etc/xdg

# dyld: gnome-shell + Mutter + gsd + ANGLE. Match the mutter smoke env.
export DYLD_LIBRARY_PATH=/var/jb/usr/lib:/var/jb/usr/lib/mutter-14:/var/jb/lib/angle

# Fonts/render already handled by xios-desktop-defaults.
```

Settings now PERSIST (dconf is built). If dconf-service is not running for any reason,
GSettings falls back to the in-memory backend and writes are lost across restarts, but the
session still runs. Do not force `GSETTINGS_BACKEND=memory` unless debugging.

## The D-Bus session bus

GNOME needs a session bus. Two options:

1. Simplest, proven with kgx: wrap the whole launch in `dbus-run-session`. It starts a private
   session bus, exports `DBUS_SESSION_BUS_ADDRESS`, runs the command, and tears the bus down
   on exit.
2. Manual: `dbus-daemon --session --print-address` and export the address yourself. Use this
   only if you need the bus to outlive a single `gnome-session` run.

Because MetaBackendIOS runs INSIDE the gnome-shell process (gnome-shell IS Mutter here), the
compositor and the session share one process tree and one bus. So the bus must exist before
gnome-shell starts. `dbus-run-session -- gnome-session ...` gives exactly that ordering.

## Launch sequence

Order matters: the login1 stub and the D-Bus bus must exist before gnome-session, and
gnome-session starts gnome-shell (which brings up Mutter/MetaBackendIOS and the Xios
rendezvous server). The Xios app must be running to display the output IOSurface.

The implementation lives in
`packages/xios-session-stubs/var/jb/usr/bin/launch-gnome-session.sh` and the
matching package template under `packages/templates/xios-session-stubs/`. Keep
the doc at the invariant level instead of copying the whole script here. The
launcher must:

- inherit `WAYLAND_DISPLAY`, `XIOS_JSON_PATH`, `XIOS_DDX_SOCKET`,
  `XIOS_INPUT_SOCKET`, and `GNOME_SHELL_LOG` from `xios-session`;
- re-sign `gnome-shell` with the GPU/JIT entitlement set needed by
  Mutter/MetaBackendIOS on iOS;
- start login1/polkit/accounts/BlueZ/hardware/audio shims inside the same
  `dbus-run-session` tree as `gnome-session`;
- write a temporary `xios.session` with `RequiredComponents=org.gnome.Shell;`;
- write a temporary `org.gnome.Shell.desktop` wrapper so `gnome-session` starts
  `gnome-shell --wayland --wayland-display "$WAYLAND_DISPLAY"`;
- detach, wait briefly for `xios.json` + the Mutter DDX socket, hand the DDX
  socket to mobile, relaunch Xios, and then return so `xios-session` can poll
  the standard status signal.

Notes:
- The stubs and gnome-session share one bus because they all live inside the single
  `dbus-run-session`. login1/polkit/accounts are system-bus services; setting
  `DBUS_SYSTEM_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS` makes both the stubs (which default to
  `G_BUS_TYPE_SYSTEM`) and their clients resolve the system bus to this session bus, so no
  real system bus is needed. This is the one ordering trap in the whole launch: a stub started
  before `dbus-run-session` lands on a different (or no) bus. (Each stub also accepts
  `XIOS_<NAME>_BUS=session` to force the session bus directly.) If the bus should outlive one
  gnome-session run, use `dbus-daemon --session --print-address` and start everything against
  the exported address.
- Deploy the three stub binaries to `/var/jb/usr/libexec/` (built to `out/` as
  `xios-{login1,polkit,accounts}-stub`).
- `gnome-session --builtin` forces the classic non-systemd manager even though the build
  already defaults to it (belt and suspenders).
- The Xios app must be launched (it reads `/var/jb/tmp/xios.json` and displays the IOSurface).
  gnome-shell (via MetaBackendIOS) creates the output IOSurface and writes that rendezvous
  file, exactly as the standalone `mutter --wayland` smoke does.
- Signing: gnome-shell/Mutter need the GPU + task-port entitlements (`iosc-gl-ent.xml`, the
  server+GPU union), same posture as the `mutter` smoke binary. gnome-session, gsd, dconf and
  the login1 stub are plain daemons and take the general ad-hoc signature.
- Schemas: run `glib-compile-schemas /var/jb/usr/share/glib-2.0/schemas` once after installing
  the debs (each package's postinst does this, but do it once by hand if installing loose).

## What is deferred, and why

- gsd plugins beyond the minimal four. Tracked per-plugin in "Disabled gsd plugins —
  resolution backlog" above (power in progress; media-keys/sound/datetime queued;
  color/xsettings/sharing leave-with-reason). None is needed for a working desktop. The
  five client-lib deps that the queued plugins want (upower-glib, libgeoclue, geocode-glib-2,
  gweather-4, libnotify) are already BUILT.
- polkitd and accountsservice daemons. The real daemons are Linux-only; we ship auto-allow /
  single-user D-Bus stubs (`xios-polkit-stub`, `xios-accounts-stub`) instead, which is enough
  for the shell. Swap in real daemons only if per-action policy or multi-user is ever wanted.
- The AccountsService-1.0 typelib must be generated ON-DEVICE (the gnome-shell gir pipeline
  must scan it from libaccountsservice-dev, alongside St/Shell/Shew/Gvc). The library ships;
  the typelib does not (cross-build cannot run g-ir-scanner on a Mach-O target).
- Calendar (evolution-data-server) stays patched out of gnome-shell until ICU lands, per the
  distribution-chooser decision.

## Open risks (device-runtime only)

- gsd `keyboard` links GTK3-x11 and does X calls; under Wayland with no Xwayland it may fail
  to init. Mitigation: it is out of the first-boot `RequiredComponents`; add it only after the
  shell is confirmed up.
- gnome-session's fail-whale (`gnome-session-failed`) is GTK3-x11 and will not render in a
  Wayland session with no X display. That path only triggers on session failure, so it is a
  worse error message, not a new failure mode. The real signal is the gnome-session log.
- The dbus/login1 shared-bus ordering (see the launch notes) is the one fiddly part of the
  script; verify `busctl --user list` shows `org.freedesktop.login1` owned before gnome-shell
  queries it.
