# ladybird-app — standalone native UIKit browser for jailbroken iPad

A real home-screen `.app`: tap the icon, Ladybird launches standalone (no iosc / Wayland /
desktop stack) and renders the web with the from-scratch Ladybird engine. This is a UIKit
frontend; upstream Ladybird has AppKit/Qt/GTK/Android frontends but no iOS one.

The package is self-contained: the app bundle contains the UI executable, the five Ladybird
helper processes, resources, fonts, and the runtime dylib closure. The engine-side iOS app
patches live in `linux-build/recipes-ladybird/patches/` and are applied by the Ladybird recipe
wrapper.

## Architecture (ports the AppKit frontend method-for-method)

Two-object split, exactly like `UI/AppKit`:

| Piece | File | AppKit equivalent |
|---|---|---|
| `ViewImplementation` subclass (pure C++) | `Sources/IOSWebViewBridge.{h,cpp}` | `Interface/LadybirdWebViewBridge.{h,cpp}` |
| Host view (ObjC++) | `Sources/LadybirdWebView.{h,mm}` (`UIView`) | `Interface/LadybirdWebView.mm` (`NSView`) |
| Input converters | `Sources/Event.{h,mm}` | `Interface/Event.mm` |
| Chrome (address bar, back/fwd/reload, 1 tab) | `Sources/BrowserViewController.{h,mm}` | `Interface/TabController.mm` |
| `WebView::Application` + entry | `Sources/IOSApplication.{h,mm}` | `Application/Application.mm` + `main.mm` |

The bridge implements the **three mandatory `ViewImplementation` overrides** — `viewport_size()`
(device px), `to_content_position()`, `to_widget_position()` — plus `update_zoom()` /
`initialize_client()`, identical to the AppKit bridge. It is pure C++ so it is portable
verbatim.

### Present path
Driven by `on_ready_to_paint`. The release Compositor links real ANGLE/EGL/GLES
over Metal and paints into a double-buffered
`Gfx::SharedImageBuffer` (BGRA8-premultiplied, device-pixel sized), front/back swapped on
each `server_did_paint`.

- **Release path (zero-copy):** the front `Gfx::SharedImageBuffer` is **IOSurface-backed**; we
  carry its IOSurface as a Mach send right, wrap it as an `MTLTexture`
  (`newTextureWithDescriptor:iosurface:`), and blit it into a `CAMetalLayer` drawable.
  Identical to AppKit's `presentMetalFrame`, and identical to how every other app in this
  repo presents (Xios). Needs the GPU/IOSurface IOKit entitlements. Missing Metal,
  IOSurface, or texture creation is fatal in release builds instead of silently
  changing rendering architecture.
- **Diagnostic CPU mode:** only `LB_APP_CPU_DIAGNOSTIC=1` compiles the
  `CGImageCreate`/`CALayer.contents` path and generated ANGLE trap stubs. It is a
  bring-up aid, not a package or release configuration.

### Input
- **Touch:** `UITouch` → `Web::MouseEvent` (down/move/up); tap = primary click, one-finger
  drag = `MouseMove` with button held (content drag/selection).
- **Scroll:** two-finger `UIPanGestureRecognizer` → `Web::MouseEvent` type `MouseWheel`.
- **Long-press:** → secondary (right) click → LibWeb context-menu request.
- **Pinch:** `UIPinchGestureRecognizer` → `Web::PinchEvent`.
- **Keyboard:** hardware via `pressesBegan/Ended` (`UIKey`, HID-usage → `KeyCode`), software
  via `UIKeyInput` (`insertText:`/`deleteBackward`). The AppKit Carbon `kVK_*` switch is
  rewritten against `UIKeyboardHIDUsage*`.

All converters pass **logical points**; the bridge multiplies by DPR (`to_content_position`)
into device pixels, exactly like AppKit.

## Multiprocess-in-app-bundle (the critical part) — SOLVED by design

Ladybird is **multiprocess-only** (no single-process build flag exists). The five helpers
must be bundled inside the `.app` and spawned.

- App-mode iOS uses Ladybird's Mach bootstrap transport, with the iOS-specific task-port
  handoff removed. The helpers are still launched from the bundle with `posix_spawn`, but the
  live process arguments include `--mach-server-name org.ladybird.Ladybird.helper.<pid>`.
  This is required for real IOSurface Mach-port handoff between the Compositor and UI process.
- Helper path resolution (`Libraries/LibWebView/Utilities.cpp:101`): the **same-dir candidate
  `"<app_dir>/<HelperName>"` is always compiled** (line 111). We make `application_directory()`
  return the bundle root by passing `[NSBundle mainBundle].bundlePath` to `WebView::Application`
  as the "ladybird binary path". So `WebContent` etc. resolve to
  `<Ladybird.app>/WebContent`, where both package variants ship them.
- Resources: the iOS default resource root (`find_prefix(app_dir)/share/Lagom`) points
  *outside* the bundle, so `IOSApplication::boot` **explicitly reinstalls**
  `Core::ResourceImplementationFile` at `<bundle>/share/Lagom`. No engine source patch needed.

**Bundle layout** (self-contained). Rootless uses `/var/jb/Applications`; rootful uses
`/Applications`:
```
<application root>/Ladybird.app/
  Ladybird        UI exe (statically links the engine)
  WebContent RequestServer ImageDecoder WebWorker Compositor
  share/Lagom/…   engine resources (resource root overridden here at boot)
  Info.plist  AppIcon.png
```

### Signing / entitlements
AMFI checks entitlements **per binary**, so the UI exe and each helper are signed
separately (Mac `ldid`, DER entitlements, via `xsign`):
- `entitlements/ladybird-app.entitlements` — `can-allow-non-platform` (load jailbreak
  fakesigned dylibs), `get-task-allow`, the GPU/IOSurface IOKit user clients (Metal present,
  same set as Xios.app), and target-rendered filesystem exceptions.
- `entitlements/ladybird-helper.entitlements` — shared by the five helpers:
  `can-allow-non-platform`, `get-task-allow`, IOSurface user clients for the Compositor's
  shared front buffer, the internal GPU user clients for ANGLE/EGL/GLES probes, and
  target-rendered install-prefix + `/tmp` file exceptions.

### Single-process fallback
There is **no** in-process mode in Ladybird, so there is no code fallback. If `posix_spawn`
of a helper were ever blocked under the JB, the fallback is operational, not architectural:
ship the helpers at an FHS libexec path and rely on the (also-compiled) libexec candidate
instead of same-dir — but spawning the helpers from either application bundle is the supported
design.

## Language choice: Objective-C++ (.mm), not Swift

The engine-facing layer is **ObjC++** for the same reason AppKit is: a `.mm` TU can
`#include` LibWebView's C++ headers and `#import <UIKit/UIKit.h>` together, call the C++ API
directly (templates, `ErrorOr`, `Function<>` callbacks, `Gfx::Bitmap`), and share the pure-C++
bridge unchanged. Swift↔C++ interop is too immature for LibWebView's heavily-templated API,
and the same clang-19 + 16.5-SDK cross toolchain that builds the engine builds `.mm` but not
a Swift toolchain targeting that SDK. A thin Swift chrome layer over the ObjC++ core is
possible later but buys nothing for M0.

## Build

The current production path is:
1. `linux-build/build-ladybird-app-engine.sh` builds the patched engine/UI targets into
   `linux-build/out/app-stage`. The default and only release path links real ANGLE/EGL/GLES.
   `LB_APP_CPU_DIAGNOSTIC=1` explicitly selects the non-release CPU/trap-stub build.
2. `linux-build/build-ladybird-app-bundle.sh` assembles the self-contained `.app` deb inside
   the Linux container. This package is only preliminarily signed.
3. `packages/ladybird-app/package-ladybird-app-targets.sh <deb> <out-root>` runs on macOS and
   emits `iphoneos-arm64` rootless and `iphoneos-arm` rootful packages with the same package id
   and version. The host `xsign`/`ldid` pass emits DER entitlements; without that,
   `IOSurfaceCreate()` returns `NULL` on device even though `ldid -e` prints the XML keys.

The two payloads are one user-facing package, not two products:

| Target | App path | Architecture |
|---|---|---|
| `rootless-1900` | `/var/jb/Applications/Ladybird.app` | `iphoneos-arm64` |
| `rootful-1900` | `/Applications/Ladybird.app` | `iphoneos-arm` |

The app and helper Mach-Os are generic arm64 and shared between the variants. Packaging adds the
scheme-correct `libiosexec` rpath, renders the filesystem entitlements, moves the bundle to the
correct application root, and registers that exact path with `uicache`. Both variants require
iOS/iPadOS 16.0 or newer. Both profiles are publishable after their host package audits pass;
release notes must state when physical-device runtime validation is still pending.

`build-ladybird-app.sh` remains a lower-level packaging driver for prebuilt artifacts. It
expects `LADYBIRD_ENGINE_STAGE` (the staged helpers + `share/Lagom`) and `LADYBIRD_UI_BIN`
(the cross-built UIKit `Ladybird` Mach-O). Steps:
1. Cross-compile the frontend: copy `Sources/` + `CMakeLists.txt`
   into `<ladybird-src>/UI/iOS`, `add_subdirectory` it, build the `Ladybird` target with the
   engine's Docker cross toolchain (clang-19 / cctools ld64 / iPhoneOS16.5.sdk / `-D__IOS__`).
   On iOS the Lagom libs are static (`if (ANDROID OR IOS)` → `BUILD_SHARED_LIBS OFF`), so the
   engine links into the UI exe + helpers.
2. Assemble `Ladybird.app` (layout above).
3. `xsign` the UI exe + each helper with the entitlements above.
4. `xmkdeb` → `ladybird-app_<ver>_iphoneos-arm64.deb`; `postinst` runs `uicache` so the icon
   appears. `Depends` on the engine leaf dylibs (ICU 78.3 confirmed; the rest finalized
   against the engine agent's deb names).

**User flow:** install one deb in Sileo → Ladybird icon on the home screen → tap → browse.

## Still deferred
- Public-release polish for the GPU path. The default build links real ANGLE EGL/GLES, removes
  the CPU `--force-cpu-painting` flag, and has on-device WebGL smoke evidence under
  `artifacts/device-runs/ladybird-webgl-screenshot-20260706-125805/`. The remaining work is
  broader page coverage, not first-light GPU enablement.
- Non-jailbroken/App Store builds. The current app relies on jailbreak fakesigning, helper
  spawning, `libiosexec`, and private IOKit entitlements.

## UI/ frontend inventory + toolkit versions (for the later desktop-flavor pick)
- **AppKit** — macOS Cocoa + Metal (the port reference; unusable as-is on UIKit).
- **Qt** — `find_package(Qt6 COMPONENTS Core Widgets)`, **no hard minimum**; the only version
  gate is `Qt 6.7.0` for the Linux Vulkan/DMABUF zero-copy path (irrelevant on our stack).
  vcpkg pins 6.10.0, but **our qtbase 6.6.3 would build the Qt UI** (dropping only that
  Linux-only path).
- **GTK** — `gtk4` (unversioned) + `libadwaita-1 >= 1.4`. **Our GTK4 4.14.5 + libadwaita 1.8.4
  exceed both** (the plan's 4.22/1.8.4 is higher than the source requires).
- **Android** — Gradle/NDK, N/A.

Takeaway for a desktop/Wayland flavor: both Qt (6.6.3) and GTK (4.14.5) are already
version-satisfied; the UIKit app here is the standalone-browser path and does not depend on
that choice.
