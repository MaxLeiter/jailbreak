# Handoff: OpenJDK 21

Last checked against `repo/Packages`: 2026-10-25.

## Current state

OpenJDK 21.0.12 is a full headless HotSpot JDK for arm64 iOS 16+, not the
interpreter-only Zero build: C1, C2, tiered compilation, JVMCI, JFR, and the
G1, Parallel, Serial, Shenandoah and ZGC collectors.

Published (rootless):

- `openjdk-21-jre-headless 21.0.12+ios1`: `java`, runtime modules, native
  libraries, fonts/ImageIO, networking, crypto, management, JFR, and the
  `/var/jb/usr/bin` links.
- `openjdk-21-jdk-headless 21.0.12+ios1`: `javac`, JShell, javadoc, jar,
  jlink/jmod, diagnostics, headers, jmods, man pages and the source zip.

Built but **not published**:

- (Retired 2026-10-25: a `+rootful1` repackage of the same image under `/usr`
  (`iphoneos-arm`) was built and never ran on a device; the rootful target is gone.)
- `openjdk-21-{jre,jdk}-awt 21.0.12+ios2`, an opt-in headful XAWT image (below).

Open:

- Build and device-test the AWT `+ios2` packages. The AWT build that was
  installed on the iPad predates patch `0006` and still renders black.
- Show an AWT window in a live iosc session. X windows now map through iosc's
  rootless XWM (iosc 0.9.51), so this should be reachable, but nobody has tried
  it with AWT yet.
- X client GL is software everywhere (softpipe under Xvfb and glamor
  Xwayland), so the OpenGL Java2D pipeline rasterizes on the CPU. Hardware GL
  for X clients would need a GLX-capable gl4es on ANGLE, and ANGLE has no
  `EGL_EXT_platform_x11` (see `../hwgl-plan.md`). XRender through glamor is the
  accelerated path that exists today.
- `os.name` still reports `Mac OS X` because the iOS target reuses the Darwin
  platform family. Changing it can change which native libraries third-party
  code picks, so it needs testing first.
- Wider coverage: Gradle/Maven, servers, large real workloads, jtreg (never
  run in this cross environment), and the mirrored code cache on newer devices.

## iOS HotSpot decisions

- **Compressed class pointers are off by default on iOS.** The upstream 1 GiB
  compressed-class-space reservation is unreliable under iOS ASLR: before the
  fix, only 4-8 of 12 starts succeeded, versus 12/12 with
  `-XX:-UseCompressedClassPointers`. Patch `0001` defaults it off while keeping
  compressed oops and allowing an explicit opt-in.
- Both the standard code cache and the opt-in `-XX:+MirrorMappedCodeCache`
  (distinct RW/RX mappings) execute generated ARM64 code. The mirror stays
  opt-in until it has wider device and OS coverage.

## Device proof (iPad7,12 / A10)

Both headless packages installed from the production repo with matching
hashes, then: 30/30 cold `java -version` starts; `javac` and `jshell`;
`linux-build/tests/OpenJDKIOSSmoke.java` compiled on device and reached tier 4
C2 (checksum `7b154fba9e45e25d`), and passed again under `-Xint` and with the
mirrored code cache; `ProcessBuilder` ran `/var/jb/usr/bin/sh`; headless
ImageIO wrote a PNG; `HttpClient` got HTTP 200 over TLS; JFR wrote a valid
recording; `jlink` built and ran a 44 MB `java.base` image.

## AWT/X11 variant

`OPENJDK_VARIANT=awt-x11` builds a headful image in its own work tree and
packages it as `openjdk-21-{jre,jdk}-awt`, installed to
`/var/jb/usr/lib/jvm/java-21-openjdk-awt`. It claims no `/usr/bin` names, so
the headless runtime is untouched; select it with `JAVA_HOME`.

    OPENJDK_VARIANT=awt-x11 bash x11/linux-build/build-openjdk-ios.sh --awt-x11-build-only
    OPENJDK_VARIANT=awt-x11 bash x11/linux-build/build-openjdk-ios.sh --package-only

`OPENJDK_PKG_VERSION` lets the variant take its own revision without touching
the headless suffix.

Fixes beyond turning on the XAWT peer:

- **rpath.** Procursus X11 dylibs have `@rpath` install names and OpenJDK only
  adds `@loader_path/.`, so the awt-x11 ldflags add `$XIOS_PREFIX/usr/lib`.
  Without it `libawt_xawt` can't find `libX11`.
- **fontconfig** (patch `0005`). `X11FontManager` uses `FcFontConfiguration`
  only when `FontUtilities.isLinux`; our macOS-family target fell through to
  `MFontConfiguration`, which wants a `fontconfig.properties` JDK 21 no longer
  generates ("Fontconfig head is null").
- **XRender rendered black** (patch `0006`), below.

On device the variant ran with `headless=false` and `sun.awt.X11.XToolkit`
against both Xwayland under iosc and Xvfb, compiled Java with its own `javac`,
and Swing components painted through Java2D (checked with `java.awt.Robot` and
ImageIO).

### Root cause: XRender surfaces rendered black

Every XRender-backed surface came out black while reporting success, but
software images were fine and `-Dsun.java2d.opengl=true` avoided it, which made
it look like an acceleration bug. It was a struct-layout ABI split across the
libawt/libawt_xawt boundary. `RECT_T` in
`unix/native/common/awt/utility/rect.h` was `XRectangle` (four shorts) without
`MACOSX` and `{int x,y,width,height}` with it. libawt is compiled `-DMACOSX`
(iOS is in the macOS family) and libawt_xawt `-UMACOSX`, and xawt hands
`XRectangle[]` buffers to libawt's `RegionToYXBandedRectangles`. libawt wrote
16-byte records into an 8-byte array, so every clip reached
`XRenderSetPictureClipRectangles` as `[0,0 0x0]`. A zero-area clip discards all
drawing with no protocol error. Patch `0006` gives the `MACOSX` branch
`XRectangle`'s field widths. Using `XRectangle` directly drags `<X11/Xlib.h>`
into every libawt unit that includes `Region.h` and broke the window-surface
path.

How it was isolated, if a silent-rendering bug like this shows up again:
`linux-build/tests/xrender-pixmap-probe.c` reproduced Java2D's operations in
plain Xlib/Xrender and was correct (rules out the server and libXrender);
reading the JVM's pixmap from a separate X client was also black (rules out
readback); a `DYLD_INSERT_LIBRARIES` interposer showed the right colour going
to the right Picture with no effect, and a Picture we made over the same
drawable worked (the Picture was the dud); interposing
`XRenderSetPictureClipRectangles` showed the zero clip.

## Build

From the repository root:

```bash
bash x11/linux-build/build-openjdk-ios.sh
bash x11/linux-build/build-openjdk-ios.sh --package-only
```

Pins: OpenJDK `jdk21u` commit `9de4f68c88a0a1510373f291d1a95b1f6b0db8c8`
(21.0.12), AngelAuraMC's iOS patch source commit
`4527b5a73dcf3f890b45eab4c6a91651ea28a5ea`, the imported patch hashes and
auxiliary header archives, source date `1783925755`, version string
`21.0.12+7-xios1`. The script keeps macOS build tools separate from the
iPhoneOS compiler, checks all 65 Mach-O files are arm64 platform 2 with a 16.0
minimum, and signs the launchers and `jspawnhelper` with the narrow JIT
entitlements (dylibs stay ad-hoc).

Our OpenJDK source patches live in `ports/openjdk21/patches/series`. Don't
turn them into ad-hoc source rewrites in the build driver.

## History

Headless packages were published 2026-07-30 after a scoped staging run and an
isolated-apt-cache install on the device. The AWT variant and the RECT_T fix
landed 2026-08-02 (PR #2).
