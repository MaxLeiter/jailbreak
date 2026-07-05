# Lightweight desktop on the iOS X11 stack — XFCE plan

> **Current status (2026-07-03): historical plan.** This file was written before the GTK3
> packages landed. `libgtk-3-0`/`libgtk-3-dev` now exist in repo metadata, so the old GTK gate is
> closed; verify the current XFCE recipe/package state before treating this as an active build
> checklist.

Goal: a usable **XFCE 4.16** desktop (window manager + panel + desktop + file
manager + settings) running on the native iOS X server (`Xios`, `DISPLAY=:3`),
on top of the GTK3 stack the `gtk-builder` agent is cross-compiling into Procursus
debs. Rootless target (`/var/jb`), iPad 7 / A10, `MEMO_TARGET=iphoneos-arm64-rootless`,
`MEMO_CFVER=1900`.

This began as **Phase-1 prep**: dependency map + build order + drafted recipes. The dependency
map remains useful, but package status has moved since the original GTK-missing snapshot.

---

## Why XFCE (not LXQt, not GNOME)

| Option | Toolkit | New non-trivial deps vs. our stack | Verdict |
|---|---|---|---|
| **XFCE 4.16** | **GTK3** (already being built) | dbus, startup-notification, libwnck3 | **chosen** |
| LXQt | Qt5 (KWin/Qt Widgets) | **entire Qt5 + KF5-ish stack** (not in Procursus) | far heavier |
| GNOME | GTK + Mutter + gjs + logind | Mutter GL/KMS, gjs/SpiderMonkey, systemd-logind | separate track |

XFCE reuses our GTK3/Pango/GDK-Pixbuf/Cairo/X11 stack almost entirely. It is autotools-
based at 4.16 (matches Procursus's heavy autotools tooling), GTK3 throughout (no Wayland,
no GL compositor required), and degrades gracefully when Linux-only bits (udev, logind,
upower, polkit) are absent — those are all *optional* `PKG_CHECK_MODULES` that auto-disable
when the `.pc` is simply missing.

**Version pin: XFCE 4.16.** 4.18 pulls in `libxfce4windowing` + more meson; 4.20 is meson-
everywhere + early Wayland. 4.16 is the cleanest first target. Bump later.

---

## What's already in Procursus (cascades for free)

Confirmed present as recipes in `procursus-work/makefiles/` — these build automatically as
dependencies, no new recipe needed:

- Core: `glib2.0` (2.78), `gettext`, `libffi`, `pcre2`, `expat`, `libxml2`
- Render/text: `cairo`, `harfbuzz`, `freetype`, `fontconfig`, `libpixman`, `libepoxy`,
  `libpng16`, `libjpeg-turbo`, `libtiff`, `openjpeg`
- X11: `libx11`, `libxext`, `libxcb` (+ `xcb-util*`, `xcb-proto`, `xtrans`), `libxrender`,
  `libxrandr`, `libxinerama`, `libxcursor`, `libxfixes`, `libxdamage`, `libxi`, `libxres`,
  `libxtst`, `libxkbfile`, `libxft`, `libxpm`, `libxmu`, `libxt`, `libsm`, `libice`,
  `libxss`, `xkbcomp`, `xkeyboard-config`, `xauth`
- Our additions (the GTK track, owned by `gtk-builder`): `fribidi`, `pango`, and the
  in-flight `gdk-pixbuf` / `atk` / `gtk+3.0`.

## What is MISSING and needs a NEW recipe

Three **non-XFCE** deps are not in Procursus and block XFCE:

| Dep | Needed by | Why required | Recipe |
|---|---|---|---|
| **dbus** | `xfconf` (hard), session bus | XFCE config (`xfconfd`) is a D-Bus service; the whole DE talks over the **session bus**. No way around it. | `recipes/dbus.mk` |
| **libwnck3** | `xfwm4` (hard), panel/session/xfdesktop (pager, tasklist, window menu) | client-window list / WM-hints library | `recipes/libwnck3.mk` |
| **startup-notification** | `xfwm4`, `libxfce4ui`, panel | launch feedback (busy cursor); xfwm4 expects it | `recipes/startup-notification.mk` |

Optional / deferred (auto-disabled if absent — add later for polish):
`libnotify` (+ a notification daemon), `libxklavier` (keyboard-layout switching),
`shared-mime-info` (Thunar file typing), `hicolor-icon-theme` + an icon theme
(e.g. Adwaita/elementary-xfce) for *visible* icons, `upower`/`polkit`/`libgtop`
(power, privileges, system monitor). None block first boot.

> **iOS caveats baked into the recipes:** Thunar's `gudev` (udev) is Linux-only — absent,
> auto-disabled (no device mounting; local browse only). `xfce4-session`'s logind/ConsoleKit
> integration is absent (we launch components directly, not via a seat). `xfwm4` compositor
> is **disabled** for first bring-up (`--disable-compositor`) — our DDX doesn't expose X
> Composite/GLX yet (SCOPE Stage 3). Re-enable once per-window compositing lands.

---

## Dependency-ordered build plan

Build strictly in this order (each `*-package` target builds its deps first via the
recipe `NAME:` prerequisites; `AFTER_BUILD,copy` stages headers/.pc into `BUILD_BASE`
so the next component's `configure`/`meson` finds them in-tree — even though we omit the
`-dev` debs, see Packaging).

```
                 [ glib2.0, cairo, pango, gdk-pixbuf, atk, gtk+3.0 ]   <-- gtk-builder
                 [ libx11, libxres, libxext, libsm/ice, xrandr, ... ]  <-- Procursus
                                   |
   ── new deps ──┐                 |
   dbus  startup-notification  libwnck3 (meson)
        |             |            |
        v             v            v
 1. libxfce4util  ───────────────────────────────────────────────┐
 2. xfconf            (needs glib gio; xfconfd is a dbus service)  │
 3. libxfce4ui        (gtk3 + libxfce4util + xfconf + startup-not) │
 4. garcon            (menu lib; glib + gtk3 + libxfce4util)       │
 5. exo               (gtk3 + libxfce4util + libxfce4ui)           │
 6. xfce4-panel       (+ garcon + exo + libwnck3 + xfconf)         │  all depend
 7. xfwm4             (+ libwnck3 + startup-notification)          │  upward on
 8. thunar            (+ exo; gudev/libnotify absent → off)        │  1–5
 9. xfce4-settings    (+ exo + xfconf + garcon + libX11/Xi/Xrandr) │
10. xfce4-session     (+ libsm/ice + xfconf)                       │
11. xfdesktop         (+ garcon + exo + xfconf + libwnck3)         │
12. xfce4-appfinder   (+ garcon + libxfce4ui + xfconf)  [bonus]    ┘
```

`TARGETS` to feed the Docker build (after GTK debs land), in order:

```
dbus-package startup-notification-package libwnck3-package \
libxfce4util-package xfconf-package libxfce4ui-package garcon-package exo-package \
xfce4-panel-package xfwm4-package thunar-package xfce4-settings-package \
xfce4-session-package xfdesktop-package xfce4-appfinder-package
```

### GTK dependency status

Everything from `libxfce4ui` onward needs `libgtk-3-0` + `libgdk-pixbuf-2.0-0` + `libatk1.0-0`
at link time. Those GTK3 packages now exist, so this is no longer the blocker it was when the
plan was drafted. `libxfce4util`, `xfconf`, `dbus`, and `startup-notification` still remain the
lowest-risk early components because they need only glib/X11/expat.

Historical sequencing message to coordinator was: *"build dbus + startup-notification +
libxfce4util + xfconf now (GTK-independent); hold libwnck3 + the GTK-linked XFCE components
until gtk-builder publishes `libgtk-3-0`."* That hold is now stale; check current recipe/deb
state before resuming the XFCE lane.

---

## Packaging strategy (deliberate simplification)

Procursus's `PACK` macro needs a `build_info/<pkg>.control` template per `.deb`. To keep the
first desktop lean we ship **one "fat" runtime `.deb` per component** (library + binaries +
data together) and **omit the `-dev` split**. Rationale: end users install a desktop, they
don't compile XFCE on-device; and the in-tree build chain gets headers/.pc from
`AFTER_BUILD,copy` into `BUILD_BASE`, not from the `-dev` debs. Each recipe strips
`include/`, `lib/pkgconfig`, and `*.a` out of the shipped package.

Provider package names (Debian-ish, used in `Depends:`):
`dbus`, `libwnck-3-0`, `libstartup-notification0`, `libxfce4util7`, `xfconf`,
`libxfce4ui-2-0`, `libgarcon-1-0`, `libexo-2-0`, `xfce4-panel`, `xfwm4`, `thunar`,
`xfce4-settings`, `xfce4-session`, `xfdesktop4`, `xfce4-appfinder`.

A thin `xfce4` metapackage (Depends on all of the above) is provided at
`packages/xfce4/DEBIAN/control` — a control-only deb (no payload) for `apt install xfce4`.
It deliberately does **not** pull an X server; start one separately.

> Drafts, not final: tarball filenames, exact soname/dylib version numbers, and a few
> `configure` flag spellings should be re-verified at first build (they're noted inline).
> These recipes are written to be *close enough to compile*, with iOS-specific flags set.

---

## Launching the desktop (runtime)

The X server (`Xios`) owns `DISPLAY=:3`. This is implemented as **`bin/xfce-up.sh`** — a
*session* launcher layered on top of the X-server launchers (it requires an X server already
up on `:3`, started by `apps/Xios/xios-server.sh` or `x11-server.sh`, and does not duplicate
that logic; it takes the screen from their throwaway fluxbox via `xfwm4 --replace`). The
sequence it runs:

```sh
export DISPLAY=:3
export XDG_DATA_DIRS=/var/jb/usr/share        # dbus service files + .desktop + icons
export XDG_CONFIG_DIRS=/var/jb/etc/xdg
export XDG_RUNTIME_DIR=/var/jb/var/run/user    # mkdir -p, 0700

# 1. machine-id (once) and the session bus
dbus-uuidgen --ensure=/var/jb/var/lib/dbus/machine-id
eval "$(dbus-launch --sh-syntax)"             # exports DBUS_SESSION_BUS_ADDRESS/_PID
#   xfconfd is D-Bus-activated from $XDG_DATA_DIRS/dbus-1/services/org.xfce.Xfconf.service

# 2. settings daemon, then WM, then shell
xfsettingsd &                                  # applies xfconf settings (theme, dpi, kbd)
xfwm4 --replace &                              # window manager (compositor disabled)
xfce4-panel &                                  # top/bottom panel
xfdesktop &                                    # wallpaper + desktop menu/icons
# xfce4-appfinder  -> app launcher on demand
```

Skip `xfce4-session` for the first smoke test (it adds SM/ICE + autostart + logout plumbing
that wants a seat); drive the components directly as above. Wire `xfce4-session` in once the
manual stack is proven.

### Keyboard / input

Input comes from the **iOS-native keyboard via XTEST** injected by `Xios` (see the
keyboard track / task #2): XFCE/GTK apps receive ordinary X `KeyPress`/`KeyRelease`
events — GTK text entries, `xfce4-appfinder`, Thunar rename, etc. "just work". Requires the
XKB keymap to compile on-device, which the **rootless `/bin/sh` → `/var/jb/bin/sh` xserver
patch (SCOPE Stage 0, blocker #2) already fixes** — `xkbcomp` is spawned the same way.
Default `us` layout (no `libxklavier` ⇒ no in-DE layout switcher yet; switch via
`setxkbmap`). Pointer/scroll come from the touch→pointer mapping `Xios` already implements.

### Fonts & icons

Fonts: the published **`x11-fonts-sf`** package (San Francisco as default) already satisfies
fontconfig — XFCE text renders without extra work. Icons: **none are installed yet**. For a
*visible* (not blank) panel/menu, add `hicolor-icon-theme` (fallback) **+ a real icon theme**
later; until then XFCE falls back to text/missing-image icons. Tracked as deferred above.

---

## Open risks / to verify at build time

1. **dbus on iOS rootless.** Session bus over a unix socket in `/var/jb/var/run/dbus` should
   work; `dbus-daemon` must be code-signed (recipe signs with `general.xml`). Autolaunch via
   launchd is **disabled** (`--disable-launchd`) — we start it explicitly. Verify `dbus-launch`
   finds the daemon and that a `machine-id` exists.
2. **xfconfd D-Bus activation path.** The service file installs to `/var/jb/usr/share/dbus-1/
   services`; ensure `XDG_DATA_DIRS` includes `/var/jb/usr/share` so the session bus finds it,
   else `xfconfd` won't auto-spawn (settings won't persist).
3. **libwnck3 ↔ our X server.** wnck reads `_NET_*`/EWMH hints; xfwm4 sets them. Should be fine
   on a standards-compliant Xvfb-derived server, but pager/tasklist are the first things to
   break if EWMH is incomplete.
4. **xfwm4 without compositor.** Plain WM works; no shadows/transparency. Fine for bring-up.
5. **Thunar with no udev/gvfs.** Local filesystem browsing only; no removable-media mounting.
6. **Soname/dylib versions** in the `cp -a .../lib*.N.dylib` lines are best-guesses per XFCE
   4.16 sonames — confirm against the staged tree on first build and adjust the glob.
```
