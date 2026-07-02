# SVG loader / GTK icon audit

Status as of 2026-07-01 late evening:

- The visible Calculator/headerbar icon breakage was caused by missing SVG image loading, not by missing Adwaita files. On-device, `gtk-encode-symbolic-svg /var/jb/usr/share/icons/Adwaita/symbolic/ui/window-close-symbolic.svg 16x16` failed with `Unrecognized image file format`.
- A temporary generated-PNG fallback was packaged as `xios-desktop-defaults 1.1.3`, then removed for disk space in `xios-desktop-defaults 1.1.4`. The remaining `*-symbolic*.png` under Adwaita is owned by the real `adwaita-icon-theme` package, not by Xios defaults.
- The long-term fix is now packaged: `librsvg 2.56.5` builds as `librsvg2-2`, `librsvg2-common`, `librsvg2-dev`, and `librsvg2-bin`. `librsvg2-common` owns the GdkPixbuf SVG loader and fixes GTK icon themes without generated PNG fallbacks.
- `xios-desktop-theme 1.1.1` depends on `librsvg2-common`, so the normal desktop theme install pulls in SVG support.

## What was built

`linux-build/recipes/librsvg.mk` builds `librsvg 2.56.5`. `2.58.x` was avoided for now because it requires Cairo >= 1.17.0 and the current staged Cairo is 1.16.0.

- `librsvg2-2`: the runtime library, installed under `/var/jb/usr/lib`.
- `librsvg2-common`: the GdkPixbuf SVG loader and cache hook. This is the package that fixes GTK icon themes.
- `librsvg2-dev`: headers, pkg-config, unversioned symlink.
- `librsvg2-bin` optional: `rsvg-convert`, useful for launcher icon generation and theme build jobs, but not needed by GTK at app runtime.

Use `linux-build/build-librsvg.sh` for rebuilds. It is separate from the broader GNOME build scripts because it installs Rust/rustup and the `aarch64-apple-ios` target. Cargo needs cctools ld64 wiring: the script creates `/root/cctools/bin/ld -> aarch64-apple-darwin-ld`, and the recipe passes `-B/root/cctools/bin/` through `CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS`.

## Where it should install

The current `gdk-pixbuf` build uses built-in raster loaders and ships no loader directory, but `gdk-pixbuf-query-loaders` reports:

```text
LoaderDir = /var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders
```

`librsvg2-common` owns:

- `/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so`
- `/var/jb/usr/share/thumbnailers/librsvg.thumbnailer`

`/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache` is generated in `postinst`/`postrm`, not shipped in the deb.

## Cache hooks

Current hooks:

- `librsvg2-common`: after installing/removing the loader, regenerate GdkPixbuf's loader cache.
- `libgdk-pixbuf-2.0-0`: if rebuilt, preserve/install the loader directory parent and run the same cache hook when modules exist.
- `xios-desktop-defaults`: keep the existing Adwaita/hicolor `gtk-update-icon-cache` and `gtk4-update-icon-cache` refreshes. These are still useful after the SVG loader exists.
- `adwaita-icon-theme`: refresh its icon cache after install/upgrade. It already has many SVG symbolic assets, so it benefits directly once the loader exists.

The device's `gdk-pixbuf-query-loaders` does not behave like a normal GNU option parser; it treated `--help` as a module path. Use a conservative hook:

```sh
dir=/var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0
if command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
  mkdir -p "$dir/loaders"
  gdk-pixbuf-query-loaders "$dir"/loaders/* > "$dir/loaders.cache" 2>/dev/null || true
fi
```

If a future rebuild provides a working `--update-cache`, use that instead.

## Dependency wiring

Do not link GTK itself against `librsvg`. SVG support is a GdkPixbuf loader module loaded at runtime.

Current package relationships:

- `librsvg2-common`: `Depends: librsvg2-2 (= @DEB_LIBRSVG_V@), libgdk-pixbuf-2.0-0, libglib2.0-0`
- `librsvg2-dev`: `Depends: librsvg2-2 (= @DEB_LIBRSVG_V@), libgdk-pixbuf-2.0-dev, libcairo2-dev, libpango1.0-dev, libfreetype-dev, libharfbuzz-dev, libxml2-dev`
- `xios-desktop-theme 1.1.1`: `Depends: xios-desktop-defaults, adwaita-icon-theme, hicolor-icon-theme, librsvg2-common`
- `adwaita-icon-theme`: no direct relationship was changed because the Xios desktop theme package now provides the user-visible desktop contract.
- `libgtk-3-0` / `libgtk-4-1`: no hard dependency needed if the theme package pulls it in. A `Recommends: librsvg2-common` is defensible, but avoid a hard GTK -> SVG dependency unless we decide every minimal GTK install must render SVG themes.
- GNOME app packages (`gnome-calculator`, `gnome-console`, `nautilus`, `file-roller`, `baobab`, `d-spy`, `gnome-font-viewer`, `gnome-text-editor`): no direct dependency needed if they depend on GTK/libadwaita plus `xios-desktop-theme` is part of the installed desktop flavor. Add direct dependencies only for apps that ship or load app-private SVG assets outside the icon theme.
- KDE/Qt path: separate issue. Qt has `qt6-svg`; KF6 icon handling already routes through Qt/KIconThemes, not GdkPixbuf.

## Verification

Verified on device after installing `librsvg2-2 2.56.5`, `librsvg2-common 2.56.5`, and `xios-desktop-theme 1.1.1`:

- `grep -i svg /var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache` lists `libpixbufloader-svg.so` and SVG MIME/extensions.
- `gtk-encode-symbolic-svg /var/jb/usr/share/icons/Adwaita/symbolic/ui/window-close-symbolic.svg 16x16` succeeds and writes `window-close-symbolic.symbolic.png`.
- Calculator relaunch via `uiopen --bundleid com.max.iosc.org.gnome.calculator` produced no icon/SVG warnings in `/var/jb/tmp/ioscd-client.log`.
- `dpkg -L xios-desktop-defaults` owns no generated symbolic PNG fallbacks; the only remaining Adwaita `*symbolic*.png` found on-device is `/var/jb/usr/share/icons/Adwaita/16x16/emblems/emblem-symbolic-link.png`, owned by `adwaita-icon-theme`.

Useful recheck commands:

```sh
/var/jb/usr/bin/gdk-pixbuf-query-loaders \
  /var/jb/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/* | grep -i svg

rm -rf /var/jb/tmp/icon-test
mkdir -p /var/jb/tmp/icon-test
cd /var/jb/tmp/icon-test
/var/jb/usr/bin/gtk-encode-symbolic-svg \
  /var/jb/usr/share/icons/Adwaita/symbolic/ui/window-close-symbolic.svg 16x16
find . -type f -ls
```

Then relaunch a native GTK app:

```sh
uiopen --bundleid com.max.iosc.org.gnome.calculator
tail -80 /var/jb/tmp/ioscd-client.log
```

Expected result: no `Unrecognized image file format`, no missing-icon warnings, and Calculator headerbar/window controls render without generated PNG fallbacks.
