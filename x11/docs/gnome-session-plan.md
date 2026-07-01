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

The `org.freedesktop.login1` provider is the existing `xios-login1-stub`
(`x11/wayland/xios-login1-stub.c`, already built and device-ready). Do not rebuild it.

### gnome-session: the non-systemd build

Upstream gnome-session 46 hard-requires systemd/libsystemd (no meson toggle) and drives the
session through `systemd --user` units. iOS has no systemd. The recipe applies
`patches/gnome-session/0001-ios-no-systemd.patch`, which is the FreeBSD-ports non-systemd
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
upower-glib, so `recipes/gnome-settings-daemon-ios-fixes.sh` makes those deps `required:false`
and adds the heavy plugins to `disabled_plugins`. It also retargets gnome-desktop-3.0 -> 4 and
removes gsd's malformed macOS `bundle_loader` ldflag in `plugins/common/meson.build`. Built
with `-Dsystemd=false -Dalsa=false -Dgudev=false -Dwayland=false` and the feature options off.

Only `libnotify` remains to build (housekeeping needs it); `recipes/libnotify.mk` provides it.

gsd is optional for first boot. Its `keyboard` plugin links GTK3-x11 and does X calls; under
a pure Wayland session (no Xwayland) it may warn or no-op. Keep it out of the initial
`RequiredComponents` if the session fails to reach `RUNNING` with it in.

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
| `org.freedesktop.PolicyKit1` | shell polkit agent | polkitd daemon | ABSENT (libs only) |
| `org.freedesktop.Accounts` | shell user widget | accountsservice | ABSENT |

The MUST-HAVES for a first boot are all covered. polkitd and accountsservice are absent; the
shell logs a warning and continues (no privilege-escalation dialogs, no user avatar on the
lock screen). Both can be added later as real daemons or small D-Bus stubs; neither blocks
bring-up.

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

```sh
#!/bin/sh
# launch-gnome-session.sh — bring up a GNOME session under Mutter/MetaBackendIOS on iOS.
set -e
PREFIX=/var/jb/usr

# 1. runtime dir + env
export XDG_RUNTIME_DIR=/var/jb/tmp/xios-run
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY=wayland-0
unset DISPLAY
export GDK_BACKEND=wayland CLUTTER_BACKEND=wayland
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_CLASS=user
export XDG_DATA_DIRS=$PREFIX/share:/var/jb/usr/local/share
export GSETTINGS_SCHEMA_DIR=$PREFIX/share/glib-2.0/schemas
export DYLD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/mutter-14:/var/jb/lib/angle

# 2. write the custom session (org.gnome.Shell only for first boot) into XDG_CONFIG_DIRS
CFG=$XDG_RUNTIME_DIR/xdg
mkdir -p "$CFG/gnome-session/sessions"
cat > "$CFG/gnome-session/sessions/xios.session" <<EOF
[GNOME Session]
Name=Xios GNOME
RequiredComponents=org.gnome.Shell;
EOF
export XDG_CONFIG_DIRS=$CFG:/var/jb/etc/xdg

# 3+4. ONE session bus for everything. The login1 stub must claim org.freedesktop.login1
#      on the SAME bus gnome-session/gnome-shell use, so both run inside a single
#      dbus-run-session. gnome-session (classic path) then starts gnome-shell, which
#      brings up Mutter/MetaBackendIOS + the Xios rendezvous server.
exec dbus-run-session -- sh -c '
  XIOS_LOGIN1_BUS=session /var/jb/usr/libexec/xios-login1-stub &
  sleep 1   # let the stub claim the name before the shell queries it
  exec gnome-session --builtin --session=xios
'
```

Notes:
- The stub and gnome-session share one bus because both live inside the single
  `dbus-run-session` invocation. A stub started before `dbus-run-session` lands on a
  different (or no) bus and gnome-shell's login1 queries fail — this is the one ordering
  trap in the whole launch. `XIOS_LOGIN1_BUS=session` makes the stub claim
  `org.freedesktop.login1` on the session bus (no system bus needed). If the bus should
  outlive one gnome-session run, switch to the manual `dbus-daemon --session
  --print-address` form and start both against the exported `DBUS_SESSION_BUS_ADDRESS`.
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

- gsd plugins beyond the minimal four. power/media-keys/color/datetime/sound are the useful
  ones but each needs a heavy dep (upower client lib, libgeoclue client lib, libcanberra with
  a sound backend, geocode-glib + gweather4). None is needed for a working desktop. Adding
  them is a self-contained follow-up: build those five deps (three are easy: libnotify done,
  geocode-glib and gweather4 are glib+libsoup; two need Darwin client-lib patches: upower and
  geoclue daemons are Linux-only but their client libs are D-Bus proxies), then re-enable the
  plugins in `gnome-settings-daemon-ios-fixes.sh`.
- polkitd and accountsservice daemons. Absent; the shell degrades gracefully. Add later as
  real daemons or small D-Bus stubs (the login1-stub is the model).
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
