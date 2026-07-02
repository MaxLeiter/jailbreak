# GNOME apps on the X11-for-iOS stack — recipe chain & dependency map

Status: **Phase 1 — drafts only, nothing built.** Owner: `gnome-track`.
Decision (locked by coordinator + user): **GNOME apps (GTK4 + libadwaita) hosted in our iOS
compositor (`carplayhost`) IS the desktop.** This is now the **primary desktop path** — XFCE
was deprioritised. GNOME *Shell* stays an off-critical-path research spike (see
[`gnome-plan.md`](gnome-plan.md) Blockers #1–#4). gtk-builder is now **GTK4-first**
(gdk-pixbuf → graphene → gtk4), so GTK3 is deferred and the GTK3 apps become optional-later.

This doc maps the app chain, records what was drafted, and lays out build order. **The named
app targets are Files (nautilus), Console (kgx), and Text Editor — all GTK4** — plus
gnome-terminal (GTK3) as an optional-later earliest-win.

---

## Ownership split

| Layer | Owner | Components |
|---|---|---|
| Foundation | Procursus (prebuilt) | glib2.0, cairo, pango*, fontconfig, freetype, harfbuzz, pcre2, libxml2, libyaml, xz/zstd, X11 stack |
| **GTK3 / GTK4 / graphene** | **gtk-builder** | `gtk+3.0`, **`gtk4`**, **`graphene`** (+ gdk-pixbuf, atk) |
| Bus + settings (Stage A) | gnome-track | `dbus` (XFCE track), **`dconf`**, **`gsettings-desktop-schemas`** |
| **App libraries** | **gnome-track** | **libxmlb, appstream, libadwaita, vte, gtksourceview5, enchant** + Files tree: **json-glib, gnome-autoar, libportal, tracker, gnome-desktop, iso-codes** |
| **Apps** | **gnome-track** | **nautilus (Files), gnome-console, gnome-text-editor** (GTK4); gnome-terminal (GTK3, optional-later) |
| Shared | Wayland track | **`libxkbcommon`** — needed by gnome-desktop too (see coordination note) |

> **Reconciliation RESOLVED (coordinator-confirmed).** GTK4/graphene names are canonical and
> already match these recipes: make targets **`gtk4` / `graphene`** (debs `libgtk-4-1` /
> `libgtk-4-dev` / `libgtk-4-bin`, `libgraphene-1.0-0` / `libgraphene-1.0-dev`). No recipe or
> control changes were needed. GTK3 deb names (`libgtk-3-0`) apply only to the optional-later
> gnome-terminal pass.

> **libxkbcommon coordination RESOLVED.** gnome-desktop-4 (GnomeXkbInfo) requires
> libxkbregistry; the Wayland track (which owns `recipes/libxkbcommon.mk`) has been directed to
> build it with **`-Denable-xkbregistry=true`** so `libxkbcommon0` ships `libxkbregistry.0.dylib`.
> We did NOT duplicate their recipe; gnome-desktop depends on the shared `libxkbcommon` target.

---

## Recipes drafted with this doc

All in `linux-build/recipes/` with control templates in `linux-build/build_info/`. **Unbuilt
drafts**, authored to mirror `recipes/pango.mk` (meson `cross.txt`, `.build_complete` guard,
`*-package` → `SIGN`/`PACK`). Versions pinned to the **GNOME 45** generation.

| Recipe | Packages | Version | Target deps | Class |
|---|---|---|---|---|
Versions are the **GNOME 46** generation (to match gtk-builder's gtk4 **4.14.5**). The bump
from the original GNOME-45 draft forced one soname change: **libadwaita 1.5 requires AppStream
1.0**, so `libappstream4` → `libappstream5`.

| `libxmlb.mk` | libxmlb2, -dev | 0.3.14 | glib (+ prebuilt lzma/zstd) | EASY |
| `appstream.mk` | **libappstream5**, -dev | **1.0.3** | glib, libxml2, libyaml, libxmlb | MEDIUM |
| `libadwaita.mk` | libadwaita-1-0, -dev | **1.5.0** | **gtk4**, appstream, fribidi | MEDIUM |
| `vte.mk` | libvte-2.91-gtk4-0, -dev | **0.76.6** | **gtk4**, libxml2, pcre2, gnutls, icu4c | MEDIUM |
| `gtksourceview5.mk` | libgtksourceview-5-0, -dev | **5.12.1** | **gtk4**, libxml2, pcre2 | EASY-MED |
| `enchant.mk` | libenchant-2-2, -dev | 2.6.1 | glib (autotools) | EASY |
| `json-glib.mk` | libjson-glib-1.0-0, -dev | 1.8.0 | glib | EASY |
| `gnome-autoar.mk` | libgnome-autoar-0-0, -dev | **0.4.5** | glib, libarchive (prebuilt), **gtk4** | EASY-MED |
| `libportal.mk` | libportal1, -gtk4-1, -dev | 0.7.1 | glib, **gtk4** | EASY-MED |
| `tracker.mk` | libtracker-sparql-3.0-0, -dev | **3.7.3** | glib, sqlite3, json-glib, icu4c | MEDIUM-HARD |
| `gnome-desktop.mk` | libgnome-desktop-4-2, -dev | **44.1** | **gtk4**, gsettings-desktop-schemas, iso-codes, libxkbcommon | MEDIUM-HARD |
| `iso-codes.mk` | iso-codes | 4.15.0 | (data; autotools) | EASY |
| `gnome-console.mk` | gnome-console | **46.0** | **gtk4**, libadwaita, vte(gtk4) | MEDIUM |
| `gnome-text-editor.mk` | gnome-text-editor | **46.3** | **gtk4**, libadwaita, gtksourceview5, enchant | MEDIUM |
| `gnome-font-viewer.mk` | gnome-font-viewer | **46.0** | **gtk4**, libadwaita, gnome-desktop (rest prebuilt) | MEDIUM (pure C, zero new sub-deps) |
| `nautilus.mk` | nautilus | **46.4** | **gtk4**, libadwaita, gnome-desktop, gnome-autoar, libportal, tracker | HARD (big tree) |
| **Vala route** ↓ | | | | |
| `libpsl.mk` | libpsl5, -dev | 0.21.5 | (builtin list; libsoup dep) | EASY |
| `libsoup3.mk` | libsoup-3.0-0, -dev | 3.4.4 | glib, libpsl, nghttp2+sqlite3 (prebuilt) | MEDIUM |
| `libgee.mk` | libgee-0.8-2, -dev | **0.20.8** | glib (Vala lib → emits gee-0.8.vapi) | MEDIUM (Vala) |
| `gnome-calculator.mk` | gnome-calculator | **46.2** | **gtk4**, libadwaita, gtksourceview5, libsoup3, libgee (+mpfr/mpc prebuilt) | MEDIUM (Vala) |
| `gnome-terminal.mk` | gnome-terminal | 3.50.1 | **gtk+3.0**, vte(gtk3), dconf, gsettings-desktop-schemas | MEDIUM (GTK3, optional-later) |

Facts that shaped the chain:
- **libadwaita 1.4 hard-requires AppStream** (`src/meson.build`, `required:true`) → it drags
  the whole `appstream → libxmlb` sub-tree. Unavoidable for GNOME-45 apps (they use 1.4-only
  widgets like `AdwToolbarView`/`AdwBreakpoint`).
- **vte is GTK4-only by default now** (`-Dgtk3=false`): GTK3 is deferred, so requiring `gtk+3.0`
  would block gnome-console. One flag (`-Dgtk3=true` + re-add the libvte-2.91-0 packaging block,
  kept commented) brings the GTK3 widget back for gnome-terminal once GTK3 lands.
- **nautilus's heavy leaves are optional** (verified against its `meson.build`): `-Dextensions=false`
  drops gexiv2 + gstreamer + explicit gdk-pixbuf; `-Dcloudproviders=false` drops libcloudproviders;
  `-Dpackagekit=false` drops PackageKit. What remains *mandatory* is gnome-autoar, gnome-desktop-4,
  libportal(+gtk4), and **tracker-sparql-3.0 (no opt-out)**. The tracker *indexer* (localsearch)
  stays optional — search is just inert without it.

### Build-host tools to add (NOT recipes — they run on the Linux build host)

These run during cross-builds and must be `apt install`-ed in the `Dockerfile` (coordinate
with whoever owns it — not `build-gtk.sh`):
- **`sassc`** — libadwaita compiles its SCSS stylesheet at build time.
- **`itstool`**, **`desktop-file-utils`** — translation/desktop-file validation for the apps.
- **`valac`** — the Vala compiler (host transpiler) for the Vala apps (gnome-calculator, libgee).
  See the "Vala route" section and `linux-build/vapi/README.md` for the vendored-`.vapi` step.
- (`glib-compile-resources`, `msgfmt` already come from `libglib2.0-bin` / `gettext`.)

### Install-time note

vte, gtksourceview5 and all three apps install **GSettings schemas**; each package needs a
`postinst` (or a shared dpkg trigger from `libglib2.0-bin`) running `glib-compile-schemas` on
`$PREFIX/share/glib-2.0/schemas`. Same mechanism flagged for `gsettings-desktop-schemas` in
Stage A.

---

## Build order (DAG, linear-safe)

```
# Stage A (foundation — already drafted)
dbus[lightde] → gsettings-desktop-schemas → dconf

# gtk-builder lands (GTK4-first): gdk-pixbuf → graphene → gtk4
# Wayland track: libxkbcommon  (MUST enable xkbregistry — see coordination note)

# App libraries (all need gtk4)
libxmlb → appstream → libadwaita
json-glib
vte (gtk4-only)
gtksourceview5
enchant
gnome-autoar           (libarchive prebuilt)
libportal              (core + gtk4 backend)
iso-codes              (data)
tracker                (json-glib, sqlite3, icu4c)
gnome-desktop          (gsettings-desktop-schemas, iso-codes, libxkbcommon+xkbregistry)

# Apps (GTK4 — the named targets)
gnome-console       (libadwaita, vte-gtk4)
gnome-text-editor   (libadwaita, gtksourceview5, enchant)
gnome-font-viewer   (libadwaita, gnome-desktop)
nautilus / Files    (libadwaita, gnome-desktop, gnome-autoar, libportal, tracker)

# Optional-later (GTK3)
gnome-terminal      (needs gtk+3.0 + vte built with -Dgtk3=true)
```

**Lightest GTK4 app first:** `gnome-console` (only libadwaita + vte-gtk4) is the quickest
end-to-end smoke test of the GTK4 base. **Files (nautilus) is the heaviest** — its full
sub-tree (gnome-desktop+iso-codes+libxkbcommon, tracker, gnome-autoar, libportal) must all
land first.

**Driver:** this whole order is encoded executably in **`linux-build/build-gnome.sh`** (companion
to `build-gtk.sh`, does not edit it). It installs our recipes/controls into the clone and runs
the `*-package` targets in order, collecting debs to `/out`. Preconditions documented in its
header: the GTK4 base (`build-gtk.sh`) and the xkbregistry-enabled `libxkbcommon` must already be
built in the same Procursus volume. Override the set with `TARGETS=...` (e.g. just
`gnome-console-package` for the first smoke test).

---

## Apps reachable now vs deferred

### Repo section: `X11/Wayland Apps`

The package repo now has a dedicated **`X11/Wayland Apps`** section for user-facing GUI clients
that run on the Xios/iosc display stack. This replaces the vague `Applications` bucket for the
GNOME apps and also absorbs lightweight X11-first GUI clients that users launch directly. Keep
desktop meta-packages in `Desktop`, display servers/session glue in `X11` or `System`, shared
libraries in `Libraries`, and headers/tools in `Development`.

Current build metadata that belongs in this section:
- **GNOME/GTK4 on Wayland or X11:** `gnome-console`, `gnome-text-editor`, `gnome-font-viewer`,
  `gnome-calculator`, `nautilus`, `baobab`, `file-roller`, `d-spy`.
- **GTK3/X11 clients:** `gnome-terminal`, `hitori`, `thunar`, `xfce4-appfinder`.

Already present as debs in `repo/debs`: `gnome-console`, `gnome-text-editor`,
`gnome-font-viewer`, `gnome-calculator`, `nautilus`, `baobab`, `file-roller`, `d-spy`,
and `hitori`. These are no longer "maybe build" candidates; the next question is whether each
one has passed an on-device launch/use smoke test and should be featured or recommended by a
meta-package.

Not yet present as debs, but recipe/control metadata exists: `gnome-terminal`, `thunar`,
and `xfce4-appfinder`.

Recommended app validation/featuring order, biased toward **likely to work** plus **useful to
real users**:

| Priority | App | Why it is likely to work | Why users want it |
|---|---|---|---|
| 1 | **gnome-console** | Already the lightest GTK4/libadwaita terminal path; vte stack is in-tree. | A terminal makes the desktop immediately useful and debuggable. |
| 2 | **gnome-text-editor** | GTK4/libadwaita plus gtksourceview/enchant; no gjs or typelibs. | Basic file editing on-device. |
| 3 | **d-spy** | Pure C GTK4/libadwaita, only needs the D-Bus session we already ship. | Developer/user diagnostic tool for the desktop bus. |
| 4 | **file-roller** | GTK4/libadwaita + libarchive/json-glib; optional features trimmed. | Archive create/extract is a real daily utility on a filesystem desktop. |
| 5 | **gnome-font-viewer** | Pure C, shallow GTK4 app; pairs with the packaged iOS/SF font work. | Lets users inspect installed fonts and validates fontconfig/UI rendering. |
| 6 | **baobab** | Shallow Vala app over GTK4/libadwaita; validates the Vala flow after calculator. | Helps users find what is consuming scarce device storage. |
| 7 | **gnome-calculator** | Vala path is understood; extra deps are already mapped. | Small, familiar utility and a useful Vala proof. |
| 8 | **hitori** | Pure C/GTK3, zero new sub-deps beyond the GTK3 stack. | Cheap touch-friendly game/smoke test; not critical, but nice. |
| 9 | **nautilus** | Built, but still has the heaviest runtime tree: tracker/portal/gnome-desktop. | Full GNOME Files experience once the heavier app stack is stable. |
| 10 | **xfce4-appfinder** | Existing GTK3/XFCE recipe; small dependency set. | Keyboard-friendly app launcher before a full shell/app grid is polished. |
| 11 | **thunar** | Existing GTK3 recipe with gudev/libnotify disabled; local browsing should work. | Lightweight file manager; good fallback if Nautilus is too heavy. |

Hold off for now on JS/GJS apps (`gnome-characters`, `gnome-weather`) and plugin-heavy editors
(`gedit` current line): they reintroduce runtime typelibs or plugin-loader complexity. Also defer
media/camera/audio-first apps until the desktop audio/session story is boring.

### Drafted (the named GTK4 targets)
- **gnome-console / kgx** (GTK4) — lightest; deps fully covered (libadwaita + vte-gtk4).
- **gnome-text-editor** (GTK4) — the gedit replacement; clean (libadwaita + gtksourceview5 + enchant).
- **gnome-font-viewer** (GTK4) — pure C, the lightest second simple win; only new deps are
  libadwaita + gnome-desktop (both already drafted), rest prebuilt. Bonus: pairs with the
  x11-fonts-sf work — previews the live iOS system fonts.
- **gnome-calculator** (GTK4, **Vala**) — the cross-Vala validation target (vendored `.vapi` +
  `valac` host tool). Drags `libsoup3` (+`libpsl`) and `libgee`; mpfr/mpc are prebuilt. Heavier
  than the pure-C trio, so it builds after them.
- **nautilus / Files** (GTK4) — drafted with the heavy leaves trimmed off. The remaining
  mandatory sub-tree is all drafted: `gnome-desktop-4` (+ `iso-codes`, `libxkbcommon`-with-
  xkbregistry), `gnome-autoar` (libarchive prebuilt), `libportal` (+gtk4), `tracker-sparql`
  (+ `json-glib`). It is the **heaviest** of the three and gated on the libxkbcommon
  coordination above.
- **gnome-terminal** (GTK3) — drafted but **optional-later** (GTK3 is deferred; build vte with
  `-Dgtk3=true` to enable it). The earliest *possible* win if GTK3 ever lands.

### Deferred — messy tree (dependency-mapped, NOT drafted)

**gedit — recommend skipping in favour of gnome-text-editor.** Current gedit (46+) is
**GTK4** and depends on the **`libgedit-*` forks** (`libgedit-gtksourceview`, `libgedit-tepl`,
`libgedit-amtk`) **plus `libpeas-2`**. libpeas is a GObject *plugin* engine that loads plugins
via **GObject-Introspection typelibs** — i.e. it re-introduces [Blocker #2](gnome-plan.md)
(typelibs can't be cross-generated for Mach-O). Core gedit might start without plugins, but
the dependency chain is far worse than gnome-text-editor for the same outcome. (gedit 44 was
GTK3 but is now old.) **Use gnome-text-editor.**

### Language note — Vala is buildable; only gjs/JS is the hard one (CORRECTED)
An earlier draft of this doc lumped Vala in with the gjs/typelib blocker. **That was wrong**;
the accurate split:

- **Vala apps (gnome-calculator, baobab, gnome-clocks, gnome-sound-recorder) ARE
  cross-compilable.** `valac` is a *host* transpiler: it emits C, which our cross C-compiler
  (`valac -cc=<cross-cc>`) builds for the target — valac **never runs target code**. It needs
  only each dependency's **`.vapi`** at build time, and a `.vapi` is a *platform-independent API
  description*. Since we build our libs with `-Dvapi=false`, we just **vendor the version-matched
  `gtk4.vapi`/`libadwaita.vapi`/… from upstream/Debian** into `share/vala/vapi/`. No GIR, no
  on-target execution. So Vala is **MEDIUM**, not blocked — the real cost of gnome-calculator is
  its extra C deps (`gtksourceview5` [have], `libsoup3`, `libgee`, `mpfr`, `mpc`), not introspection.
- **gjs/JS apps (gnome-characters, gnome-weather) and GNOME Shell are the genuinely hard ones.**
  gjs loads **`.typelib` at RUNTIME** for every library it touches, and typelibs are ABI-precise
  binary metadata that normally need `g-ir-scanner` to *run a target binary* — which our
  qemu-based cross can't do for Mach-O ([Blocker #2](gnome-plan.md)). Escape: generate typelibs
  **on-device** (native arm64) or on an Apple-Silicon host, then ship them (the D1 spike), with
  `GI_TYPELIB_PATH` pointing at them. Deferred, not impossible.

`gnome-font-viewer` (pure C, zero new deps) stays the lightest first simple win; **gnome-calculator
is a viable heavier option** (see the spike result below). Other pure-C later candidates:
`file-roller` (GTK3+libarchive).

### Vala route — spike result: **FEASIBLE (MEDIUM)**

Confirmed the cross-Vala flow works for our pipeline:
- **valac is a build-HOST tool.** It emits C (`app.vala.c`) which the **cross** C-compiler builds;
  no target binary runs during a Vala build. Meson cross-file gets a `[binaries]` valac entry
  (`vala = 'valac'`); add **`valac`** to the Dockerfile apt (a build-host tool, like `sassc`).
- **Dependency `.vapi` are arch-neutral** and supplied externally:
  `add_project_arguments(['--vapidir', <our vapidir>], language: 'vala')`. Core glib/gobject/gio
  vapi ship **with** valac.
- **Cleanest `.vapi` source: Ubuntu 24.04 (Noble)** — it ships `libgtk-4-dev` **4.14.5**, an
  *exact* match to gtk-builder's gtk4 4.14.5. Vendor `gtk4.vapi`/`gdk4.vapi`/`gsk4.vapi`/
  `gtk4.deps` (+ `gtksourceview-5.vapi`, `libadwaita-1.vapi`) from its `-dev` debs into our prefix
  `share/vala/vapi/`. (Alt, most reproducible: a one-time **native x86** build of our exact lib
  versions with introspection+vala on emits the exact `.gir`/`.vapi`.)

What **gnome-calculator** then needs — all tractable:
- **Math deps gmp/mpfr/mpc: ALREADY PREBUILT** in Procursus (`libgmp10`/`libmpfr6`/`libmpc3`) → zero recipes.
- `gtksourceview5`: already drafted. `nghttp2` + `sqlite3`: prebuilt (libsoup deps).
- **NEW recipes:** `libsoup3` (+ small `libpsl`), `libgee` (itself a Vala lib → same cross-Vala flow,
  emits its own vapi), and `gnome-calculator` (the Vala app).
- **Runtime-optional:** `glib-networking` (GIO TLS backend for libsoup HTTPS currency fetch — the
  app launches without it; only online rate updates fail).

Gotchas:
- **Version coherence:** gtk-builder builds gtk4 **4.14** (GNOME-46 era), but our `libadwaita.mk`
  is **1.4.0** (GNOME 45). For an exact vapi match to Ubuntu 24.04 (libadwaita 1.5), either bump
  libadwaita→1.5 (+ apps→GNOME 46) or harvest the libadwaita-**1.4** vapi from Debian 12 / Ubuntu
  23.10. A newer vapi mostly works (unused extra declarations don't break linking), but exact-match
  is cleanest — flagged for a coordinator decision.
- valac 0.56 (Ubuntu 24.04) is fine for GNOME 45/46 apps.

**Verdict:** Vala is re-opened — gnome-calculator/baobab/gnome-clocks/gnome-sound-recorder are all
buildable. Only **gjs/JS** (gnome-characters) and the **Shell** stay behind the on-device-typelib
(D1) spike. Recommend keeping the pure-C apps (console/text-editor/font-viewer/files) as the first
wins, then doing gnome-calculator as the first Vala proof.

---

## Why this dodges the GNOME Shell blockers

None of the drafted chain touches the four shell walls: no **gjs/mozjs** (apps are C), no
**introspection typelibs** (C apps build `-Dintrospection=disabled`; only gedit/libpeas would
need them — hence skipping it), no **Mutter/Cogl/EGL** (apps render via the X server under a
light WM or our iOS compositor), no **logind/systemd** (a `dbus-run-session` session bus is
enough; settings persist via dconf). The iOS-native keyboard → XTEST covers input.
