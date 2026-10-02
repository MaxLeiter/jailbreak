# OpenCode / Bun iOS Package

Goal: run OpenCode on the jailbroken iPad by building off-device, packaging for
rootless iOS, and installing only debs on the device.

## Status

- `bun` is built from pinned upstream Bun source for iPhoneOS arm64/A10.
- `opencode` is built from pinned upstream OpenCode source as a Bun-targeted JS
  bundle and installed behind `/var/jb/usr/bin/opencode`.
- Both packages are installed on the iPad and published at
  `https://repo.maxleiter.com`.

Published packages:

```text
bun 1.4.0~canary.1+git5b55beb711+ios0.4
opencode 1.17.13~ios0.5
```

`bun ...+ios0.5` (JavaScriptCore JIT, below) is built but **not yet published**
and not yet installed from its deb — the device it was validated on went off
the network mid-session, so the deb in `linux-build/out/` has not been through
an install-and-verify pass. See the acceptance tests in
`linux-build/probes-bun-jit/`.

On-device verification:

```sh
/var/jb/usr/bin/bun -e 'const fs=require("fs"); console.log(fs.realpathSync("/var/jb/tmp"))'
TMPDIR=/var/jb/tmp TMP=/var/jb/tmp TEMP=/var/jb/tmp /var/jb/usr/bin/opencode --version
```

Expected output includes the real `/private/preboot/.../procursus/tmp` path and:

```text
1.17.13
```

## JavaScriptCore JIT

`+ios0.5` turns the JIT on (baseline + DFG). Everything through `+ios0.4` ran
`ENABLE_JIT=OFF`, which is not as slow as it sounds — `ENABLE_C_LOOP` was never
on, so those builds ran the assembly LLInt rather than the C-loop interpreter.

FTL stays off, and with it the wasm BBQ/OMG tiers (they depend on it in
`WebKitFeatures.cmake`). FTL wants B3/Air and signal-based wasm memory, and the
iOS SDK ships no `mach/mach_exc.defs`, so `HAVE(MACH_EXCEPTIONS)` is 0 here and
JSC falls back to POSIX signal handlers. Revisiting FTL means solving that
first.

The memory model is the interesting part, and it is not JSC's default. Measured
on the A10 (probes and full results in `linux-build/probes-bun-jit/`):

- `MAP_JIT` is refused (`EINVAL`) bare-fakesigned.
- An RWX mapping is created without complaint and then **SIGBUSes on the first
  instruction fetch**, so writing straight through an RWX pool is out.
- `mach_vm_remap` gives a working RW alias of an RX region — which is exactly
  `ENABLE(SEPARATED_WX_HEAP)`, still present in bun's WebKit.
- But iOS will not fault a dirty anonymous page into a *fresh* executable
  mapping. It will re-protect a page that already has an entry there. So every
  page of the pool has to pass through the exec mapping as RW once and flip to
  RX; after that, alias writes are executed by the RX view for the life of the
  process.

`patches/bun-webkit/0002-ios-separated-wx-jit.patch` implements that: it turns
on `HAVE_REMAP_JIT` and `ENABLE_SEPARATED_WX_HEAP` for the port (JSCOnly defines
no `PLATFORM()`, so every gate that would have selected this path was off),
drops `MAP_JIT` from the reservation, does the RW→touch→RX pass in
`OSAllocator::commit()`, and leaves the exec view's *maximum* protection at RWX
so that pass is permitted. `USE(EXECUTE_ONLY_JIT_WRITE_FUNCTION)` stays off —
it needs execute-only memory, which the A10 does not have.

## Rebuild

Pinned inputs:

- Bun/WebKit: `linux-build/build_info/bun-ios.lock`
- OpenCode: `linux-build/build_info/opencode.lock`
- Bun patch: `linux-build/patches/bun/0001-add-iphoneos-a10-target.patch`
- TinyCC patch: `linux-build/patches/tinycc/tccrun-ios-mmap.patch`
- WebKit patches: `linux-build/patches/bun-webkit/` (applied in glob order)

Build Bun:

```sh
PACKAGE=1 LLVM_PREFIX=/opt/homebrew/opt/llvm@21 bash linux-build/run-bun-ios.sh
```

Build OpenCode:

```sh
bash linux-build/build-opentui-ios.sh
bash linux-build/build-fff-ios.sh
PACKAGE=1 SMOKE_DEVICE=1 bash linux-build/build-opencode.sh
```

Publish:

```sh
cp linux-build/out/bun_1.4.0~canary.1+git5b55beb711+ios0.4_iphoneos-arm64.deb ../repo/debs/
cp linux-build/out/opencode_1.17.13~ios0.5_iphoneos-arm64.deb ../repo/debs/
../bin/publish-repo.sh
```

## Package Layout

`bun`:

- `/var/jb/usr/libexec/bun-ios/bun`
- `/var/jb/usr/bin/bun`

The wrapper sets `GIGACAGE_ENABLED=0` before executing the iOS Bun binary. Bun
currently prints a JavaScriptCore warning when Gigacage is disabled; it is noisy
but expected.

`opencode`:

- `/var/jb/usr/libexec/opencode-js/*`
- `/var/jb/usr/bin/opencode`
- `/var/jb/usr/libexec/opencode-js/libopentui.dylib`
- `/var/jb/usr/libexec/opencode-js/libfff_c.dylib`

The wrapper sets `TMPDIR`, `TMP`, and `TEMP` to `/var/jb/tmp` by default and
executes the bundled OpenCode entrypoint with `/var/jb/usr/bin/bun`.
The package depends on `bun` and `ripgrep`; the bundled OpenTUI and fff dylibs
cover the native TUI renderer and preferred fuzzy search backend.

## Notes

- Bun's `macho-postlink` helper still gets killed after the link on this build
  host. `linux-build/build-bun-ios.sh` accepts that specific post-link failure
  only when the linked `bun-profile` binary exists, then packages that binary.
- Bun package revisions from `ios0.2` onward include the OpenCode startup fix:
  iOS is treated like macOS for `get_fd_path`/`F_GETPATH`, which makes
  `fs.realpathSync` work on rootless iOS paths.
