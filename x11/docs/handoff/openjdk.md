# OpenJDK 21 for rootless and rootful iOS

Last updated: 2026-07-31

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

The same target-neutral arm64 JDK image now also has a rootful package profile:

- `openjdk-21-jre-headless 21.0.12+rootful1` installs the runtime and command
  links under `/usr`, with package architecture `iphoneos-arm`.
- `openjdk-21-jdk-headless 21.0.12+rootful1` installs the matching development
  tools and depends exactly on the rootful JRE revision.

The rootful packages pass host payload/control/signature inspection but have
not run on rootful hardware. They are not published and must not be described
as device-proven.

Final local and installed package bytes:

| Package | Bytes | SHA-256 |
|---|---:|---|
| `openjdk-21-jre-headless_21.0.12+ios1_iphoneos-arm64.deb` | 54,290,592 | `4f8ec7930c35cd52567a7536f6fc8cce89e215a2853b8af70e6ba3e814c61894` |
| `openjdk-21-jdk-headless_21.0.12+ios1_iphoneos-arm64.deb` | 126,170,144 | `65cc88210b184f27291e700413c6be09e70cc7e08f697d0a3ad9087e5143c9f0` |

Both packages are published in the signed production APT repo at
`https://repo.maxleiter.com` and are represented by manifest commit
`538d0f5c`.

## Release proof

- Scoped staging publication passed the 621-package dependency, payload/hash,
  Procursus-shadow, signing, and version-drift gates.
- The device reinstalled both packages from `https://dev.repo.maxleiter.com`
  and then passed the full runtime matrix below. Evidence is in
  `artifacts/device-runs/2026-07-30-openjdk21-staging/`.
- Scoped production deployment `dpl_7wP4vbFjpjofGm4h3sTAdgMHBSZD` published
  only the two OpenJDK packages. The live `Packages` file is byte-for-byte
  identical to manifest commit `538d0f5c`.
- A fresh isolated APT cache on the device selected both production versions
  at priority 1002, downloaded all 180 MB from the production package URLs,
  and reproduced both SHA-256 hashes above. The installed runtime then
  reported `21.0.12+7-xios1` and `javac 21.0.12`.

## Reproducible build

Run from the repository root:

```bash
bash x11/linux-build/build-openjdk-ios.sh
```

The source build uses the rootless development sysroot. Repackage the same
arm64 iOS image for rootful after that build completes:

```bash
XIOS_TARGET=rootful-1900 \
  bash x11/linux-build/build-openjdk-ios.sh --package-only
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

The test did not restart or disturb the running Xios session.

## AWT/X11 variant (opt-in, alongside headless)

`OPENJDK_VARIANT=awt-x11` builds a second, headful image
(`--enable-headless-only=no`) in its own work tree and ships it as
`openjdk-21-{jre,jdk}-awt`. It installs to
`/var/jb/usr/lib/jvm/java-21-openjdk-awt` and deliberately claims **no**
`/usr/bin` names, so the proven headless runtime is untouched — select it with
`JAVA_HOME`. Verified on device: installing the AWT packages left the headless
package versions and every `/usr/bin` symlink identical.

    OPENJDK_VARIANT=awt-x11 bash x11/linux-build/build-openjdk-ios.sh --awt-x11-build-only
    OPENJDK_VARIANT=awt-x11 bash x11/linux-build/build-openjdk-ios.sh --package-only

Two fixes were needed beyond selecting the XAWT peer:

- **rpath.** The Procursus X11 dylibs carry `@rpath` install names, and OpenJDK
  gives its libraries only `LC_RPATH @loader_path/.` — the JDK's own `lib`. The
  `awt-x11` ldflags now add `$XIOS_PREFIX/usr/lib`, matching every other
  Procursus consumer. Without it `libawt_xawt` cannot resolve `libX11`.
- **fontconfig** (patch `0005`). `X11FontManager` only consults
  `FcFontConfiguration` when `FontUtilities.isLinux`; our macOS-family target
  fell through to `MFontConfiguration`, which wants a `fontconfig.properties`
  JDK 21 no longer generates, so the first text operation threw
  "Fontconfig head is null".

### Device evidence (iPad7,12 / A10)

- `headless=false`, `toolkit=sun.awt.X11.XToolkit`, screen geometry read over
  the X protocol, `Frame` displayable and showing at its requested size.
- Ran against both Xwayland (attached to a live `iosc` compositor) and Xvfb.
- The variant compiles Java on-device with its own `javac`.
- Swing renders: `JButton`/`JCheckBox`/`JTextField`/`JProgressBar` paint through
  Java2D, `java.awt.Robot` captures, and `ImageIO` encodes the result to PNG.

### Fixed: accelerated XRender surfaces rendered black

Symptom: every XRender-backed surface rendered black. `VolatileImage` fills
returned `000000` while reporting success (`contentsLost()==false`), Metal L&F
painted `JButton` faces as black blocks, and on-screen windows stayed at their
unpainted background. Software `createCompatibleImage` was always correct, and
`-Dsun.java2d.opengl=true` avoided it entirely, which is what made it look like
an acceleration problem.

Root cause: a struct-layout ABI split across the libawt/libawt_xawt boundary,
introduced by the XAWT-as-unix patch. `RECT_T` in
`unix/native/common/awt/utility/rect.h` was `XRectangle` (four shorts, 8 bytes)
when `MACOSX` was undefined and `{int x,y,width,height}` (16 bytes) when it was
defined. `Region.c` and `rect.c` live in libawt, compiled `-DMACOSX` because iOS
is in the macOS platform family; `XRBackendNative.c` and `X11SurfaceData.c` live
in libawt_xawt, compiled `-UMACOSX`, and hand `XRectangle[]` buffers to
`RegionToYXBandedRectangles` in libawt. libawt wrote 16-byte records into an
8-byte array, so the first rectangle's int `x` filled `XRectangle.x` and `.y`
and its int `y` filled `.width` and `.height`.

Every clip therefore reached `XRenderSetPictureClipRectangles` as `[0,0 0x0]`.
A zero-area clip discards all rendering silently, with no X protocol error --
which is why nothing rendered, no diagnostic appeared, and any client using that
Picture (not just the JVM) was equally affected.

Fixed by patch `0006`, which gives the `MACOSX` branch `XRectangle`'s field
widths. Selecting `XRectangle` itself instead would drag `<X11/Xlib.h>` into
every libawt translation unit that includes `Region.h`; that was tried first and
regressed the window-surface path with `native ops missing` on the toolkit
thread.

How it was isolated, in case a similar silent-rendering bug shows up again:

- `linux-build/tests/xrender-pixmap-probe.c` reproduced Java2D's operations in
  plain Xlib/Xrender with no JVM: core fill, `XRenderFillRectangle` at depth 24
  and ARGB32, and the 1x1-repeating-solid composite. All correct, ruling out the
  X server and libXrender.
- Reading the JVM's own pixmap by XID from a *separate* X client also showed
  black, ruling out Java's readback path.
- Every primitive failed, including `drawImage`, ruling out any single operation.
- A `DYLD_INSERT_LIBRARIES` interposer on `XRenderFillRectangle` showed the JVM
  issuing the right colour to the right Picture with no effect; wrapping
  `XSetErrorHandler` showed no protocol errors.
- Filling the JVM's Picture from the interposer *also* did nothing, while a
  Picture we created over the same drawable worked -- proving the Picture, not
  the drawable, was the dud.
- Interposing `XRenderSetPictureClipRectangles` showed `[0,0 0x0]`, while the
  Java-side `Region` was `[[0, 0 => 120, 40]]`.

Verified after the fix on the default XRender pipeline: `fillRect`, a 200x
repeat, antialiased fill, `fill(Shape)`, `drawImage`, `clearRect` and a wide
`drawLine` all return the right colour; Swing paints its real Metal gradients;
and the on-screen window contents paint (`robot_px` matches the app background).
`-Dsun.java2d.opengl=true` is no longer needed as a workaround.


## Remaining work

- Rebuild and republish `openjdk-21-{jre,jdk}-awt`: the installed device
  packages predate patch `0006`, so they still render black.
- Get an X client's window actually *presented* in a live iosc session, so AWT
  output is visible on the panel and not only verifiable in captured pixels.
- Client-side GL is software everywhere (`softpipe` under both Xvfb and a
  glamor-backed Xwayland), so the OpenGL Java2D pipeline rasterises on CPU.
  Hardware acceleration for X clients needs a GLX-capable gl4es (MIT) built
  against ANGLE — note `docs/hwgl-plan.md` Phase C: ANGLE exposes no
  `EGL_EXT_platform_x11` and needs a `CAMetalLayer`, so this is not a
  drop-in. XRender via glamor is the accelerated path that already exists.
- OpenJDK still reports `os.name=Mac OS X` because the iOS target reuses the
  Darwin/macOS platform family. Changing this can alter third-party library
  selection and needs compatibility testing first.
- Run representative real applications and build systems (Gradle/Maven,
  servers, and large desktop-independent Java workloads) to extend coverage
  beyond the release smoke matrix.
- Exercise the mirrored code cache across newer devices/iOS releases before
  considering it as the default.
- The full upstream jtreg suite was not run in this cross-build environment;
  the physical-device smoke matrix above is the current runtime gate.
