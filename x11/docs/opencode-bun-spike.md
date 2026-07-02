# OpenCode / Bun iOS Spike

Goal: run OpenCode inside the iosc Wayland desktop by building everything off
device, packaging for rootless iOS, and running only the final binaries on the
A10 iPad.

## Current Findings

- Current OpenCode (`anomalyco/opencode`) is a Bun/TypeScript app compiled into
  platform binaries. It does not ship an iOS target.
- The current npm release checked here is `opencode-ai` / `opencode-darwin-arm64`
  `1.17.13` (`anomalyco/opencode` tag `v1.17.13`, commit
  `10c894bdeef3618f5666fb506ef7f9491bb964d8`).
- The pinned OpenCode inputs live in `linux-build/build_info/opencode.lock`;
  bumping OpenCode is an explicit version, commit, and tarball SHA-512 change.
- Bun's upstream release platform table includes Darwin, Linux, Linux musl,
  Android, FreeBSD, and Windows. It does not include iOS.
- Re-signing the upstream `bun-darwin-aarch64` binary is not enough. On the iPad
  it fails in dyld while loading macOS-platform libraries, e.g.
  `/usr/lib/libicucore.A.dylib` is present only as the wrong platform for this
  process.
- Re-stamping the upstream OpenCode Darwin arm64 standalone as iOS fixes that
  first dyld platform failure, but exposes macOS-only Bun runtime imports:
  `___clear_cache`, `_pthread_jit_write_protect_np`, and
  `_pthread_jit_write_protect_supported_np`.
- `linux-build/tools/macho-opencode-ios-patch.py` reproducibly adds a tiny iOS
  shim dylib and rewrites only those chained-fixups imports to the shim.
- After that patch, both OpenCode and a one-line Bun standalone still crash on
  iPad7,12/A10 with `SIGILL` before `main`, inside the upstream macOS Bun
  runtime initializer. The first faulting instruction was ARMv8.3 `ldapr`; a
  local experiment rewrote all 756 `ldapr` instructions to older `ldar`, which
  moved the crash to ARMv8.1 LSE `casal`. A10 does not support LSE atomics, and
  replacing scattered atomics with LL/SC loops is not a safe Mach-O patch. That
  makes the current upstream standalone payload a non-release path; we need an
  actual iOS/A10-safe Bun runtime build (`arm64-apple-ios`, no LSE/RCpc).

## Harness

Use the isolated spike runner:

```bash
bash linux-build/run-bun.sh
```

Artifacts land in `linux-build/out/`:

- `bun-preflight`: a tiny `iphoneos-arm64` binary built with the repo's
  cctools/iPhoneOS SDK path. This proves the build/sign/deploy loop.
- `bun-preflight_0.0.1_iphoneos-arm64.deb`: the same smoke binary packaged as a
  rootless deb.
- `bun-darwin-arm64-upstream`: the upstream macOS Bun binary, kept only as an
  expected-failure probe.

To also run the probes on the device:

```bash
DEPLOY=1 bash linux-build/run-bun.sh
```

Use the OpenCode bring-up runner:

```bash
bash linux-build/run-opencode.sh
```

It sources `linux-build/build_info/opencode.lock`, fetches the pinned
`opencode-darwin-arm64@1.17.13` npm tarball with scripts disabled, verifies the
SHA-512 integrity, builds the tracked iOS shim source, restamps/patches the
Mach-O, signs the binary and shim, and runs an on-device smoke test. It
intentionally refuses to build an installable `opencode` deb until that smoke
test passes. Set `PACKAGE=1 SMOKE_DEVICE=1` only after the runtime blocker is
fixed.

## Next Step

Patch Bun's build configuration to add an iPhoneOS target instead of repackaging
the Darwin binary. The repo's existing Docker image already has the useful
pieces: arm64 Debian host, cctools-port, staged iPhoneOS SDK, `ldid`, clang,
cmake, ninja, git, and curl. The likely work is in Bun's build configuration,
dependency build flags, JavaScriptCore/WebKit linkage, ICU, libuv/kqueue, and
Mach-O post-link/signing.
