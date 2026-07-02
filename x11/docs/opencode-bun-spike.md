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
bun 1.4.0~canary.1+git5b55beb711+ios0.2
opencode 1.17.13~ios0.1
```

On-device verification:

```sh
/var/jb/usr/bin/bun -e 'const fs=require("fs"); console.log(fs.realpathSync("/var/jb/tmp"))'
TMPDIR=/var/jb/tmp TMP=/var/jb/tmp TEMP=/var/jb/tmp /var/jb/usr/bin/opencode --version
```

Expected output includes the real `/private/preboot/.../procursus/tmp` path and:

```text
1.17.13
```

## Rebuild

Pinned inputs:

- Bun/WebKit: `linux-build/build_info/bun-ios.lock`
- OpenCode: `linux-build/build_info/opencode.lock`
- Bun patch: `linux-build/patches/bun/0001-add-iphoneos-a10-target.patch`
- WebKit patch: `linux-build/patches/bun-webkit/0001-jsconly-skip-mach-exceptions-ios.patch`

Build Bun:

```sh
PACKAGE=1 LLVM_PREFIX=/opt/homebrew/opt/llvm@21 bash linux-build/run-bun-ios.sh
```

Build OpenCode:

```sh
PACKAGE=1 SMOKE_DEVICE=1 bash linux-build/build-opencode.sh
```

Publish:

```sh
cp linux-build/out/bun_1.4.0~canary.1+git5b55beb711+ios0.2_iphoneos-arm64.deb ../repo/debs/
cp linux-build/out/opencode_1.17.13~ios0.1_iphoneos-arm64.deb ../repo/debs/
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

The wrapper sets `TMPDIR`, `TMP`, and `TEMP` to `/var/jb/tmp` by default and
executes the bundled OpenCode entrypoint with `/var/jb/usr/bin/bun`.

## Notes

- The old approach of repackaging upstream `opencode-darwin-arm64` is retained
  only as historical context: the embedded macOS Bun runtime used unsupported
  A10 instructions and is not the release path.
- Bun's `macho-postlink` helper still gets killed after the link on this build
  host. `linux-build/build-bun-ios.sh` accepts that specific post-link failure
  only when the linked `bun-profile` binary exists, then packages that binary.
- The `ios0.2` Bun package fixes the OpenCode startup blocker by treating iOS
  like macOS for `get_fd_path`/`F_GETPATH`, which makes `fs.realpathSync` work
  on rootless iOS paths.
