# gjs on the X11-for-iOS stack — feasibility, the introspection breakthrough, and the mozjs plan

Status: **Implemented baseline; remaining work is Shell-specific packaging/polish.** Owner: `gjs-track`. Sibling docs: [`gnome-plan.md`](gnome-plan.md)
(the four GNOME-Shell blockers), [`gnome-apps.md`](gnome-apps.md) (the C/Vala app chain).

This track owns the two **independent** hard blockers that gate gjs (and therefore GNOME Shell
and all gjs-based apps):

- **Blocker #2 — GObject-Introspection typelibs for Mach-O.** → **SOLVED (proven on-device).**
- **Blocker #1 — mozjs115 / SpiderMonkey JIT-less cross-compile.** → **SOLVED (proven on-device:
  built, loads, `JS_Init` + `JS_NewContext` + JS eval all run on the A10).** See Blocker #1 below.

---

## TL;DR

| Gate | Old verdict (gnome-plan) | New verdict |
|---|---|---|
| Runtime **typelibs** (gi) | 🔴 "qemu can't run Mach-O dumpers" | ✅ **Done.** Built gobject-introspection 1.78 *natively on the iPad* and generated + runtime-loaded GLib/GObject/Gio typelibs. |
| **mozjs115** (gjs JS engine) | 🔴 hard cross-compile | ✅ **Built + runs on-device.** JIT-less mozjs115 cross-compiled Linux→iOS; `JS_Init`/`JS_NewContext`/eval all green on the A10 (last blocker — the helper-thread stack-size EINVAL — fixed, patch 0004). |
| **gjs 1.78** | ⏳ pending after mozjs + GI | ✅ **Built, packaged, installed, and smoke-tested on-device.** `gjs --version`, plain JS, and `imports.gi.GLib`/`GObject`/`Gio` all run on the iPad. `GjsPrivate-1.0.typelib` is generated on-device and shipped inside the `gjs` deb. |
| **GTK4 stack typelibs + a gjs GTK4 app** | ⏳ "scan once gtk4 installed" | ✅ **Done.** Graphene/HarfBuzz/GdkPixbuf/Pango/Gdk-4.0/Gsk-4.0/Gtk-4.0 scanned natively on-device (`gir-build-ondevice.sh`); a gjs GTK4 app builds a window and renders it (`imports.gi.Gtk == 4.14.5`). See "GTK4 stack typelibs" below. |

The decisive reframe: **the device is a full arm64 Darwin machine.** Procursus `apt` ships a
native toolchain — `clang-16`, `odcctools`+`ld64`, `pkg-config`, `python3.9`, `meson`, `ninja`,
`flex`, `bison`, `m4`. So **g-ir-scanner runs on the device itself**; the probe it compiles and
runs is native arm64 Mach-O. qemu was never the right tool — we don't emulate, we run on the
real thing. This collapses the harder of the two gjs gates.

Net effect: the gjs/GNOME-Shell language/runtime base is now green, and the **GTK4 app stack on
top of it is proven** (typelibs scanned on-device, a gjs GTK4 window renders). The remaining
Shell-specific work is the Soup + Mutter (Meta/Clutter/Cogl/St) typelibs, Mutter-on-GL, and the
logind stub, tracked in gnome-plan #3/#4.

---

## Blocker #2 — introspection typelibs — SOLVED

### What was proven (2026-06-30, on `root@MaxsiPad.local`)

Built **gobject-introspection 1.78.0** from source *natively on the iPad* (no cross, no qemu)
and produced real typelibs, then loaded them through `libgirepository` exactly as gjs will:

```
gobject-introspection-1.78.0: meson + ninja build → exit 0
Generated typelibs: GLib-2.0 (211 KB), GObject-2.0 (62 KB), Gio-2.0 (368 KB),
                    GModule-2.0, GIRepository-2.0, + cairo/freetype2/fontconfig/libxml2
Runtime validation (g_irepository_require + g_irepository_find_by_name):
   GLib-2.0   → 893 infos, resolved GLib.DateTime
   GObject-2.0 → 271 infos
   Gio-2.0    → 772 infos, resolved Gio.File (GI_INFO_TYPE_OBJECT)
   => ALL_TYPELIBS_LOAD_OK
```

Typelib magic verified `GOBJ`. Evidence pulled to the build host. This is the **exact runtime
path** gjs/gnome-shell take (load `.typelib` for every namespace they touch), so it is a true
end-to-end proof, not a partial one.

### Why this works (and why the old plan thought it didn't)

`g-ir-scanner` produces a `.gir` partly by **compiling a small "dumper" that links the target
library and running it** to read GType/enum/struct-offset values out of the live ABI. The old
analysis assumed a cross-compile, where that dumper is a *target* (iOS Mach-O) binary you must
run under **qemu** — and qemu-user only executes Linux ELF. Dead end.

But the dumper is just a normal arm64 Mach-O program, and **the iPad runs those natively.** With
a native toolchain installed on the device, g-ir-scanner runs there directly: it compiles the
dumper with the device's `clang`, runs it natively, emits the `.gir`, and `g-ir-compiler` writes
the `.typelib`. No emulation anywhere. As a bonus, **g-i's own build scans glib**, so the
foundational GLib/GObject/Gio/GModule/GIRepository typelibs come out of the bootstrap for free.

### The six on-device frictions (all found and fixed)

These are Darwin/rootless quirks of building *on the device*. None is fatal; each has a one-line
fix. Folded into the reusable script (below).

1. **Rootless dyld search path.** On-device vanilla `clang` doesn't inject the `/var/jb/usr/lib`
   rpath that the Procursus cross-wrapper adds, so `@rpath/libgobject-2.0.0.dylib` won't load.
   Fix: `export DYLD_LIBRARY_PATH=/var/jb/usr/lib` for the build (or link with
   `-Wl,-rpath,/var/jb/usr/lib`).
2. **`ninja` hardcodes `/bin/sh`**, which doesn't exist on rootless (`/bin` is read-only; the
   shell is `/var/jb/bin/sh`). Same root cause as the Stage-0 xorg `os/utils.c` fix. Fix: the
   project's documented same-length trick — `ln -sf /var/jb/bin/sh /var/sh` and byte-patch a
   copy of `ninja` (`/bin/sh`→`/var/sh`, both 7 bytes) + re-sign with `ldid -S`. *(Only needed
   for the one-time on-device g-i **build**; per-library scanning uses no ninja — see Design A.)*
3. **`bison` SIGPIPEs (exit 141)** because Procursus's bison has a baked-in m4 path that doesn't
   exist on rootless; it pipes its skeleton through a missing m4 and dies. Fix:
   `export M4=/var/jb/usr/bin/m4`. *(Build-only; scanning doesn't run bison.)*
4. **`m4` must be installed** (`apt install m4`).
5. **`libpcre2-8.0.dylib` has a dangling `_SLJIT_UPDATE_WX_FLAGS`** (a Procursus pcre2 packaging
   quirk — the PCRE2-JIT W^X hook is left as a flat-namespace undefined). Two-level/lazy binding
   never trips it (a normal GObject program runs fine), but the giscanner **python C-extension**
   is linked `-undefined dynamic_lookup` (flat namespace), which forces eager resolution at
   `dlopen` → `ImportError: symbol not found '_SLJIT_UPDATE_WX_FLAGS'`. Fix: a tiny signed shim
   dylib that exports a no-op `SLJIT_UPDATE_WX_FLAGS`, injected with `DYLD_INSERT_LIBRARIES`.
   Safe because iOS can't get RWX, so pcre2 JIT never actually calls it (interpreter fallback).
6. **On-device `clang` defaults to the macOS platform** ("using sysroot for 'iPhoneOS' but
   targeting 'MacOSX'"), so the dumper object is macOS while `ld` defaults to iOS → mismatch.
   Fix: point the scanner's compiler at a one-token wrapper that forces
   `-target arm64-apple-ios14.0`.

### The reusable build step

Two designs; **Design A is proven and recommended now**, Design B is the "pure cross-repro"
upgrade for later.

**Design A — bootstrap g-i once, then scan each library on-device.** This is what the spike did.
- *Bootstrap (one-time):* build+install gobject-introspection on the device (or cross-build its
  `libgirepository`+tools in Docker with `-Dbuild_introspection_data=false` to dodge frictions
  #2/#3, then install). This yields `libgirepository`, `g-ir-scanner`, `g-ir-compiler`, and the
  foundational GLib/GObject/Gio typelibs.
- *Per-library typelib:* our C libraries are cross-built in Docker with `-Dintrospection=disabled`
  (unchanged). To get e.g. `Gtk-4.0.typelib`, install the lib's `-dev` deb on the device and run
  g-ir-scanner against its installed headers/lib. **Per-library scanning needs none of frictions
  #2/#3/#4** (no ninja, no bison/m4) — only the dyld path, the pcre2 shim, and the iOS-target CC
  wrapper. Package the resulting `.typelib`/`.gir` into `gir1.2-*` debs.
- Captured executably in **`linux-build/gir-ondevice.sh`** (bootstrap + a `scan <Namespace> <pkg>`
  subcommand). The introspection step is the one part of the pipeline that is *inherently*
  on-device — gnome-plan already conceded this ("not pure cross-repro for the introspection step
  only").

**Design B — cross-build with `gi_cross_binary_wrapper` (later, for full reproducibility).**
gobject-introspection's meson exposes `gi_cross_binary_wrapper` / `gi_cross_ldd_wrapper` /
`gi_cross_use_prebuilt_gi` for exactly this: cross-compile everything in Docker, but when the
scanner needs to *run* the dumper, it invokes a wrapper. Point that wrapper at an
`ssh root@MaxsiPad.local` runner (sign + scp the dumper + shuttle the in/out files + exec
remotely). Keeps typelib generation inside the deterministic recipe build, with the device as a
remote arm64 executor. More plumbing (the container needs ssh reachability to the device at build
time); defer until the on-device pass proves annoying to reproduce.

> **Synergy with gnome-track (Vala/vapi).** We now emit real **GIRs** on-device. gnome-track
> currently vendors `.vapi` for its Vala apps; a GIR can be run through `vapigen` (host, no target
> exec) to produce an exact in-tree `.vapi`. Not needed now (vendoring works), but the GIRs are
> available if they want to switch off the vendored shortcut.

### GTK4 stack typelibs — SCANNED ON-DEVICE (2026-06-30)

The Gtk/Gdk/Pango typelibs are **done**. Generated natively on the iPad and all load in gjs:

```
Graphene-1.0, HarfBuzz-0.0, GdkPixbuf-2.0 (+GdkPixdata),
Pango-1.0/PangoCairo-1.0/PangoFc-1.0/PangoFT2-1.0/PangoOT-1.0,
Gdk-4.0, GdkX11-4.0, Gsk-4.0, Gtk-4.0   →  imports.gi.Gtk == 4.14.5 in gjs
```

**Method (the most-native path; reinforces the "native + fast" north star).** Rather than
hand-write g-ir-scanner's enormous per-namespace invocations, each library's *own meson build*
drives g-ir-scanner — but run **natively on the device** (`-Dintrospection=enabled`). The dumper
meson compiles is native arm64 Mach-O and runs natively against the real installed ABI: no cross,
no qemu, no ssh dumper-shuttle. Captured executably in **`linux-build/gir-build-ondevice.sh`**
(`<source.tar> [meson -D opts...]`, optional `GIR_PREBUILD=` source patch). It builds only the
`.typelib` ninja targets (skips tests/tools/demos and unrelated libs e.g. hb-subset), installs
the `.gir`/`.typelib` into the device search dirs, and the chain validates in gjs.

*Device prep beyond the GI bootstrap (one-time, all reproducible):*
- Install the GTK-stack `-dev` debs + `apt-get install -f` (pulls freetype/png/pixman/x11/uuid/…).
- **Merge the full target pkg-config set** onto the device (`cp -n` from the Docker build sysroot
  `build_base/iphoneos-arm64-rootless/.../usr/{lib,share}/pkgconfig`, 87→197 .pc). The per-deb
  headers don't carry every transitive `.pc`; cairo/gtk4 have long `Requires.private` chains.
- `zlib.pc` shim (iOS ships libz in the dyld cache but no `.pc`; freetype2.pc Requires it) — the
  script writes this idempotently.
- Copy `EGL/ KHR/ GL/` headers + `X11/Xlib-xcb.h`, `X11/extensions/{composite,Xcomposite}.h` from
  the sysroot (libepoxy-dev/gdk-x11 need them; the device debs omitted them).
- pango patched (`GIR_PREBUILD`) to make `appleframeworks` non-required so CoreText stays off and
  it falls back to fontconfig/freetype — **matching how the shipped libpango deb was built** (a
  typelib must describe the installed lib; CoreText is only worth enabling under a future native
  Quartz/Metal GTK backend, not the X11+cairo path).

**Proof — a real gjs GTK4 app on the iPad.** `imports.gi.Gtk`, builds an `ApplicationWindow` →
`Box` → labels + button, `present()`s it on an X display, runs the main loop, `app.run() == 0`.
Rendered window captured from the framebuffer (`scratchpad/gtk4-shot.png`: "Hello from gjs on
iOS / GTK 4.14, typelibs scanned on-device", Adwaita dark, cairo renderer). Note: the running
**Xios.app is iOS-sandboxed** (its `/tmp/.X11-unix` socket is in its app container, unreachable
from an SSH/root context — the global `/tmp/.X11-unix/X5` is a stale leftover), so the proof ran
against a root-reachable **Xvfb :8**. Wiring gjs/GTK clients to the live Xios surface is a
separate display-plumbing item (same as XFCE-on-Xios via `bin/xfce-up.sh`).

### What still needs doing for the Shell's typelibs

gnome-shell additionally needs **Soup** and **Mutter's own Meta/Clutter/Cogl/Cally/St**. The
Mutter ones can only be scanned **after** mutter builds (Shell-only, gated on Blocker #1+#3).
**Adw-1** (libadwaita 1.5.0) is **DONE** — scanned on-device via `gir-build-ondevice.sh` (3 darwin
patches from libadwaita.mk passed as `GIR_PREBUILD`: neutralise the macOS settings backend in
`src/meson.build` + the `__APPLE__` gates in `adw-settings*`; needed `libappstream-dev` configured
first). A gjs **AdwApplicationWindow + AdwHeaderBar + AdwStatusPage** renders on-device
(`scratchpad/adw-shot.png`). The modern GNOME app surface is now reachable in gjs. Remaining for the
Shell: **Soup** + **Mutter** (Meta/Clutter/Cogl/St, gated on the mutter build).

---

## Blocker #1 — mozjs115 / SpiderMonkey (JIT-less) — SOLVED

gjs 1.78 (the glib-2.78 generation) embeds **mozjs115** (Firefox ESR 115 SpiderMonkey). This is
the genuinely hard cross-compile in the whole tree. It started as a heavy-build draft, but the
build and on-device runtime smoke are now complete; the original risk analysis below is retained
as implementation context.

### What makes it tractable

- **JIT-less is a real, supported config.** `--disable-jit` selects the portable C++ interpreter
  (codegen "none"). iOS forbids RWX/dynamic-codesign, so this is mandatory and correct — only
  slower (interpreter is several× the JIT; gnome-shell animation would be sluggish but functional).
  Prior art: `gameclosure/spidermonkey-ios`, Mozilla bug 1102925.
- The dependencies exist: **system ICU** (Procursus `icu4c`), **readline/zlib** (have), and the
  build only needs host Python 3 + Rust + the cctools cross toolchain we already run.

### What makes it hard (the friction to expect)

- **Linux→Apple Mach-O cross of mozjs is under-trodden.** Homebrew/MacPorts build mozjs *on*
  macOS; almost nobody cross-compiles it from Linux. Expect host-vs-target tool confusion and
  `build/moz.configure` checks that assume they can run target binaries.
- **Rust.** mozjs115 needs a *recent* Rust with the `aarch64-apple-ios` std target. Procursus's
  `rust.mk` is WIP and pins 1.56 (too old). **Use a host `rustup` toolchain** (current stable)
  with `rustup target add aarch64-apple-ios` — a **build-host tool**, added to the `Dockerfile`,
  not a Procursus recipe. cbindgen + the `aarch64-apple-ios` target are the load-bearing bits.
- **The linker.** SpiderMonkey wants to run just-built host tools (the `host` parts of the build
  must target Linux while the `target` parts target iOS). moz.configure's `--host`/`--target`
  split must be set explicitly or it builds the JS shell for the wrong platform.
- **No JIT atomics / `mozglue` bits** sometimes assume a writable-executable mapping; with
  `--disable-jit` those paths are compiled out, but watch `js/src/jit` references that leak.
- **`moz.configure` may run target-compiled probe binaries** (the same pattern as the
  introspection dumper). If a configure check insists on *executing* an iOS binary on the Linux
  host it fails — and the **same escape applies**: run those probes on-device (ssh-to-iPad exec
  wrapper) or supply the answer via a cross cache. The most likely "stuck" point once the
  toolchain is wired; watch the configure log for it.

### BUILD RESULT — mozjs115 BUILT for iOS (2026-06-30, `procursus-vol-gjs`, `--cpus=3`)

**SOLVED.** JIT-less SpiderMonkey 115 cross-compiled Linux→iOS. `libmozjs-115.dylib` verified
Mach-O ARM64, `LC_BUILD_VERSION platform=iOS`, minos 14.0, JS API symbols present
(`JS_NewContext`/`JS_Init`); plus `libjs_static.a`. (First pass `--without-intl-api`; Intl rebuild
with bundled in-tree ICU follows.)

**Host setup (build-gjs.sh):** rustup (1.96) + `rustup target add aarch64-apple-ios`, cbindgen
0.26, nasm. **Put `CARGO_HOME`/`RUSTUP_HOME` on the build volume** (ephemeral container `$HOME`
vanishes on `--rm`). Source: firefox-115.12.0esr (482 MB).

**The fixes — 3 source patches + 3 build-env, all in-tree now:**

*Configure (→ clean for `--target=aarch64-apple-ios`):*
1. `config.sub`: mozjs's 5 bundled copies don't know `ios` → replace with the host's
   `/usr/share/misc/config.sub` (recipe does this).
2. **patch 0001** — `moz.configure` iOS target: `init.configure` `split_triplet` had no `ios`
   case (only `darwin`→OSX) and the `OS` EnumString (`constants.py`) lacked `iOS`. Add both
   (kernel=Darwin, os=iOS). Because `os != OSX`, the macOS-SDK demand + `-mmacosx-version-min`
   injection (both gated on OSX) are naturally skipped — CC's `-target arm64-apple-ios` drives it.
3. **ld64 wiring**: moz's ld64 probe hardcodes `-fuse-ld=ld`, so symlink the cctools ld as `ld`,
   add `-B<cctools-bin>` to CC, `--enable-linker=ld64`. cctools `ld64-956.6` emits the
   "Logging ld64 options" signature moz IDs it by, and links valid iOS Mach-O.

*Build (`mach build`):*
4. Rust **cc-crate**: it runs `xcrun --show-sdk-path --sdk iphoneos` to find the iOS SDK — no
   xcrun on Linux → a fake `xcrun` shim returning the iPhoneOS SDK. And `CRATE_CC_NO_DEFAULTS=1`:
   the cc-crate auto-adds `-fembed-bitcode` for iOS, which conflicts with mozbuild's
   `-ffunction-sections`; with it, cc uses only moz's full CXXFLAGS.
5. **patch 0002** — drop the JS shell (`js/src/shell` uses `system()`/`fork()`, unavailable on
   iOS; not needed for embedding). It's grouped with the `rust` dir under one conditional, so
   remove only the `"shell"` DIRS entry (keep `rust` — libmozjs needs jsrust/mozglue).
6. **patch 0003** — `old-configure.in`: its `case "$target"` Darwin branches matched only
   `*-darwin*`, so iOS fell through to ELF defaults (`MOZ_FIX_LINK_PATHS="-Wl,-rpath-link,..."`,
   which cctools ld64 rejects). Extend the three darwin cases to `*-darwin*|*-ios*`.

Drivers: `scratchpad/mozjs-derisk*.sh`, `mozjs-configure{2..7}.sh`, `mozjs-b{4,5,6}.sh` (logs on
the volume). All baked into `ports/mozjs/patches/000{1,2,3}-*` + `recipes/mozjs.mk` + the mozconfig.

### Packaged + on-device status

- **Packaged** (`linux-build/build-gjs.sh` with `TARGETS="mozjs-package"`, output in
  `linux-build/out/`):
  `libmozjs-115-0` (7.1MB dylib) + `libmozjs-115-dev` (92MB; headers under `include/mozjs-115`
  + `libjs_static.a`). Ready to publish.
- **On-device (root@MaxsiPad.local):** a cross-compiled JSAPI test loads libmozjs and runs.
  **`JS_Init()` succeeds on the A10**, and as of **2026-06-30 `JS_NewContext()` succeeds too** —
  the full JSAPI lifecycle now runs end-to-end: `JS_NewContext` → `InitSelfHostedCode` →
  `JS_NewGlobalObject` → compile + `JS::Evaluate("40 + 2*(' '.length)")` → `42`, exit 0, 5/5
  stable. **SpiderMonkey runs on the A10.** Harness: `scratchpad/build-jstest{,2,3}.sh` +
  `jstest_fix` (full eval); test dir on-device `/var/jb/tmp/mozjs-test`.

  **Root cause of the old `JS_NewContext()` SIGSEGV (FIXED — patch 0004).** The "null deref ~180
  bytes into `js::Thread::create`" was not a stray pointer: it was a *failed* `MOZ_RELEASE_ASSERT`.
  `MOZ_CRASH`'s release body is `*((volatile int*)NULL) = __LINE__; abort();` — a deliberate
  write to address 0. The assert that fired is the one after `pthread_attr_setstacksize`:
  SpiderMonkey's helper-thread pool (started during context creation) requests
  `HELPER_STACK_SIZE = 2*1024*1024 - 2*4096 = 2088960` bytes, which is 4 KiB-aligned but **not**
  16 KiB-aligned. On arm64 iOS the page size is **16384** (`PTHREAD_STACK_MIN` is also 16384), and
  Darwin's `pthread_attr_setstacksize` returns **EINVAL** unless the size is a page multiple
  (`2088960 % 16384 == 8192`). Proven on-device with a standalone probe (`setstacksize(2088960) →
  22 EINVAL`; `setstacksize(2097152) → 0 OK`). **Fix (`patches/0004-posix-thread-ios-stacksize-align.patch`):**
  in `js::Thread::create`, round the requested stack size up to `sysconf(_SC_PAGESIZE)` and clamp
  to `PTHREAD_STACK_MIN` (under `#ifdef XP_DARWIN`) before the `setstacksize` call. One-line-class
  fix, in-tree now; debs in `linux-build/out/` refreshed with the corrected dylib.

### Draft cross `mozconfig`

Shipped as **`linux-build/build_info/mozjs115.mozconfig`** (consumed by the recipe; reproduced
here for review):

```sh
# mozjs115 — JIT-less SpiderMonkey, Linux→iOS arm64 Mach-O cross.
ac_add_options --enable-project=js
ac_add_options --target=aarch64-apple-ios
ac_add_options --host=aarch64-unknown-linux-gnu     # build host = the arm64 Linux container
ac_add_options --disable-jit                        # interpreter-only (iOS: no RWX)
ac_add_options --disable-jemalloc                   # use system allocator
ac_add_options --without-intl-api                   # OR --with-system-icu (Procursus icu4c)
ac_add_options --disable-tests
ac_add_options --disable-debug
ac_add_options --enable-optimize
ac_add_options --enable-release
ac_add_options --disable-export-js                  # static-ish embed; gjs links the static lib
ac_add_options --with-system-zlib
ac_add_options --enable-readline

# Cross toolchain (the cctools-port aarch64-apple-darwin we already use for everything else)
CC="aarch64-apple-darwin-clang -target arm64-apple-ios14.0 -isysroot $TARGET_SYSROOT"
CXX="aarch64-apple-darwin-clang++ -target arm64-apple-ios14.0 -isysroot $TARGET_SYSROOT -stdlib=libc++"
AR=aarch64-apple-darwin-ar
# Host tools (build-time codegen) target the Linux container:
HOST_CC=clang
HOST_CXX=clang++
# Rust cross target:
export RUSTFLAGS="-Clink-args=-isysroot $TARGET_SYSROOT"
# (rustup target add aarch64-apple-ios on the build host)
```

### Draft recipe

Shipped as **`linux-build/recipes/mozjs.mk`** (modelled on the house meson recipes but driving
`mach`/`python3 configure` instead of meson). Outputs `libmozjs-115-0` + `libmozjs-115-dev`
(static `libjs_static.a` + headers + `js-config`). **Unbuilt draft.** It pins mozjs 115 ESR,
applies a small quilt series for iOS portability (signal handlers, `posix_spawn`/`/bin/sh`-free
process launch, `__builtin_available` guards), and runs `mach build`/`mach build install`.

### Estimate

Multi-day at best; the Rust + mach + cctools cross is the friction, not the JIT-less part. This
is the single longest pole on the gjs path. Recommend it be a **dedicated, gated build** once
Docker frees, after a short de-risk: first get `mach configure` to *complete* for the cross
target (no compile), which surfaces 90% of the host/target tool problems cheaply.

---

## Staged plan: introspection → gjs → gnome-shell

**G0 — introspection bootstrap + packaged debs (DONE).**
Built g-i on-device and packaged 5 installable debs (`gi-package.sh`, in `linux-build/out/`),
dpkg-installed + re-validated from the installed prefix (see "Packaged debs" below). The
**GTK4-stack scan is now also DONE** (Graphene/HarfBuzz/GdkPixbuf/Pango/Gdk-4.0/Gsk-4.0/Gtk-4.0,
via `gir-build-ondevice.sh`) — see "GTK4 stack typelibs" above.

**G1 — mozjs115 (gated).** De-risk `mach configure` for the cross target, then the full JIT-less
build → `libmozjs-115` debs. Longest pole.

**G2 — gjs 1.78 (DONE).** Built via `linux-build/build-gjs-manual.sh` against the staged
mozjs115/GI artifacts, packaged as `libgjs0`, `gjs`, and `libgjs-dev`, and installed on-device.
The `libgjs0` package is relinked to the `libgtkintl` shim for the `g_libintl_*` imports.
`GjsPrivate-1.0.typelib` is generated on-device and packed under
`/var/jb/usr/lib/gjs/girepository-1.0`. Runtime smoke:
`gjs --version`, `print(42)`, and `imports.gi.GLib`/`GObject`/`Gio` all pass on the iPad.

**G3 — gnome-shell (Shell milestone, after gjs + mutter).** Scan Mutter's
Meta/Clutter/Cogl/St typelibs (G0 mechanism), stub `org.freedesktop.login1` (gnome-plan #4),
then `gnome-shell`. High risk; explicitly a research milestone. **Soup-3.0 DONE** (gjs `Session`
+ `Message` validated). Scoping (2026-06-30): mutter-46.0 source fetched; deps mostly present
(`wayland-server` 1.23, `wayland-protocols` 1.38, `xkbcommon` 1.7, `gsettings-desktop-schemas`
46.1, `gl`/`glesv2` 21.0.2); missing `egl.pc` + `json-glib.pc` (+ the large X dep set if x11).

> **Hardware/GPU reality for the Shell (decisive).** A *hardware* gnome-shell cannot run on
> Mutter-as-X11-WM. Mutter-on-X11 GPU-composites by binding redirected client **X11 pixmaps**
> as GL textures (`texture-from-pixmap`), which needs **hardware DRI inside the X server** —
> `Xios` is a userspace **software** X server on iOS, so it has none, and even mesa can only do
> *software* GLX against it. **ANGLE can't substitute**: ANGLE-iOS is Metal-only with no X11
> platform (can't import X11 pixmaps) and its output is a `CAMetalLayer`/IOSurface, not an X11
> drawable. So on this stack **GPU compositing is only reachable via Wayland** (clients hand the
> compositor IOSurface/dmabuf buffers; compositor renders to the display IOSurface via ANGLE/
> Metal) — i.e. the **iosc** architecture. A *hardware* gnome-shell therefore = **Mutter running
> as a Wayland compositor with an iOS/IOSurface backend** (a new `MetaBackend` over iosc's
> ANGLE→Metal→IOSurface output + buffer-import), NOT Mutter-X11 (software-only, llvmpipe).
> The `Meta/Clutter/Cogl/St` **typelibs are backend-agnostic**, so they can be generated (Mutter
> linked against ANGLE `libEGL`/`libGLESv2` for symbols) to unblock gjs shell code-loading
> *independent* of which display backend wins — coordinate the backend with the iosc track.

### Mutter 46 CROSS-BUILT for iOS (2026-06-30) — `libmutter`/Cogl/Clutter/Mtk all link

**Mutter 46 — a Linux compositor — cross-compiles + links to iOS arm64 Mach-O**, fully off-device
in Docker (`build-mutter.sh` + `recipes/mutter.mk`). Produced `libmutter-14`, `libmutter-cogl-14`,
`libmutter-cogl-pango-14`, `libmutter-clutter-14`, `libmutter-mtk-14`. Built as a **Wayland**
compositor (`-Dwayland=true`, native/KMS backend OFF, `-Dintrospection=false` — the typelibs are
scanned ON-DEVICE next, Design A). All deps real and reproducible:

- **Built/bumped 7 real deps:** lcms2, libxcomposite, xkbcommon-x11, json-glib, **real libcolord**
  (client-only: `-Dpnp_ids` non-udev path + guarded include + dropped colorhug/data — NOT a stub),
  **pixman 0.42.2** (meson; SIMD asm disabled for clang), **libXfixes 6.0.1** (mutter needs ≥6).
- **Three links-only shims** for Linux-kernel subsystems with no iOS path (clearly marked, dmabuf/
  input/session inert → IOSurface/logind-stub later): **libdrm** (real headers + stubbed `drm*`),
  **libei/libeis** (real headers + stubbed `eis_*`), and stub `<linux/dma-buf.h>` + `<systemd/
  sd-login.h>` headers. EGL/GLES staged from ANGLE; `eglmesaext.h` from mesa src.
- **Source/config patches** for the untested **wayland + x11 + no-native** combo: `meta-context-
  main.c` bodiless-else fix + `sd_pid_get_user_unit` guarded to `HAVE_LIBSYSTEMD` (falls back to
  MANDATORY X11 policy), `libei/libeis`/`libdrm`/`colord` daemon deps made non-required,
  `-DSOCK_CLOEXEC=0` for Darwin sockets.
- **Cross-build viability proven:** mutter has **zero compile-and-run meson checks** and all codegen
  uses host tools (glib-mkenums/gdbus-codegen/wayland-scanner), so the off-device cross-build needs
  no target-binary execution (`exe_wrapper='/bin/true'` only satisfies the meson sanity check).

**Next (on-device, coordinated with iosc):** install the mutter debs + `g-ir-scanner` →
`Meta-14`/`Clutter-14`/`Cogl-14`/`Mtk-14` typelibs → `imports.gi.Meta` in gjs. The dmabuf→IOSurface
buffer path (the inert shimmed bits) is the **MetaBackendIOS** running-compositor effort.

**Off-critical-path win unlocked now:** with typelibs working, **gjs-based *apps*** (not just the
Shell) become reachable once gjs (G2) lands — e.g. simple GJS GTK4 programs — without ever
touching mutter/logind. Good intermediate proof that the runtime is real. **DONE** (GTK4 stack
typelibs + a rendered gjs GTK4 window, 2026-06-30).

**Display direction — converge on `iosc` (Wayland), not X11.** Per the native+fast north star,
gjs/GTK apps should ultimately display through the **`iosc`** Wayland compositor (zero-copy
IOSurface; see `x11/wayland`, the wayland-m1-compositor track) rather than the software X11/Xvfb
path used for today's proof. The typelib work is backend-agnostic (Gtk-4.0.gir is identical), so
keep generating typelibs now (Adw-1 next); the display convergence is a separate step — build/enable
GTK4's **Wayland backend** and point `GDK_BACKEND=wayland` at iosc — coordinated with the Wayland
track (complementary, not overlapping: gjs = scriptable GNOME/apps, Wayland = the GPU display).

---

## Packaged debs (shipped)

`linux-build/gi-package.sh` runs on the device (`meson install` → lay out the Procursus package
split → `ldid` sign → `dpkg-deb`). Built + dpkg-installed cleanly into `/var/jb` and re-validated
loading typelibs from their **installed** location. In `linux-build/out/`, for the GNOME wave:

| deb | contents |
|---|---|
| `libgirepository-1.0-1` | runtime loader (`/var/jb/usr/lib` rpath added for parity) |
| `gir1.2-glib-2.0` | GLib/GObject/Gio/GModule/GIRepository typelibs |
| `gir1.2-freedesktop` | cairo/freetype2/fontconfig/libxml2/GL/Vulkan/x* typelibs |
| `gobject-introspection` | `g-ir-scanner`/`compiler`/`generate` + giscanner python module |
| `libgirepository-1.0-dev` | headers, `.pc`, gir XML |

All `1.78.0`, `iphoneos-arm64`, control split matching Procursus.

## Reproduction

The full proven procedure is in **`linux-build/gir-ondevice.sh`** (`bootstrap` + `scan`);
packaging is **`linux-build/gi-package.sh`**. Device prerequisites `bootstrap` installs via
`apt`: `clang odcctools ld64 pkg-config python3 libpython3.9-dev meson ninja make
m4 flex bison libffi-dev libglib2.0-dev libpcre2-dev gettext`. Build host only needs to `scp` the
g-i tarball (the device has no `xz`, so decompress to `.tar` first). Scratch dir
`/var/jb/tmp/gi-spike`; touches no X display (`:2`/`:5` left alone).
