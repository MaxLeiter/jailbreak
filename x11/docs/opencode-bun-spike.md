# OpenCode / Bun iOS Spike

Goal: run OpenCode inside the iosc Wayland desktop by building everything off
device, packaging for rootless iOS, and running only the final binaries on the
A10 iPad.

## Current Findings

- Current OpenCode (`anomalyco/opencode`) is a Bun/TypeScript app compiled into
  platform binaries. It does not ship an iOS target.
- Bun's upstream release platform table includes Darwin, Linux, Linux musl,
  Android, FreeBSD, and Windows. It does not include iOS.
- Re-signing the upstream `bun-darwin-aarch64` binary is not enough. On the iPad
  it fails in dyld while loading macOS-platform libraries, e.g.
  `/usr/lib/libicucore.A.dylib` is present only as the wrong platform for this
  process.

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

## Next Step

Patch Bun's build configuration to add an iPhoneOS target instead of repackaging
the Darwin binary. The repo's existing Docker image already has the useful
pieces: arm64 Debian host, cctools-port, staged iPhoneOS SDK, `ldid`, clang,
cmake, ninja, git, and curl. The likely work is in Bun's build configuration,
dependency build flags, JavaScriptCore/WebKit linkage, ICU, libuv/kqueue, and
Mach-O post-link/signing.
