# Amethyst graphical Minecraft launcher

Last updated: 2026-07-31

## Goal and current state

This lane packages AngelAuraMC's Amethyst iOS launcher as the graphical
Minecraft Java Edition frontend for Xios. It is not an X11/AWT window: the
launcher is UIKit and the game uses Amethyst's patched LWJGL/GLFW input,
OpenAL audio, and native OpenGL translation stack. This avoids the
software-only desktop-GL limitation in the current Xwayland path.

The source is pinned at Amethyst commit
`64c5c9c44148d9cc7c7c4430940b8dcbe9331a44` (2026-07-11). A host build has
produced the launcher, account UI, custom controls, Java launcher jars,
LWJGL/GLFW, GL4ES/TinyGL4ANGLE, MobileGlues, OpenAL, MoltenVK, and OSMesa
components as 27 arm64 iOS Mach-O files after bundling liblzma.
Physical-device GUI proof is still required before this package may be
published.

## Rootless and rootful packages

One application source/build supports both jailbreak layouts:

| Target | Application path | Java 21 path | Package architecture |
|---|---|---|---|
| `rootless-1900` | `/var/jb/Applications/AngelAuraAmethyst.app` | `/var/jb/usr/lib/jvm/java-21-openjdk` | `iphoneos-arm64` |
| `rootful-1900` | `/Applications/AngelAuraAmethyst.app` | `/usr/lib/jvm/java-21-openjdk` | `iphoneos-arm` |

The launcher checks the rootless Java location, then the rootful location, then
an optional bundled runtime. The `.deb` has an exact dependency on the matching
scheme's `openjdk-21-jre-headless` revision. Amethyst's accidental
`/usr/lib/liblzma.5.dylib` dependency is rewritten to an app-bundled,
ad-hoc-signed `@rpath/liblzma.5.dylib`, so the same executable does not depend
on a rootful filesystem path.

## Reproducible build

Run from `x11/`:

```bash
XIOS_TARGET=rootless-1900 bash linux-build/build-amethyst-ios.sh
XIOS_TARGET=rootful-1900 bash linux-build/build-amethyst-ios.sh
```

The build driver checksum-pins the x86_64 Temurin 8 boot JDK required by
Amethyst's Java build, resets all recursive submodules to the pinned upstream
commit, applies `ports/amethyst-ios/patches/series`, builds a slim system-JRE
payload, signs it with Amethyst's narrow TrollStore/JIT/GPU entitlements,
audits every Mach-O, and emits both a `.deb` and `.tipa`.

OpenJDK itself is built once because its arm64 iOS image is scheme-neutral.
The existing image can be repackaged for rootful with:

```bash
XIOS_TARGET=rootful-1900 \
  bash linux-build/build-openjdk-ios.sh --package-only
```

The rootful target is a smoke profile. Do not publish its packages until a
rootful physical device has passed installation and runtime validation.

## Device gate

Use `bin/xios-device` and capture physical screenshots. A release candidate
must prove:

1. The `.deb` installs without unresolved dependencies and `uicache` registers
   `org.angelauramc.amethyst`.
2. The UIKit launcher reaches its visible main screen and remains stable.
3. It detects the package-managed Java 21 runtime for the active jailbreak
   scheme and can start a JVM with JIT entitlements.
4. Microsoft sign-in or upstream demo mode downloads only legitimately
   accessible game assets.
5. A supported Minecraft version reaches a title/menu frame with working
   touch controls, orientation, audio, and a rendered world smoke.

Do not call a host build, simulator launch, package install, or JVM-only test
Minecraft-running proof. The title/menu and world render require screenshots
from a physical device.
