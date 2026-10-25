# gjs on iOS: on-device introspection and the mozjs 115 cross

**Status: done.** gobject-introspection 1.78, mozjs 115 and gjs 1.78 are built, published and
running GNOME Shell on the iPad. This file records how the two gjs blockers from
[gnome-plan.md](gnome-plan.md) were solved, and the frictions worth knowing before touching
either again. Current typelib packaging is in [handoff/gtk4-typelibs.md](handoff/gtk4-typelibs.md);
the JIT build is in [mozjs-jit-plan.md](mozjs-jit-plan.md).

What ships (repo/Packages):

| Package | Version |
|---|---|
| `libgirepository-1.0-1`, `gir1.2-glib-2.0`, `gir1.2-freedesktop`, `gobject-introspection`, `libgirepository-1.0-dev` | 1.78.0+ios1 |
| `libmozjs-115-0` (JIT-less) / `libmozjs-115-dev` | 115.12.0+ios1 |
| `libmozjs-115-jit-0` (opt-in JIT, drop-in replacement) | 115.12.0+ios1 |
| `libgjs0`, `gjs`, `libgjs-dev` | 1.78.0+ios1 |

Known packaging defect: `libmozjs-115-dev 115.12.0+ios1` ships headers that are all dangling
symlinks into a build tree that no longer exists, and `libmozjs-115-jit-dev 115.12.0+ios2` installs
its headers at `usr/include/js` while its `.pc` says `include/mozjs-115`. The recipe already has the
`cp -aL` fix; the published deb predates it and a rebuild needs the full mozjs cross again. Runtime
is unaffected; anything compiling against mozjs on the device is (this is what dropped 0 A.D., see
handoff/games.md).

## Blocker #2: introspection typelibs (solved by scanning on the device)

g-ir-scanner compiles a small dumper that links the target library and runs it to read GType, enum
and struct-offset values. In a cross build that dumper is an iOS Mach-O binary, and qemu-user only
runs Linux ELF. But the iPad is a full arm64 Darwin machine, and Procursus ships `clang`, `ld64`,
`pkg-config`, `python3`, `meson` and `ninja` for it. So the scanner runs on the device and the
dumper runs natively. No emulation.

How it is done now:

- Libraries are still cross-built in Docker with `-Dintrospection=disabled`.
- For typelibs, each library's own meson build is run on the device with introspection enabled,
  building only the typelib targets (`x11/linux-build/gir-build-ondevice.sh <source.tar> [-D...]`).
  Header-only scanning was tried for the Shell closure and produced empty stubs; see
  gtk4-typelibs.md.
- The g-i bootstrap and the base GLib/GObject/Gio typelibs: `x11/linux-build/gir-ondevice.sh`,
  packaged by `x11/linux-build/gi-package.sh`.

On-device frictions, all fixed in the scripts:

1. On-device `clang` does not add the `/var/jb/usr/lib` rpath; set `DYLD_LIBRARY_PATH=/var/jb/usr/lib`
   or link with `-Wl,-rpath,/var/jb/usr/lib`.
2. `ninja` hardcodes `/bin/sh`, which does not exist on rootless. Symlink `/var/sh` to
   `/var/jb/bin/sh`, byte-patch a copy of ninja (both paths are 7 bytes), re-sign. Only needed to
   build g-i itself.
3. Procursus `bison` has a baked-in m4 path; set `M4=/var/jb/usr/bin/m4` (and install `m4`).
4. `libpcre2-8` leaves `_SLJIT_UPDATE_WX_FLAGS` undefined. Normal programs never trip it, but the
   giscanner Python extension is linked `-undefined dynamic_lookup` and binds eagerly. Inject a
   signed no-op shim with `DYLD_INSERT_LIBRARIES`.
5. On-device `clang` targets macOS by default; wrap it to force `-target arm64-apple-ios14.0`.
6. The device debs do not carry every transitive `.pc` file or some EGL/X11 headers; the scripts
   copy them from the build sysroot and write a `zlib.pc` shim.

A typelib must describe the installed library, so scan with the same options the shipped package
used (pango with CoreText off, Atspi with `-Dx11=disabled`).

## Blocker #1: mozjs 115 (solved)

gjs 1.78 embeds SpiderMonkey 115 ESR. The cross is Linux to iOS Mach-O through `mach`, which almost
nobody does. Build driver: `x11/linux-build/build-gjs.sh` + `recipes/mozjs.mk` +
`build_info/mozjs115.mozconfig`; patches in `x11/ports/mozjs/patches/`.

Host setup: rustup with `aarch64-apple-ios`, cbindgen, nasm. Keep `CARGO_HOME`/`RUSTUP_HOME` on the
build volume, since the container's `$HOME` disappears with `--rm`.

The fixes:

1. mozjs's bundled `config.sub` copies do not know `ios`; the recipe replaces them with the host's.
2. Patch 0001: `moz.configure` had no `ios` case in `split_triplet` and no `iOS` OS constant. Adding
   them also skips the macOS SDK checks, which are gated on OSX.
3. ld64 wiring: moz's probe hardcodes `-fuse-ld=ld`, so symlink cctools ld as `ld`, add `-B<cctools>`,
   `--enable-linker=ld64`.
4. The Rust `cc` crate runs `xcrun`; a fake `xcrun` returns the iPhoneOS SDK. Set
   `CRATE_CC_NO_DEFAULTS=1`, or it adds `-fembed-bitcode`, which conflicts with `-ffunction-sections`.
5. Patch 0002: drop the JS shell (`js/src/shell` uses `system()`/`fork()`); keep the `rust` dir.
6. Patch 0003: `old-configure.in` Darwin cases matched only `*-darwin*`; extend to `*-ios*`, or the
   ELF link defaults leak in and ld64 rejects them.
7. Patch 0004: the `JS_NewContext()` "null deref" was a failed `MOZ_RELEASE_ASSERT` (MOZ_CRASH writes
   to address 0 on purpose). SpiderMonkey's helper threads ask for a 2088960-byte stack, which is
   4 KiB aligned but not 16 KiB aligned, and arm64 iOS `pthread_attr_setstacksize` returns EINVAL
   for anything that is not a multiple of the 16 KiB page. The patch rounds up to the page size.
8. Patch 0005 (found with the JIT build, in the shared series): wasm uses Mach exception ports,
   and iOS kills a process that calls `thread_set_exception_ports` (`EXC_GUARD`). Wasm is off on
   iOS; the JS JIT does not need those handlers.

The default `libmozjs-115-0` is built `--disable-jit`. The JIT build is separate so the JIT-less
debs are never overwritten.

## gjs 1.78

Built by `x11/linux-build/build-gjs-manual.sh` against the staged mozjs and g-i, packaged as
`libgjs0`, `gjs` and `libgjs-dev`. `libgjs0` is relinked to the `libgtkintl` shim for the
`g_libintl_*` imports. `GjsPrivate-1.0.typelib` is scanned on the device and shipped inside the
`gjs` deb under `/var/jb/usr/lib/gjs/girepository-1.0`.

## Why GNOME Shell had to be Wayland

A GPU-composited Shell could not be Mutter as an X11 window manager: that path binds redirected X11
pixmaps as GL textures, which needs hardware DRI in the X server, and ANGLE on iOS is Metal-only
with no X11 platform. So GPU compositing here is Wayland-only, and the Shell runs on Mutter with an
iOS backend. The typelibs are backend-agnostic, which is why the scans could start before the
backend existed. See [mutter-on-iosc.md](mutter-on-iosc.md).
