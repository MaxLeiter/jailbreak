# Vendored Vala `.vapi` bindings (cross-Vala build inputs)

These are **build-host inputs** for cross-compiling the **Vala** GNOME apps (gnome-calculator,
and later baobab/gnome-clocks). They are **not** shipped to the device.

## Why

`valac` is a host transpiler (Vala → C); our cross C-compiler then builds the C. valac needs
each dependency's **`.vapi`** (an arch-neutral API description) at compile time. We build our
own libraries with `-Dvapi=false` (vapi generation would need GIR / `g-ir-scanner` run on the
*target*, which qemu can't do for Mach-O — see `docs/gnome-plan.md` Blocker #2). Since `.vapi`
is platform-independent, we simply **vendor version-matched copies** here.

## Source — Ubuntu 24.04 LTS (Noble)

Noble ships **gtk4 4.14.5**, an *exact* match to gtk-builder's gtk4. Harvest from its `-dev`
debs (any mirror; example below). `gee-0.8.vapi` is **not** vendored — our `libgee` build emits
it. Core `glib-2.0`/`gio-2.0`/`cairo`/`pango`/`gdk-pixbuf` vapi ship **with** valac.

| File(s) | Ubuntu 24.04 package |
|---|---|
| `gtk4.vapi` `gtk4.deps` `gdk4.vapi` `gsk4.vapi` | `libgtk-4-dev` (4.14.5) |
| `libadwaita-1.vapi` `libadwaita-1.deps` | `libadwaita-1-dev` (1.5.x) |
| `gtksourceview-5.vapi` `gtksourceview-5.deps` | `libgtksourceview-5-dev` |
| `libsoup-3.0.vapi` `libsoup-3.0.deps` | `libsoup-3.0-dev` |
| `graphene-gobject-1.0.vapi` (if needed) | `libgraphene-1.0-dev` |

Harvest (run once on any machine, commit the resulting `*.vapi`/`*.deps` here):

```sh
# example for one package; repeat per package above
pkg=libgtk-4-dev
url=$(curl -s "https://packages.ubuntu.com/noble/amd64/$pkg/download" | grep -oE 'https://[^"]*'"$pkg"'_[^"]*_amd64.deb' | head -1)
curl -fsSL "$url" -o /tmp/$pkg.deb
dpkg-deb -x /tmp/$pkg.deb /tmp/$pkg
cp /tmp/$pkg/usr/share/vala*/vapi/*.vapi /tmp/$pkg/usr/share/vala*/vapi/*.deps . 2>/dev/null || true
```

## How the build consumes them

1. Build-host needs **`valac`** (`apt-get install -y valac`) — add to the Dockerfile, like `sassc`.
2. Stage these files into the **host valac vapidir** (e.g. `/usr/share/vala-0.56/vapi/`) so
   valac finds them with no per-project flag, OR pass `--vapidir=<this dir>`. `build-gnome.sh`
   (or the Dockerfile) should copy them before building the Vala app targets.
3. Vala recipes carry `vala = 'valac'` in their meson `cross.txt` `[binaries]` section
   (see `recipes/gnome-calculator.mk`).

## Version coherence

Keep these matched to the libraries we actually build (gtk4 **4.14**, libadwaita **1.5**,
gtksourceview **5.12** for the GNOME-46 stack). A newer vapi mostly works (unused extra
declarations don't break linking), but exact-match avoids surprises.
