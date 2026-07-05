# GNOME on the X11-for-iOS stack — feasibility & staged plan

Status: **Historical feasibility baseline; not current status.** Owner: `gnome-track`.
Context: rootless palera1n iPad 7 (A10, iPadOS 17.6.1, `/var/jb`), Procursus bootstrap,
cross-compiled in the `linux-build/` Docker pipeline. The GTK3 stack
(fribidi→pango→gdk-pixbuf→atk→gtk3) is being built in parallel by `gtk-builder`. Display is
the native **Xios** server (Xvfb/kdrive-derived, software-only) per [`SCOPE.md`](../SCOPE.md).

> **Current status (2026-07-03): superseded as a status source.** This file is the original
> GNOME feasibility baseline. The gjs/SpiderMonkey and GObject-Introspection gates it called
> hard blockers are solved; GNOME Shell 46 has first light on-device. Use
> [`docs/handoff/gnome-session.md`](handoff/gnome-session.md),
> [`docs/handoff/mutter.md`](handoff/mutter.md), and [`gjs-plan.md`](gjs-plan.md) for current
> GNOME Shell work. Use [`gnome-apps.md`](gnome-apps.md) plus repo metadata for current app
> package status.

---

## TL;DR — the verdict

Two very different targets hide under the word "GNOME":

| Target | Verdict | One-line reason |
|---|---|---|
| **GNOME *apps* under a light WM or iosc** | **Built/published in part** | The GTK4/libadwaita app chain moved from plan to package output; remaining work is per-app smoke, featuring, and meta-package policy. |
| **GNOME *Shell* (the full session)** | **First light achieved** | gjs/mozjs and typelibs are solved, Mutter-on-iOS exists, and direct plus daemon `xios-session gnome` launches reach a running Shell. Remaining work is polish and missing service shims. |

**Historical recommendation:** this doc correctly argued for staging apps before the Shell, but
the staging has moved forward. Current GNOME work is no longer blocked on gjs or base typelibs;
pick up from the handoff docs instead of restarting the research spike below.

> **Synergy with the in-flight XFCE track.** A sibling agent is already cross-compiling
> **XFCE** (xfwm4/xfce4-panel/xfce4-session/thunar/xfconf/dbus/…). XFCE is the pragmatic proof
> that a *full GTK3 desktop environment* runs on this stack while **dodging every GNOME hard
> blocker**: it is GTK3 (no GTK4 needed), C (no gjs/SpiderMonkey), needs no introspection
> typelibs, uses its own `xfwm4` WM (no Mutter/Cogl/EGL), stores settings in `xfconf` (no hard
> dconf dependency), and runs its session without systemd/logind. **GNOME *apps* can run inside
> that XFCE session.** So the realistic near-term "Linux desktop on iOS" is *XFCE + selected
> GTK apps*; GNOME Shell remains the stretch research goal. The `dbus` they build is shared
> infrastructure both tracks sit on.

### One hard constraint that framed the original X11-Shell plan: the GNOME version

This original X11-oriented plan assumed **glib 2.78 → the GNOME 45 generation**. Current app and
Shell work has moved to GNOME 46 components on the iosc/Mutter-on-iOS path, so treat the X11
version argument below as historical context rather than the active strategy. It mattered because:

- **GNOME 49 (Sept 2025) disabled the X11 session by default**; it is being removed entirely
  in GNOME 49/50. Mutter keeps a `-Dx11=true` build option only through **GNOME 48**, after
  which gnome-shell is **Wayland-only**.
- Therefore **gnome-shell-as-an-X11-WM only exists through GNOME 48.** Targeting GNOME 45
  (which our glib already pins) keeps the X11 session on the table. **We must never chase
  GNOME ≥49 for the shell** — it would force Wayland, which we do not have.

Input is a non-issue at every stage: the native iOS keyboard → XTEST path (SCOPE Stage 4)
feeds X clients regardless of WM/shell, so none of this depends on solving X input.

---

## The floor: what Procursus gave us at the time

This was verified against the upstream Procursus repo index (`apt.procurs.us` dist `1900`,
`iphoneos-arm64`, 1369 packages) **and** the recipe clone
(`linux-build/procursus-work/makefiles/`, 614 recipes). It is a historical upstream-baseline
inventory, not the current local repo state.

**Prebuilt debs we can `apt install` today (the foundation):**
`libglib2.0-0/-dev/-bin` (2.78), `libcairo2` (+`-gobject`/`-script`), `libfontconfig1`,
`libfreetype6`, `libharfbuzz0b` (+icu/subset/gobject), `libgcrypt20`, `libpixman-1-0`,
`libvterm0`, software **mesa** (`libgl1-mesa-glx`, `libgles2-mesa`, `libglapi`, GLU/GLEW),
the **full X11 client stack** (libX11/xcb/Xext/Xi/Xtst/Xrandr/Xfixes/Xdamage/Xcursor/Xrender/
Xinerama/Xss/Xft/Xcomposite + xcb-* helpers), `xkbcomp`, `x11-apps`, `xterm`, **`fluxbox`**.

**Not prebuilt, but a recipe exists → cascades in our pipeline:**
`pcre2`, `libffi`, `gettext`, `gnutls`/`nettle`, `libxml2`, `icu4c`, `libepoxy`, `graphite2`,
`expat`, **`gobject-introspection`** (recipe present but **disabled — see Blocker #2**),
plus the in-flight GTK3 recipes (`pango`/`gdk-pixbuf`/`atk`/`gtk+3.0`).

**Absent from upstream Procursus at the time (no deb, no recipe) — these became the local
gnome-track build surface:**
**`dbus`** (!), `dconf`, `gsettings-desktop-schemas`, `at-spi2-core`, `json-glib`,
`libsoup`, `librsvg`, `gcr`/`libsecret`, `polkit`, `accountsservice`, `gvfs`,
`adwaita-icon-theme`/`hicolor-icon-theme`, `shared-mime-info`, `desktop-file-utils`,
`graphene`, **GTK4**, `libadwaita`, `gnome-desktop`, `gnome-settings-daemon`,
`gnome-session`, **`mutter`**, **`gnome-shell`**, **`gjs`/`mozjs`**, and every GNOME app
(nautilus, gnome-terminal, gnome-text-editor, …).

> The single most surprising gap is **D-Bus**: Procursus is a minimal CLI bootstrap and ships
> no `dbus` at all. Nothing GNOME runs without a session bus, so **`dbus` is the first brick.**
> It is also *easy* (C + expat, both buildable) — a draft recipe is included here.

---

## The dependency tree, by layer

Each layer depends on the ones above. "★" = a true hard blocker (its own section below).

```
Layer 0  FOUNDATION (have / cascades)
  glib2.0 ─ gobject ─ gio ─ pcre2 ─ libffi ─ gettext ─ libxml2 ─ expat
  cairo ─ pango(building) ─ harfbuzz ─ freetype ─ fontconfig ─ fribidi
  X11 client libs ─ pixman ─ software mesa (GL/GLES, llvmpipe)

Layer 1  GTK + IMAGING
  gdk-pixbuf(building) ─ atk(building) ─ gtk+3.0(building)
  librsvg (Rust; SVG icon loader)            ── MEDIUM (Rust cross)
  shared-mime-info, desktop-file-utils,      ── EASY (data/tools)
  hicolor-icon-theme, adwaita-icon-theme
  ── for modern apps ──
  graphene ─ GTK4 ─ libadwaita                ── MEDIUM (big, but mechanical)

Layer 2  SESSION MIDDLEWARE (the freedesktop plumbing)
  ★ dbus  ── EASY to build, but UNPACKAGED; everything needs it
  dconf ─ gsettings-desktop-schemas           ── EASY (C+glib / data)
  json-glib                                   ── EASY
  at-spi2-core (a11y bus)                      ── EASY-MED (optional: NO_AT_BRIDGE=1)
  libsoup3, gcr, libsecret, gsound, libnotify ── MEDIUM
  gvfs                                         ── MEDIUM (mounts/backends)

Layer 3  SESSION / POLICY (systemd-coupled — the murky zone)
  ★ logind   → no systemd on device; needs elogind or a stub
  polkit     → system bus + PAM + setuid helper
  accountsservice → wants logind/elogind
  gnome-settings-daemon, gnome-desktop, gnome-session
        → GNOME 45 increasingly assumes `systemd --user`

Layer 4  THE SHELL
  ★ gjs  →  ★ mozjs115 (SpiderMonkey, JIT-less)
  ★ gobject-introspection typelibs (Mach-O / qemu problem)
  ★ mutter (Cogl/Clutter on software GLX, no EGL)
  gnome-shell (JS, on gjs, consuming typelibs for GTK+Mutter+Clutter+…)
```

---

## The hard blockers, honestly

### Historical Blocker #1 — SpiderMonkey / gjs (the shell's language runtime)

> **Current status:** solved for the baseline path. `libmozjs-115-*` and `gjs` packages exist,
> and gjs has run JS plus GI imports on-device. Keep the notes below as the original risk model.

`gnome-shell` is written in JavaScript on **gjs**, which embeds **SpiderMonkey**. Our glib
2.78 pins gjs 1.78 → **mozjs115 (ESR 115)**.

- **JIT is forbidden on iOS.** A fakesigned app gets no dynamic-codesign / RWX. SpiderMonkey
  *can* build interpreter-only: `--disable-jit` / `--disable-ion` selects the portable C++
  interpreter (codegen "none"). This is a real, supported configuration — it's exactly what
  the old `play-co/spidermonkey-ios` / GameClosure builds did, and what mozjs does on
  architectures with no JIT backend. **Correctness is fine; speed is the cost** (interpreter
  is several× slower — gnome-shell animations would be sluggish but functional).
- **The cross-compile is the pain, not the JIT-less part.** mozjs115's build (`mach`/
  `moz.configure`) wants **Rust + cargo + cbindgen + autoconf2.13 + python3 + clang/llvm**.
  Documented cross-compiles are Linux→Linux/aarch64. **Linux→Apple Mach-O** is far less
  trodden (Homebrew/MacPorts build mozjs *on* macOS, not cross). Expect to fight: host-tool
  vs target-tool confusion, Rust's `aarch64-apple-ios` std target + the cctools linker,
  `//` host-build artifacts, and SpiderMonkey's habit of running just-built tools.
- **Historical difficulty: HIGH — the single hardest cross-compile in the tree.** Tractable (Rust is
  available in Procursus via `rust.mk`; the JIT-less path is proven), but a multi-week spike.
- **Scope:** this used to block the *shell only*. Plain GTK *apps* are C and never touch gjs.

### Historical Blocker #2 — GObject-Introspection typelibs for Mach-O

> **Current status:** solved by native on-device scanning. The old cross-build objection below
> was accurate for qemu-on-Linux, but the iPad can run the Mach-O scanner dumpers directly.

This is the *less obvious* shell blocker and, in some ways, the nastier one.

- Bindings-based code (all of gjs, hence gnome-shell) loads **`.typelib`** files at runtime
  for every library it touches (Gtk, Gdk, Mutter, Clutter, Cogl, Soup, …). Typelibs are
  produced by **`g-ir-scanner`**, which **compiles and *runs* a small dumper linked against
  the target library** to extract enum values, struct sizes, etc.
- Cross-compiling, the dumper is a **target** binary. The standard fix is to run it under
  **qemu-user** — but **qemu-user only executes Linux ELF, not iOS Mach-O.** So the usual
  trick is unavailable for our target.
- Tellingly, **Procursus's own `gobject-introspection.mk` has `SUBPROJECTS += …` commented
  out** — i.e. it is not actually wired into the build. The C libraries that *can* skip
  introspection do (our `pango.mk` builds with `-Dintrospection=disabled`), which is fine for
  C apps but fatal for gjs.
- **Proven escape:** generate GIRs/typelibs **natively on the
  iPad** (it *is* arm64 Mach-O — `g-ir-scanner` can run there), then fold them into the debs —
  abandons pure cross-repro for the introspection step only. Other historical options were
  (b) build the dumpers for and
  run them on an **Apple-Silicon host** if the iOS/macOS ABI proves close enough for the
  scanned values (risky); (c) hand-author/patch typelibs (impractical at GNOME scale).
- **Historical difficulty: HIGH. Co-equal with #1 as a shell gate.** Note it is *independent* of gjs:
  even a perfect mozjs build is useless to gnome-shell without typelibs.

### Historical Blocker #3 — Mutter on software GLX, no EGL, no KMS

> **Current status:** the active Shell path moved to Mutter-on-iOS/iosc instead of this X11/GLX
> compositor strategy. `libmutter-14-*` packages exist, and GNOME Shell first light has been
> reached through the iosc path.

Our mesa is built **software-only**: `-Dgallium-drivers=swrast` (llvmpipe),
`-Dglx=gallium-xlib` (indirect software GLX via Xlib), `-Dosmesa=true`, **no EGL, no GBM, no
KMS, no Wayland** (see `linux-build/procursus-work/makefiles/mesa.mk`).

- Mutter's **native** backend (KMS/DRM + GBM + logind for DRM-master/seat) is **out** — no
  DRM on iOS, no logind.
- The viable path is Mutter as the **X11 WM/compositor** (the classic "GNOME on Xorg"
  session): here mutter is a *client* of our X server, not a display server, so it needs **no
  DRM, no GBM, no DRM-master**. Cogl supports a **GLX winsys** with desktop GL ≥ 1.3; llvmpipe
  advertises GL 4.x/GLSL 3.30, so the GL *version* is sufficient. Mutter only forces EGL "when
  drawing using GLES" — with desktop GL it can take the **GLX** path our mesa provides.
- **Unknowns:** whether mutter 45's Cogl still happily initialises over *indirect* software
  GLX (gallium-xlib) specifically, and whether performance (full-screen software-composited
  GL) is bearable on an A10. **Verdict: feasible-with-major-work / unproven.** Needs an actual
  spike once the rest exists. Building mutter needs `-Dx11=true` (present through GNOME 48).
- **Scope: shell only.** Plain GTK apps under fluxbox/twm use the X server's own rendering;
  **they need no Cogl, no EGL, no mutter.**

### ★ Blocker #4 — logind / systemd / the session daemons

No systemd, no logind on a jailbroken iPad.

- **GNOME dropped ConsoleKit in 2015; it has needed logind since.** The non-systemd world
  (Gentoo/Alpine/Void/FreeBSD) runs GNOME via **elogind** (logind split out of systemd).
  `accountsservice` and `gnome-session`/`gsd` expect logind to be present.
- On iOS there is no VT/seat/DRM for elogind to manage, so even elogind is a **stretch** —
  most likely a **stub `org.freedesktop.login1`** D-Bus service that answers the handful of
  calls gsd/gnome-session actually make (session/seat objects, `Inhibit`, idle).
- **polkit** wants a system bus + PAM + a setuid helper — heavy and largely pointless on a
  single-user jailbreak; likely stubbed/skipped.
- GNOME 45 is mid-migration toward **`systemd --user`** for session startup, which we cannot
  provide; the older `gnome-session`-spawns-everything path still exists in 45 but is fading.
- **Scope: full-session only.** Apps don't need any of it (worst case: a couple of warnings).

### D-Bus — listed for completeness, but *not* a hard blocker

`dbus` used to be simply **unpackaged**, not hard. It is now packaged alongside `dconf`,
`gsettings-desktop-schemas`, and `gnome-session`. A **session bus runs fine without systemd**
via `dbus-run-session` / `dbus-launch --autolaunch`; the **system** bus is mostly irrelevant to
plain apps. The only iOS caveat is the usual epoll/kqueue/launchd-autolaunch portability, long
since solved by historical jailbreak dbus ports.

---

## Tractable now vs blocked

| Component | Class | Notes |
|---|---|---|
| **dbus** | ✅ tractable | C+expat; draft recipe shipped. Build first. |
| **gsettings-desktop-schemas** | ✅ tractable | Data-only schemas; draft recipe shipped. |
| **dconf** | ✅ tractable | C+glib (GDBus, not libdbus); draft recipe shipped. Runtime-needs dbus. |
| json-glib, libnotify, shared-mime-info, desktop-file-utils, hicolor/adwaita icons | ✅ tractable | Small C / data; no target-binary exec. |
| at-spi2-core | ✅ tractable | dbus a11y bus; or disable with `NO_AT_BRIDGE=1`. |
| librsvg | 🟡 medium | Rust cross (`rust.mk` exists) **or** pin C-only **2.40.x**. Needed for SVG/symbolic icons. |
| graphene, GTK4, libadwaita | 🟡 medium | Big but mechanical; required for *modern* GNOME apps. |
| libsoup3, gcr, libsecret, gvfs | 🟡 medium | Standard deps for richer apps. |
| **gobject-introspection typelibs** | ✅ solved | Generated/scanned on-device for the base, GTK4/libadwaita, and Shell boot batches. |
| **gjs / mozjs115** | ✅ solved | JIT-less mozjs115 and gjs built, packaged, installed, and smoke-tested on-device. |
| **mutter** | 🟡 first light | Mutter-on-iOS/iosc path has booted Shell; ongoing work is compositor/session polish, not the old software-GLX question. |
| **logind / accountsservice / polkit / gnome-session** | 🟡 stubbed | Single-user/session shims are enough for first light; finish only what the running Shell still needs. |
| **gnome-shell** | 🟡 first light | Direct and daemon `xios-session gnome` reach `state=up` with `gnome-shell 46.0+ios3`; remaining work is polish, service shims, and repeated-picker UX. |

---

## GTK3 vs GTK4 — historical planning fork

> **Current status:** GTK4/libadwaita is no longer hypothetical. GTK4, libadwaita, GNOME apps,
> and GTK4 typelibs have been built; this section is retained to explain why the project pivoted
> toward modern GNOME apps instead of stopping at the older GTK3 app set.

The early `gtk-builder` track started with **GTK3**, but **GNOME migrated almost everything to
GTK4 by GNOME 42**. In the GNOME 45/46 generation:

- **GTK4 / libadwaita:** nautilus (Files), gnome-console (kgx), **gnome-text-editor**,
  gnome-calculator, eog→Loupe, gnome-system-monitor, most "Apps."
- **Still GTK3:** **gnome-terminal** (vte-gtk3), **gedit** (maintained, still GTK3 in this
  era), and the wider non-GNOME GTK3 ecosystem (geany, gimp 2.10, pcmanfm, mousepad,
  galculator).

**Implication:** GTK3 alone reaches **gnome-terminal + gedit** and little else GNOME-branded.
For the *real* modern GNOME app experience (Files, Console, Text Editor) we will need to build
**graphene + GTK4 + libadwaita**. That stack is "medium" (large but no exotic blockers) and is
the highest-leverage next investment after the foundation. Recommend treating **GTK4 as a
first-class follow-on to the GTK3 build**, not an afterthought.

The old GTK3-only first targets were `gnome-terminal`, `gedit`, and `gtk3-demo`. The current
app validation order lives in [`gnome-apps.md`](gnome-apps.md), biased toward built GTK4 apps
such as `gnome-console`, `gnome-text-editor`, `d-spy`, `file-roller`, and `nautilus`.

---

## Staged plan (historical path)

> **Current status:** Stages A-D below have mostly landed in some form. Use this as a dependency
> rationale, not an active checklist.

**Stage A — Foundation bus + settings (tractable now).**
Build `dbus`, then `dconf` + `gsettings-desktop-schemas`, then `shared-mime-info`,
`desktop-file-utils`, `hicolor-icon-theme`, `adwaita-icon-theme`, `json-glib`. Validate a
session bus with `dbus-run-session` on-device. *Draft recipes for the first three ship with
this doc.* No GTK, no shell, no logind. **This is the only stage that should start before
GTK3 lands.**

**Stage B — First GTK3 apps under fluxbox.**
After `gtk-builder`'s GTK3 lands: add `librsvg` (icons), `at-spi2-core` (or `NO_AT_BRIDGE=1`),
`vte` (gtk3), then **gnome-terminal** and **gedit**. Run them as plain X clients under the
already-packaged **fluxbox**. Settings persist via dconf; bus via dbus-run-session. **This is
"GNOME apps on iOS" — the realistic near-term win.** No mutter, no gjs, no logind.

**Stage C — GTK4 + libadwaita → modern GNOME apps.**
Build `graphene` → **GTK4** → **libadwaita**, plus `libsoup3`/`gcr`/`libsecret`/`gvfs` as
apps demand. Unlocks **Files (nautilus), Console (kgx), Text Editor, Calculator**. This is the
big mechanical lift that makes it *feel* like GNOME. Still no shell.

**Stage D — Shell prerequisites, as isolated research spikes (do NOT gate C on these).**
Two independent spikes, runnable in parallel, each de-risked alone before any session work:
- **D1 — typelibs:** solve gobject-introspection for Mach-O (native on-device scan is the most
  promising). Deliverable: working `.typelib`s for Gtk/Gdk/GLib.
- **D2 — gjs:** cross-compile **mozjs115 JIT-less**, then **gjs**; run a hello-world gjs
  script consuming a typelib from D1. Deliverable: gjs executes GI-bound JS on-device.

**Stage E — GNOME Shell attempt.**
The original X11/GLX Shell attempt has been superseded by the Mutter-on-iOS/iosc path. Direct
`xios-session gnome` now reaches first light; remaining GNOME Shell work is tracked in
[`docs/handoff/gnome-session.md`](handoff/gnome-session.md).

---

## Draft recipes shipped with this doc

New, GTK-independent, clearly-tractable Procursus recipes (Stage A), authored to mirror the
house style of `recipes/pango.mk` / `recipes/fribidi.mk` (meson `cross.txt`, `.build_complete`
guard, `*-package` → `SIGN`/`PACK`). These notes are historical; check current recipes,
`linux-build/out/`, and repo metadata before treating any package below as unbuilt.

```
linux-build/recipes/dconf.mk                     + build_info/dconf.control
linux-build/recipes/gsettings-desktop-schemas.mk   build_info/dconf-dev.control
                                                   build_info/gsettings-desktop-schemas.control
```

> **`dbus` is already covered.** The parallel **XFCE track** (sibling agent) has shipped
> `recipes/dbus.mk` + `build_info/dbus.control` (autotools, dbus **1.14.10**, single `dbus`
> package, `Depends: libexpat1`). We deliberately did **not** duplicate it; our `dconf`
> depends on that `dbus` package at runtime. (Note: their recipe pins 1.14.x specifically
> because **dbus ≤1.14 uses autotools and 1.16+ is meson-only** — good to know before any
> version bump.)

Notes for whoever builds these (a future `build-gnome.sh`, modelled on `build-gtk.sh` — do not
fold them into `build-gtk.sh`, which `gtk-builder` owns):
- **Build order:** `dbus` (XFCE track) → `gsettings-desktop-schemas` → `dconf` (dconf wants the
  dbus session bus at *runtime*, not build time — it talks GDBus, so it compiles against glib
  alone).
- **Versions pinned to the GNOME-45 era:** dconf **0.40.0**, gsettings-desktop-schemas **45.0**.
- **dconf** is drafted as a simplified single runtime package (lib + GIO backend module
  `libdconfsettings.so` + `dconf-service` + `dconf` CLI) + `dconf-dev`. Debian splits the
  runtime further (`dconf-gsettings-backend`/`dconf-service`/`dconf-cli`/`libdconf1`); split
  later if a finer dependency graph is wanted.
- **gsettings-desktop-schemas** is data-only; a `postinst`/dpkg-trigger must run
  `glib-compile-schemas` on-device (noted in the recipe).

---

## Resolved questions from the original plan

1. **GTK4/libadwaita:** yes; the GTK4 app chain has packages and typelibs.
2. **Shell ambition:** yes; GNOME Shell first light is now a live handoff track.
3. **Introspection strategy:** on-device `g-ir-scanner` is the proven Mach-O route.
4. **Build budget:** many Stage A-C packages have moved from draft to repo/package output.

---

### Sources

- GNOME X11 session removal timeline (GNOME 49 default-off, gone by 49/50; 48 last with X11):
  <https://blogs.gnome.org/alatiera/2025/06/08/the-x11-session-removal/>,
  <https://blogs.gnome.org/alatiera/2025/06/23/x11-session-removal-faq/>,
  <https://www.phoronix.com/news/GNOME-GDM-Disable-X11-Default>
- Mutter `-Dx11=true` deprecated, removed in GNOME 50:
  <https://www.phoronix.com/news/GNOME-Mutter-Prep-X11-Free>,
  <https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/2354>
- Cogl winsys/GL requirements (GLX/EGL, GL ≥1.3): <https://github.com/rib/cogl>
- SpiderMonkey JIT-less / cross-compile (`--disable-ion`, iOS interpreter mode):
  <https://firefox-source-docs.mozilla.org/js/build.html>,
  <https://bugzilla.mozilla.org/show_bug.cgi?id=1102925>,
  <https://github.com/gameclosure/spidermonkey-ios>
- gobject-introspection cross-compile needs qemu to run target g-ir-scanner:
  <https://maxice8.github.io/8-cross-the-gir/>,
  <https://docs.yoctoproject.org/dev-manual/gobject-introspection.html>
- GSettings memory/keyfile fallback when dconf absent:
  <https://bbs.archlinux.org/viewtopic.php?id=218642>
- GNOME↔systemd/logind, elogind for non-systemd, accountsservice:
  <https://blogs.gnome.org/adrianvovk/2025/06/10/gnome-systemd-dependencies/>,
  <https://wiki.gentoo.org/wiki/Elogind>, <https://lwn.net/Articles/1025560/>
- librsvg last C release = 2.40.x; 2.41+ Rust; gdk-pixbuf SVG loader:
  <https://en.wikipedia.org/wiki/Librsvg>, <https://gitlab.gnome.org/GNOME/librsvg/-/tags>
- App toolkits (nautilus/calculator GTK4 since 42; gnome-terminal/gedit still GTK3):
  <https://9to5linux.com/first-look-at-some-of-the-gtk4-apps-in-gnome-42>,
  <https://tuxphones.com/gnome-text-editor-mobile-friendly-libhandy-gtk4-gedit/>
- D-Bus 1.14.x stable, meson on Unix: <https://dbus.freedesktop.org/>
