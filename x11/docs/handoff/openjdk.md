# OpenJDK 21 for rootless iOS

Last updated: 2026-07-30

## Current state

OpenJDK 21.0.12 is built as a full headless HotSpot JDK for arm64 iOS 16+ and
is installed on the iPad7,12 / A10 test device. This is not the Zero
interpreter-only mobile build: the server VM includes C1, C2, tiered
compilation, JVMCI, JFR, G1, Parallel, Serial, Shenandoah, and ZGC.

The package split is:

- `openjdk-21-jre-headless 21.0.12+ios1`: `java`, runtime modules,
  configuration/legal files, native libraries, fonts/ImageIO, networking,
  crypto, management, JFR runtime, and `/var/jb/usr/bin` links.
- `openjdk-21-jdk-headless 21.0.12+ios1`: `javac`, JShell, javadoc, jar,
  jlink/jmod, diagnostics/debuggers, headers, jmods, man pages, and source zip.

Final local and installed package bytes:

| Package | Bytes | SHA-256 |
|---|---:|---|
| `openjdk-21-jre-headless_21.0.12+ios1_iphoneos-arm64.deb` | 54,290,592 | `4f8ec7930c35cd52567a7536f6fc8cce89e215a2853b8af70e6ba3e814c61894` |
| `openjdk-21-jdk-headless_21.0.12+ios1_iphoneos-arm64.deb` | 126,170,144 | `65cc88210b184f27291e700413c6be09e70cc7e08f697d0a3ad9087e5143c9f0` |

These packages have not been staged or published to the APT repo.

## Reproducible build

Run from the repository root:

```bash
bash x11/linux-build/build-openjdk-ios.sh
```

The build pins:

- OpenJDK `jdk21u` commit
  `9de4f68c88a0a1510373f291d1a95b1f6b0db8c8` (21.0.12).
- AngelAuraMC's iOS 17-21 patch source commit
  `4527b5a73dcf3f890b45eab4c6a91651ea28a5ea`.
- Both imported patch hashes and all downloaded auxiliary header archives.
- Source date `1783925755` and version string `21.0.12+7-xios1`.

The build script keeps macOS build tools separate from the iPhoneOS target
compiler, assembles the residual headless-AWT X11/fontconfig headers from our
iOS development packages, validates all 65 Mach-O files as arm64 platform 2
with a 16.0 minimum, and signs launchers plus `jspawnhelper` with the existing
narrow JIT entitlements. Dylibs remain ad-hoc signed.

OpenJDK source patches owned by this repo live in
`ports/openjdk21/patches/series`. Do not convert them into transient source
rewrites in the build driver.

## iOS HotSpot decisions

The upstream 1 GiB compressed-class-space reservation was unreliable under
iOS ASLR on this device. Before the fix, reservation-size experiments started
only 4-8 times out of 12; `-XX:-UseCompressedClassPointers` started 12/12.
The local iOS-only HotSpot patch therefore defaults
`UseCompressedClassPointers=false` while retaining compressed ordinary object
pointers and allowing an explicit opt-in.

The standard patched code-cache path and the optional
`-XX:+MirrorMappedCodeCache` path both execute generated ARM64 code. The
mirrored test logged distinct RW/RX mappings and completed the same C1/C2
workload. The mirror flag remains opt-in until it has broader device/version
coverage.

## Physical-device proof

All of the following passed on the iPad7,12 / A10:

- Both packages install cleanly with `dpkg`; `libiosexec1 1.3.1` satisfies the
  subprocess dependency and `dpkg -V` reports no modified packaged files.
- 30/30 ordinary `java -version` cold starts.
- `javac full version "21.0.12+7-xios1"` and `jshell 21.0.12`.
- The reusable `linux-build/tests/OpenJDKIOSSmoke.java` compiles on-device.
- `-XX:+PrintCompilation` shows its hot loop reaching tier 3 and tier 4 C2,
  then producing checksum `7b154fba9e45e25d`.
- The same workload passes in forced `-Xint` mode and with
  `-XX:+MirrorMappedCodeCache`.
- `ProcessBuilder` launches `/var/jb/usr/bin/sh` and receives the expected
  child output.
- Headless AWT/ImageIO creates a deterministic 106-byte PNG.
- Default TLS initializes and Java `HttpClient` receives HTTP 200 over HTTPS.
- JFR records a valid 2.1-format flight recording with execution,
  allocation, module, flag, and native-library events.
- `jlink` creates and runs a 44 MB `java.base`-only image on-device.
- `java.compiler`, `jdk.compiler`, `jdk.internal.vm.ci`, and `jdk.jfr` are
  present in the installed module graph.

The test did not restart or disturb the running KDE/Xios session.

## Remaining work

- Native AWT windows are not implemented. The current build is intentionally
  headless; a real XAWT or Wayland Java peer is its own porting milestone.
- OpenJDK still reports `os.name=Mac OS X` because the iOS target reuses the
  Darwin/macOS platform family. Changing this can alter third-party library
  selection and needs compatibility testing first.
- Run representative real applications and build systems (Gradle/Maven,
  servers, and large desktop-independent Java workloads) before publishing.
- Exercise the mirrored code cache across newer devices/iOS releases before
  considering it as the default.
- The full upstream jtreg suite was not run in this cross-build environment;
  the physical-device smoke matrix above is the current runtime gate.
