# gjs on the X11-for-iOS stack — feasibility, the introspection breakthrough, and the mozjs plan

Status: **Phase 1.** Owner: `gjs-track`. Sibling docs: [`gnome-plan.md`](gnome-plan.md)
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

The decisive reframe: **the device is a full arm64 Darwin machine.** Procursus `apt` ships a
native toolchain — `clang-16`, `odcctools`+`ld64`, `pkg-config`, `python3.9`, `meson`, `ninja`,
`flex`, `bison`, `m4`. So **g-ir-scanner runs on the device itself**; the probe it compiles and
runs is native arm64 Mach-O. qemu was never the right tool — we don't emulate, we run on the
real thing. This collapses the harder of the two gjs gates.

Net effect: the gjs/GNOME-Shell critical path is now **mozjs115 only** (plus Mutter-on-GL and
the logind stub, which are Shell-specific and tracked in gnome-plan #3/#4).

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

### What still needs doing for the Shell's typelibs

gnome-shell consumes typelibs for **Gtk-4.0, Gdk-4.0, Gsk-4.0, Pango, Soup, and Mutter's own
Meta/Clutter/Cogl/Cally/St**. The Mutter ones can only be scanned **after** mutter builds
(Shell-only, gated on Blocker #1+#3). The Gtk/Gdk/Pango ones can be scanned as soon as those
libs are installed on the device — a good incremental task that also benefits any future
gjs-based *app* (not just the Shell).

---

## Blocker #1 — mozjs115 / SpiderMonkey (JIT-less) — DRAFT (heavy build gated)

gjs 1.78 (the glib-2.78 generation) embeds **mozjs115** (Firefox ESR 115 SpiderMonkey). This is
the genuinely hard cross-compile in the whole tree. **Drafted here; not built** — per coordinator,
check before kicking the heavy build (Docker is loaded).

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

- **Packaged** (`linux-build/build-mozjs-debs.sh`, in `linux-build/out/`):
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
dpkg-installed + re-validated from the installed prefix (see "Packaged debs" below). Remaining:
a `scan` pass for Gtk-4.0/Gdk-4.0/Pango once gtk4 is installed on-device (gated on gtk-builder's
gtk4-on-device green) — useful to *any* future gjs app, independent of the Shell.

**G1 — mozjs115 (gated).** De-risk `mach configure` for the cross target, then the full JIT-less
build → `libmozjs-115` debs. Longest pole.

**G2 — gjs 1.78.** Needs mozjs115 + glib + the typelibs from G0 + `cairo`. meson cross-build
(`-Dprofiler=false`, JIT-less mozjs). Deliverable: run a hello-world gjs script that does
`imports.gi.GLib`/`imports.gi.Gio` against the G0 typelibs **on-device**. This is the moment the
whole gjs path is proven end-to-end.

**G3 — gnome-shell (Shell milestone, after gjs + mutter).** Build **mutter** (`-Dx11=true`,
GNOME ≤48) on the software/ANGLE GL path (gnome-plan #3), scan its Meta/Clutter/Cogl/St typelibs
on-device (G0 mechanism), stub `org.freedesktop.login1` (gnome-plan #4, coordinate with
gnome-track's dconf), then `gnome-shell --x11`. High risk; explicitly a research milestone.

**Off-critical-path win unlocked now:** with typelibs working, **gjs-based *apps*** (not just the
Shell) become reachable once gjs (G2) lands — e.g. simple GJS GTK4 programs — without ever
touching mutter/logind. Good intermediate proof that the runtime is real.

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
