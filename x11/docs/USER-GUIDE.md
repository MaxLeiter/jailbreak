# X11 on a jailbroken iPad — user guide

Get a real X11 session running on a rootless (palera1n/Dopamine, `/var/jb`) iPad. There are
two ways in:

- **Path A — X over VNC.** Works today. A real X server (`Xvnc`) renders to a virtual
  framebuffer; you view it with any VNC client. This is the recommended way to actually use
  X11 right now.
- **Path B — the native Xios app.** In progress. A native iOS app that renders the X
  framebuffer directly to the screen via Metal (retina) with touch as the pointer. Sideload
  only today — not yet a published package.

> Tested on iPadOS 17.6.1, iPad 7th gen, palera1n rootless, Procursus bootstrap. Background
> and architecture: see [`../SCOPE.md`](../SCOPE.md).

---

## 1. Add the repo

The fixed `tigervnc` and the font package come from **`repo.maxleiter.com`**.

**In Sileo:** Sources → add `https://repo.maxleiter.com`.

**Or from the shell** (rootless paths), drop a source file and update:

```bash
# on the iPad, as root
cat > /var/jb/etc/apt/sources.list.d/maxleiter.sources <<'EOF'
Types: deb
URIs: https://repo.maxleiter.com
Suites: ./
Components:
Trusted: yes
EOF
apt update
```

(One-line equivalent: `deb [trusted=yes] https://repo.maxleiter.com ./`.) It's a flat,
unsigned repo, hence `Trusted: yes`.

> Why a custom repo? Procursus ships `tigervnc-standalone-server`, but that build is
> uninstallable on rootless (a bogus dependency) and crashes on startup (it spawns
> `/bin/sh`, which doesn't exist under `/var/jb`). The repo's build fixes both — details in
> [`procursus-pr-tigervnc.md`](procursus-pr-tigervnc.md). Its version is higher, so `apt`
> prefers it over the Procursus one.

---

## 2. Path A — X over VNC (works now)

### Install

```bash
# on the iPad, as root
apt update
apt install tigervnc-standalone-server x11-fonts-sf xios-desktop-defaults fluxbox xterm x11-apps
```

- `tigervnc-standalone-server` — the fixed `Xvnc` (from `repo.maxleiter.com`).
- `x11-fonts-sf` — makes San Francisco the default font (see §4).
- `xios-desktop-defaults` — retina/Xft/GTK/XDG/session defaults for the Xios distro layer.
- `fluxbox` — a lightweight window manager. `xterm` + `x11-apps` (xeyes/xclock) come from
  Procursus and give you something to look at.

### Start the server

```bash
# on the iPad, as root
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME=/var/root
mkdir -p /var/jb/var/lib/xkb          # where xkbcomp writes the compiled keymap

# xios-desktop-defaults provides profiles: native=2160x1620@264dpi,
# comfy=1440x1080@176dpi, debug=1024x768@96dpi.
Xvnc :1 -geometry 1440x1080 -depth 24 -rfbport 5901 \
     -SecurityTypes None -localhost -AlwaysShared -desktop "iPad X11" &

export DISPLAY=:1
fluxbox &
xterm &                                # and/or: xeyes & xclock &
```

`-localhost` means only on-device clients can connect — nothing is exposed to the network.

### View it

- **On-device:** any iPad VNC client app, pointed at `127.0.0.1:5901` (no password —
  `-SecurityTypes None`).
- **From a Mac (debug):** tunnel it over SSH, then open `vnc://127.0.0.1:5901`:
  ```bash
  ssh -L 5901:127.0.0.1:5901 root@<ipad>     # on the Mac
  ```

### Stop it

```bash
pkill -f 'Xvnc :1'
```

### Rootless notes

- Everything lives under `/var/jb`; `/` and `/bin` are read-only. Keep `/var/jb/usr/bin` on
  your `PATH`.
- If `xios-desktop-defaults` is installed, the launchers source
  `/var/jb/etc/profile.d/xios.sh` and honor `XIOS_DISPLAY_PROFILE=native|comfy|debug`.
- If the keyboard fails to initialize, make sure `/var/jb/var/lib/xkb` exists (the `mkdir`
  above). The old on-device `/bin/sh`→`/var/sh` byte-patch is **obsolete** — the packaged
  `Xvnc` execs `/var/jb/bin/sh` directly.

---

## 3. Path B — the native Xios app (in progress)

**Xios** is a native iOS app that hosts the X server's framebuffer itself: it draws the X
screen to a `CAMetalLayer` at **retina resolution (2160×1620)** and feeds **touches back in
as the X pointer** (via XTEST) — no VNC, no separate viewer. It's the endgame display path;
the VNC route above is the interim.

**Status:** functional and verified on-device, but **not yet packaged as a `.deb`**. Today
you build and sideload it from the Mac:

```bash
# from the repo root, with the iPad reachable over SSH (device.env or THEOS_DEVICE_IP set)
bin/install-app.sh x11/apps/Xios
```

This builds the app (xcodegen + xcodebuild), pseudo-signs it with `ldid` using
`x11/apps/Xios/entitlements.plist`, installs it to `/var/jb/Applications/Xios.app`, and
registers it with `uicache`. Then launch **Xios** from the Home Screen.

Requirements:
- **Mac:** Xcode, `xcodegen`, `ldid`.
- **iPad:** rootless jailbreak + **AppSync Unified** (to run the pseudo-signed app) +
  `uicache` (standard on palera1n).

> Why the special entitlements: a fakesigned app doesn't get GPU access by default, so the
> app explicitly requests the GPU/IOSurface IOKit user clients (without them
> `MTLCreateSystemDefaultDevice()` returns nil → black screen), and reaches `/var/jb` via a
> sandbox path-exception rather than `no-container` (which would also kill GPU access). Full
> rationale and the IOSurface zero-copy design are in [`../SCOPE.md`](../SCOPE.md).

---

## 4. Fonts — San Francisco by default

`x11-fonts-sf` (installed in §2) makes Apple's **San Francisco** the default X11 font:
`.SF UI` for sans-serif/serif/system-ui and `.SF UI Mono` for monospace (terminals, code).

It copies **no font files** — it points fontconfig straight at `/System/Library/Fonts`, so
it always tracks the OS and picks up emoji + CJK for free. After install it runs `fc-cache`
automatically; verify with `fc-list | head`.

Without it, Procursus ships the font *engines* but no font files, and apps that need core
fonts (like `xterm`) won't start.

---

## 5. What's coming

The native app is the foundation for a real iOS-integrated desktop. On the roadmap (see
[`../SCOPE.md`](../SCOPE.md) for detail and status):

- **GTK apps** — a GTK3 stack is being cross-compiled for iOS so GTK/GNOME apps can run.
- **Per-window compositing** — promoting from one fullscreen framebuffer to one surface per
  X window (X Composite → per-window IOSurfaces), so X windows behave like iOS windows.
- **An iOS-native desktop** — hosting X windows in real iOS scenes with the on-screen
  keyboard wired to X, the iOS compositor acting as the desktop shell.

For now, Path A is the way to use X11 on the iPad today; Path B is where it's going.
