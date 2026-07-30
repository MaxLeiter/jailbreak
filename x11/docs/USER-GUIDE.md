# Xios user guide: a desktop on a jailbroken iPad

Install one package, open one app, get a desktop. This guide covers the four desktop
flavors, how to start and stop a session, and what to do when something does not come up.

> Tested on iPadOS 17.6.1, iPad 7th gen, palera1n rootless, Procursus bootstrap. Other
> rootless jailbreaks (Dopamine, RootHide) should work; rooted jailbreaks will not, because
> every binary here bakes in `/var/jb`. Architecture and background: [`../SCOPE.md`](../SCOPE.md).

---

## 1. What you need

| | |
|---|---|
| **Device** | A jailbroken iPad on iOS/iPadOS 16 or newer, rootless (`/var/jb`). GNOME, KDE, and X11 need 16.5; the native flavor needs 16.0. |
| **Package manager** | Sileo, Zebra, or `apt` on the device. |
| **AppSync Unified** | Required. The Xios display app is unsigned, and without AppSync it will not launch. Add `https://cydia.akemi.ai/` as a source and install it first. |
| **Free space** | Installed size is about 190 MB for GNOME and 610 MB for KDE (which brings every KDE app we ship); the native and X11 flavors are around 55 MB. Procursus dependencies add a little on top. |

Nothing here needs a Mac, a VM, or a network hop. Everything is a native arm64 iOS binary
installed from an apt repo.

---

## 2. Add the repo

**In Sileo:** Sources, add `https://repo.maxleiter.com`.

**Or from a shell on the device, as root:**

```bash
cat > /var/jb/etc/apt/sources.list.d/maxleiter.sources <<'EOF'
Types: deb
URIs: https://repo.maxleiter.com
Suites: ./
Components:
Trusted: yes
EOF
apt update
```

One-line equivalent: `deb [trusted=yes] https://repo.maxleiter.com ./`. It is a flat repo,
so the suite is `./`. The metadata is GPG-signed; if you would rather verify it than trust
it blindly, drop the repo key in place of `Trusted: yes`:

```bash
curl -fsSL https://repo.maxleiter.com/maxleiter-repo.gpg \
  -o /var/jb/etc/apt/trusted.gpg.d/maxleiter-repo.gpg
```

Some packages resolve against Procursus (`apt.procurs.us`), which any rootless bootstrap
already has configured.

---

## 3. Pick a flavor

There is no single `xios` package. Install one flavor and it pulls in everything else,
including the shared `xios-core` base and the display app.

| Flavor | What you get | Needs | State |
|---|---|---|---|
| `xios-gnome` | GNOME Shell 46 on Mutter, full session layer, Adwaita theme | iOS 16.5 | Boots and paints on an A10. Daemon and app concurrency still has rough edges. |
| `xios-kde` | KWin plus Plasma Desktop, Plasma Mobile, and Plasma Nano, System Settings, PowerDevil, Breeze, and every KDE app we ship (Konsole, Dolphin, Kate, KWrite, KCalc, Okular, Ark, Gwenview) | iOS 16.5 | Experimental. Newer than the GNOME path and less polished. |
| `xios-native` | No Linux shell at all: each app gets a Home Screen icon and its own iPadOS window | iOS 16.0 | Core path works. Host-window polish in progress. |
| `xios-x11` | The Xios X server for plain X11 apps, plus Xwayland inside the compositor | iOS 16.5 | Works. Software rendering only, by design. |

Every flavor also gets the **iosc desktop**: the compositor's own tablet-first shell with a
panel, dock, overview, and wallpaper. It is the most reliable session and a good first
thing to try.

---

## 4. Install

In Sileo, search for the flavor and install it. Or from a shell, as root:

```bash
apt install xios-gnome
```

Substitute `xios-kde`, `xios-native`, or `xios-x11`. The install brings in, among other
things:

- **`com.max.xios`**, the display app. It appears on the Home Screen as **X11**.
- **`iosc`** and **`iosc-shell`**, the Wayland compositor and its desktop shell.
- **`angle`**, OpenGL ES translated to Metal, which is how anything reaches the GPU.
- **`xios-session`** and **`xios-launcher-tools`**, the session launcher plus the `ioscd`
  daemon that the in-app session picker talks to.
- **`xios-desktop-defaults`**, fonts, locale, XDG paths, and the retina display profile.

Sileo will not auto-install the *recommended* extras. For GNOME those are worth adding by
hand:

```bash
apt install gnome-console nautilus gnome-text-editor gnome-calculator
```

---

## 5. Start a desktop

Two ways in. Both call the same code.

### From the iPad

Open **X11** on the Home Screen and pick a session from the picker. Once a desktop is up:

| Gesture | Does |
|---|---|
| Three-finger tap | Switch between running displays |
| Four-finger tap | Open the session and dimension picker |
| Pinch | Zoom to fit |
| Swipe up from the lower edge | Raise the iOS keyboard |

### From a shell (on device or over SSH), as root

```bash
xios-session iosc            # the iosc desktop shell
xios-session gnome           # GNOME session and Shell
xios-session kde             # KWin plus Plasma Desktop (experimental)
xios-session kde-mobile      # KWin plus Plasma Mobile (experimental)
xios-session kde-nano        # KWin plus Plasma Nano (experimental)
xios-session status          # what the last session did
xios-session stop            # tear it all down, back to SpringBoard
```

Launch a single app against whatever compositor is already running, without restarting the
session:

```bash
xios-session app kgx                  # GNOME Console
xios-session app gnome-text-editor
```

Pick a resolution with environment variables, then re-run or `resize`:

```bash
XIOS_SESSION_WIDTH=1080 XIOS_SESSION_HEIGHT=1440 XIOS_SESSION_DPI=176 xios-session resize
```

> **Keep the screen awake and unlocked while a session starts.** A locked or asleep iPad
> gets the Metal app suspended by FrontBoard, and you will see a black frame instead of a
> desktop.

---

## 6. Flavor notes

**GNOME.** `xios-session gnome` starts the real session manager, then the Shell. The
launcher polls the log and reports honestly: `up` only once the Shell's JS UI has loaded,
`compositor-only` if Mutter came up but the Shell never painted, `error` with the last 40
log lines otherwise.

**KDE.** The Plasma presets nest KWin on top of iosc. Plasma Desktop is the pointer-and-panel
layout; Plasma Mobile is touch-first and the better fit for an iPad. This flavor is the
newest and the least settled, so expect to hit things.

**Native.** There is no desktop environment. Installing the flavor does not create Home
Screen icons by itself: pick which apps you want in the Xios pane in Settings, or run
`xios-launcher-sync` to list, enable, dry-run, and apply. Tap an icon and that Linux app
opens in its own iPadOS window, with Split View and Slide Over as the window manager.

**X11.** The X11 flavor runs clients through rootless Xwayland inside the
GPU-accelerated `iosc` compositor. The legacy software-rendered `xios-server`
package is no longer installed by the flavor; it remains separately available
for bring-up and diagnostics. See [Appendix A](#appendix-a-x-over-vnc) for the
older VNC route, which still works.

---

## 7. Troubleshooting

**The X11 icon does nothing, or the app closes immediately.** AppSync Unified is missing or
the app lost its signature. Reinstall AppSync, then `apt install --reinstall com.max.xios`.

**Black screen with the app open.** The iPad was locked or asleep while the session came
up, or no display server is running. Unlock, then `xios-session status`. If no session is
up, start one.

**Nothing on screen and `status` says `compositor-only`.** The compositor is up but the
shell never painted. Check the log for the flavor you picked.

**Logs.** All under `/var/jb/tmp/`:

| File | What |
|---|---|
| `xios-session.log` | Session bring-up and teardown |
| `xios-session-status.json` | Machine-readable state of the last session |
| `gnome-shell.log` | GNOME Shell output |
| `kde-plasma.log` | KWin and Plasma output |

**A session left something behind.** `xios-session stop` does a full teardown, including
stale compositors and sockets. It is safe to run at any time.

**"Is it running slowly, or did it deliberately slow down?"** `xios-status`. It prints the
latched runtime behaviour of the compositor and the display app — the things that change
by themselves and would otherwise look like a fault:

```
iosc       pacing=vblank fps=30-60/60 interval=16.67ms
Xios       upscale=1440x1080->2160x1620 metalfx-spatial direct
```

`pacing` says whether the repaint is pinned to the display refresh (`vblank`) or falling
back to the event loop, and the frame-rate range CoreAnimation is allowed to settle in —
so a 30fps desktop reads as a decision rather than a stutter. `upscale` says whether the
desktop is being composited below the panel's resolution and scaled up on present; `off`
is the default. Both keys also appear in the logs as `[status]` lines, and
`xios-status <key>` filters. This is distinct from `xios-session status`, which reports
which flavor is up rather than how it is behaving.

**Making it faster on an older iPad.** The A10 iPads are thermally limited before the
desktop does anything, and the 2160x1620 panel is a lot of pixels for them. Two knobs,
both opt-in and both reversible by restarting the session:

| Knob | Effect |
|---|---|
| `IOSC_UPSCALE=auto` | Composite below native and let MetalFX scale up on present. Pair with a lower `IOSC_LOGICAL` — `auto` does nothing on its own if the compositor is already at or above panel resolution. |
| `IOSC_UPSCALE=1.5` | Same, but always: the present pass composites at panel/1.5 regardless of the compositor's resolution. |

Set them in the environment of whatever starts the session, e.g.
`IOSC_LOGICAL=1440x1080 IOSC_UPSCALE=auto xios-session iosc`. Confirm it took effect with
`xios-status upscale`; softer edges are the expected trade. No Wayland client can observe
this — it happens entirely in the display app, after the desktop is composited.

**apt refuses to install a flavor.** Check the iOS floor in the table above. The packages
carry both `MinimumOSVersion` and a `firmware (>= X)` dependency, so an older device is
refused on purpose rather than left to fail at runtime.

---

## Appendix A: X over VNC

The original path, from before the display app existed. Still useful for headless work or
for viewing a session from a laptop.

```bash
# on the iPad, as root
apt install tigervnc-standalone-server x11-fonts-sf xios-desktop-defaults fluxbox xterm x11-apps

export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME=/var/root
mkdir -p /var/jb/var/lib/xkb          # where xkbcomp writes the compiled keymap

Xvnc :1 -geometry 1440x1080 -depth 24 -rfbport 5901 \
     -SecurityTypes None -localhost -AlwaysShared -desktop "iPad X11" &

export DISPLAY=:1
fluxbox &
xterm &
```

`-localhost` keeps it on the device. View it with any iPad VNC client at `127.0.0.1:5901`,
or tunnel from a Mac with `ssh -L 5901:127.0.0.1:5901 root@<ipad>` and open
`vnc://127.0.0.1:5901`. Stop it with `pkill -f 'Xvnc :1'`.

Procursus ships its own `tigervnc-standalone-server`, but that build is uninstallable on
rootless and crashes on startup. The repo's build fixes both; details in
[`procursus-pr-tigervnc.md`](procursus-pr-tigervnc.md).

---

## Appendix B: fonts

`x11-fonts-sf` makes Apple's San Francisco the default: `.SF UI` for sans, serif, and
system-ui, `.SF UI Mono` for terminals and code. It ships no font files, it points
fontconfig at `/System/Library/Fonts`, so it tracks the OS and picks up emoji and CJK for
free. It runs `fc-cache` on install; check with `fc-list | head`.

Without it, Procursus gives you font engines but no fonts, and apps that need core fonts
(`xterm`, for one) will not start. Every flavor pulls it in through `xios-desktop-defaults`.

---

## Reporting problems

Device, iOS version, jailbreak, flavor, what you did, what happened, and the relevant log
from `/var/jb/tmp/`. Issues: https://github.com/MaxLeiter/jailbreak/issues
