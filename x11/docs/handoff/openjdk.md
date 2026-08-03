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

### Known defect: accelerated VolatileImage renders black

`GraphicsConfiguration.createCompatibleVolatileImage(...)` returns an image that
fills **black** while reporting success (`contentsLost()==false`). A software
`createCompatibleImage` on the same config is correct, so this is specific to
the X pixmap-backed accelerated surface. Blitting the VolatileImage into a
software image also yields black, so the *fill* is wrong — not just readback.

Visible consequence: Metal L&F paints its button gradient through
`sun.swing.CachedPainter`, which uses a VolatileImage, so `JButton` faces render
as black blocks. Everything not routed through a VolatileImage is correct.

Reproduced identically with `-Dsun.java2d.xrender=false`,
`-Dsun.java2d.pmoffscreen=false`, and
`-Dswing.volatileImageBufferEnabled=false`.

**Workaround: switch Java2D to the OpenGL pipeline.**

    java -Dsun.java2d.opengl=true ...

The default X11/XRender pipeline gives `sun.java2d.xr.XRGraphicsConfig` and a
VolatileImage that fills `000000`. With the OpenGL pipeline the same probe
reports `OpenGL pipeline enabled for default config on screen 0`, gives
`sun.java2d.opengl.GLXGraphicsConfig`, and the VolatileImage fills correctly.
Metal L&F buttons then paint their real gradient instead of black blocks, and
the on-screen window contents paint correctly too (the Robot capture goes from
the unpainted `eeeeee` background to the app's own `1a202c`).

So the bug is confined to the X pixmap/XRender offscreen path, not Java2D
generally. The OpenGL route avoids it rather than fixing it.

**It is ours, not the X server's.** `linux-build/tests/xrender-pixmap-probe.c`
does what Java2D does, in plain Xlib/Xrender with no JVM: fills a pixmap via
core X11, via `XRenderFillRectangle` at depth 24 and ARGB32, and via the
1x1-repeating-solid `XRenderComposite` that `XRSurfaceData`/`XRCompositeManager`
actually issues. All four return the right colour. The same failure also
reproduces on a glamor-backed Xwayland, not just Xvfb, so it is not a
server-specific quirk either.

**The fill never reaches the pixmap; it is not a readback problem.**
`XRSurfaceData.getXid()` gives the pixmap's XID, and a *separate X client*
(`xrread`, same technique as the probe) reading that pixmap while the JVM still
holds it sees `000000` too. The server-side pixel data really is black.

**No primitive lands on an XRender surface.** `fillRect`, a 200x repeat of it,
`fillRect` with antialiasing, `fill(Shape)`, `drawImage`, `clearRect` and a
40px-wide `drawLine` all read back `000000`. Since even a blit fails, this is
not one broken operation — the whole XRender surface is a sink. That matches
the on-screen behaviour: with the XRender pipeline the Swing window stayed at
its unpainted `eeeeee` background, and only the OpenGL pipeline made it paint.

What is known about the Java side:

- The surface really is `sun.java2d.xr.XRSurfaceData$XRPixmapSurfaceData`,
  managed by `sun.java2d.xr.XRVolatileSurfaceManager` — the right plumbing.
- `-Dsun.java2d.xrender=True` reports `XRender pipeline enabled` and detects
  libXrender as 0.910, so the pipeline is not silently disabled.
- `-Dsun.java2d.trace=count` shows exactly one primitive for a fill-then-read
  cycle: the `Blit(IntRgb, SrcNoEa, IntRgb)` readback. XRender fills go through
  `XRBackendNative` rather than the loops, so that alone is not proof the fill
  is skipped, but nothing in the loop layer touches the surface.

So the pipeline believes it is enabled, builds the right surface objects, and
then emits rendering that has no effect on a pixmap the server is perfectly
willing to render into from another client.

Next, in increasing cost:

1. Check whether X protocol errors are being raised and swallowed. AWT installs
   its own X error handler; a stream of `BadPicture`/`BadMatch` on every render
   would explain "enabled but inert" exactly.
2. Interpose on `XRenderComposite`/`XRenderFillRectangle` with
   `DYLD_INSERT_LIBRARIES` and log the arguments the JVM passes — in particular
   whether the destination Picture is the one created for the pixmap.
3. Compare `XRBackendNative.c` and the `XRCompositeManager` flush path against a
   known-good Linux build; our build is the only variable left, and the
   `-UMACOSX`-on-XAWT-but-`-DMACOSX`-on-libawt split is the obvious suspect for
   a struct or calling-convention mismatch across the two libraries.

Caveat before making this the default: under Xvfb, GLX resolves to llvmpipe
software rendering, so this trades a correctness bug for CPU-side rasterisation.
It should be re-measured under Xwayland before being baked in. See
`../xwayland-plan.md` — client-side desktop GL is software today, and a gl4es
(MIT) GL→GLES-on-ANGLE shim built *with* its GLX layer is the path to making
this pipeline hardware-accelerated. Note that Amethyst's `libgl4es_114.dylib`
exports 1222 GL entry points but **zero** `glX*`, so it is not reusable as-is
for X11 clients.

## Remaining work

- Fix the black accelerated-VolatileImage path in the XRender pipeline, or
  decide to default the AWT variant to `sun.java2d.opengl=true`. Measure the
  OpenGL pipeline under Xwayland first: it is correct but software-rasterised
  until a GLX-capable gl4es lands, so defaulting it today may cost throughput.
- Get an X client's window actually *presented* in a live iosc session, so AWT
  output is visible on the panel and not only verifiable in captured pixels.
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
