# Xios handoff index

One file per domain. Each starts with its current state (checked against `repo/Packages`,
which is what production serves), then gotchas, then a short history. Point one agent at one
file. When a doc and the index disagree, the index wins; fix the doc.

Last full pass: 2026-10-25.

## Device

- iPad7,12 (A10), iPadOS 17.6.1, Dopamine rootless (`/var/jb`), Procursus.
- SSH: `ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@MaxsiPad.local`
- Prefer `x11/bin/xios-device` for status, session launch and switch, input injection,
  screenshots and evidence. See `docs/device-testing.md`. Check whether someone else is
  using the device (apt history, file mtimes) before trusting a test.

## The product

Install one flavor from Sileo and open the X11 icon. The flavor table (what each meta
installs, versions, floors) is in `docs/repo-fold-in.md`; the user-facing version is
`docs/USER-GUIDE.md`.

- `xios-gnome`: GNOME Shell 46 on Mutter's iOS backend.
- `xios-kde`: KDE Plasma (Desktop, Mobile, Nano) as KWin nested in iosc, plus 8 KDE apps.
- `xios-x11`: X11 apps through rootless Xwayland on the iosc desktop.
- `xios-native`: no desktop; each Linux app is its own iPadOS window.

The first three sit on `xios-core` (the Xios app, iosc, iosc-shell, `xios-session`,
`xios-launcher-tools`). All four sit on `xios-runtime` (iosc, ANGLE, D-Bus, audio, FHS
bridges). Several desktops can run at once as slots; the in-app panel (three-finger tap)
picks and switches them.

## Domains

| file | current state (2026-10-25) |
|---|---|
| `xios-app.md` | `com.max.xios 0.1.12` published. The 10-25 ioscd error-message change needs a `MARKETING_VERSION` bump to ship. Hardware input matrix still needs a device run. |
| `iosc-compositor.md` | `iosc 0.9.51` published: fenced triple-buffered output, XWM built in, X windows map on device, one X display per slot. Open: wider XWM coverage, `DISPLAY` on ioscd and shell launches. |
| `iosc-shell.md` | `iosc-shell 0.9.14` published; launches run as `mobile`. Server-side decorations not built. |
| `session-launcher.md` | `xios-session 1.0.82`, `xios-launcher-tools 0.1.12` published: desktops coexist, preflight before teardown, `presets`, per-bus ioscd helpers. The last three are host-tested only. |
| `native-ipados.md` | `xios-native 0.1.8` published; launches by app id work on device. Raw touch and per-bus helpers have no recorded device run. |
| `gnome-session.md` | GNOME Shell 46 (`gnome-shell 46.0+ios3`, `xios-gnome 0.1.12`) boots and runs as a slot. Open: atk-bridge off, calendar off, unpublished gnome-desktop/ibus fixes. |
| `mutter.md` | `libmutter-14-0 46.0+ios11` published. Touch, scroll, IM text and clipboard work. Open: a real Pencil tablet tool. |
| `gtk4-typelibs.md` | Done, packaged as `xios-gnome-typelibs 0.2.0`. Rescans are still a device job. |
| `svg-loader.md` | Done (`librsvg 2.56.5`, pulled in through `xios-desktop-theme`). |
| `kde-kf6.md` | Plasma Desktop, Mobile and Nano plus 8 apps ship as `xios-kde 0.1.21` on `kwin +ios33`. Open: `kwin +ios34` built but unpublished, brightness applet, Nano is first-light only. |
| `polish.md` | Rotation, volume, dark mode, brightness, haptics, clipboard and audio landed. Open: physical checks (UIKit clipboard leg, VoiceOver gestures) and camera. |
| `wayland-apps.md` | First app wave all published and smoke-tested in iosc; the imv wrapper still prefers X11. |
| `wayland-extra-apps.md` | Second wave all published and smoke-tested; waybar is a minimal build, Transmission's GTK client is not built. |
| `geary-webkitgtk.md` | WebKitGTK 2.44.4 and Geary 46 published on an end-of-life engine, with security notices. The multiprocess WebKit smoke is still open. |
| `games.md` | OpenTTD, Warzone 2100 and Crispy Doom run on the device; Wesnoth has never run there; 0 A.D. dropped. Nothing published. |
| `openjdk.md` | Headless OpenJDK 21.0.12+ios1 published and working on the device. Rootful and AWT `+ios2` builds unpublished. |
| `amethyst-minecraft.md` | Host build only; unpublished; never run on the device. |
| `xfce.md` | Only Thunar and its libraries are published. There is no XFCE session. |
| `audit-2026-10-01.md` | The audit's rebuild wave shipped. Still unbumped: waybar, angle, basu, kf6-i18n, KitchenHub, KioskMode, XiosPrefs. Open decisions listed. |
| `loose-ends-audit.md` | Intentional shims (do not "fix" them), remaining port work, and physical checks no one has recorded. |

## Cross-cutting gotchas

- **The Xios app is a package** (`com.max.xios`, pulled in by `xios-core`). Ship it with
  `bin/package-app.sh x11/apps/Xios` and install the deb. Bump `MARKETING_VERSION` in
  `x11/apps/Xios/project.yml` first or apt sees no upgrade. The deb keeps the exec bit and
  the ldid signature, and its postinst runs `uicache -p`. The `bin/install-app.sh` dev loop
  does not: `scp -r` drops the exec bit and `_CodeSignature`, and copying into an existing
  bundle nests it, so `rm -rf` the destination, `chmod +x`, re-sign with the existing
  entitlements, then `uicache -p`.
- **Host-signed binaries can be killed on the device** (exit 137), and installing from a deb
  does not always avoid it. Re-sign on the device when that happens.
- **FrontBoard.** Killing and relaunching the app quickly trips a throttle (no process, no
  crash log); `sbreload` clears it. The app needs the screen awake and unlocked to present.
  A Home Screen tap is more reliable than `uiopen -b` over SSH.
- **Geometry comes from `/var/jb/tmp/xios.json`** (or `xios-<slot>.json`), never a constant.
  iosc's output is logical size times scale and changes on rotation.
- **ioscd and the Xios app ship together.** Picker launches send desktop-file ids, and each
  package Breaks the other's older versions.
- **Public deb filenames are immutable.** Bump the version, never replace bytes. See
  `AGENTS.md` for the publish procedure.
