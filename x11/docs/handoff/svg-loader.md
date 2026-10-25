# SVG loader for GTK icon themes

Done. Kept as a short reference for how SVG icons work in this stack.

## Current state

- `librsvg 2.56.5+ios1` ships as `librsvg2-2`, `librsvg2-common`, `librsvg2-dev` and `librsvg2-bin`.
  `librsvg2-common` owns the GdkPixbuf SVG loader
  (`/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so`) and the thumbnailer.
- `xios-desktop-theme 1.1.2` depends on `librsvg2-common`, so every desktop flavor gets SVG icons.
  `iosc-shell` and `xios-launcher-tools` depend on it directly too.
- `xios-desktop-defaults` ships no generated PNG fallbacks.

The original bug: GTK headerbar icons were missing because GdkPixbuf had no SVG loader
(`gtk-encode-symbolic-svg ... Unrecognized image file format`), not because Adwaita files were
missing.

## Notes

- Build: `x11/linux-build/build-librsvg.sh` + `recipes/librsvg.mk`. It installs rustup and the
  `aarch64-apple-ios` target, and wires cctools ld64 through
  `CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS=-B/root/cctools/bin/`. 2.58 needs Cairo 1.17+, which is
  why it is 2.56.
- `loaders.cache` is generated in `postinst`/`postrm`, never shipped. The device's
  `gdk-pixbuf-query-loaders` treats `--help` as a module path, so the hook passes the loader files
  explicitly:
  `gdk-pixbuf-query-loaders "$dir"/loaders/* > "$dir/loaders.cache"`.
- Do not link GTK against librsvg. SVG is a GdkPixbuf module loaded at runtime; the theme package is
  what pulls it in. Qt/KDE does SVG through `qt6-svg`, separately.
- GNOME Shell does not need the Rsvg typelib (it was patched out); St draws SVG icons through this
  loader.

## Check on device

```sh
gdk-pixbuf-query-loaders /var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/* | grep -i svg
cd /var/jb/tmp && gtk-encode-symbolic-svg \
  /var/jb/usr/share/icons/Adwaita/symbolic/ui/window-close-symbolic.svg 16x16
```
