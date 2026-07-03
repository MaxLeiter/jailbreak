# ladybird-app — standalone native UIKit browser for jailbroken iPad

A real home-screen `.app`: tap the icon, Ladybird launches standalone (no iosc / Wayland /
desktop stack) and renders the web with the from-scratch Ladybird engine. This is a NEW
UIKit frontend — upstream Ladybird has AppKit/Qt/GTK/Android frontends but no iOS one.

This package is **design + scaffold done in parallel with the engine build** (the engine
agent owns `linux-build/recipes-ladybird/` + `procursus-vol-ladybird`; this dir touches
none of that). The app cannot fully link until the engine's `WebContent`/`WebWorker`
helpers finish, so parts are marked **BLOCKED-ON-ENGINE**.

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

### Present path (mirrors AppKit's two paths)
Driven by `on_ready_to_paint`. WebContent hands the frontend a **double-buffered
shared-memory `Gfx::Bitmap`** (BGRA8-premultiplied, device-pixel sized), front/back
swapped on each `server_did_paint`.

- **Preferred (zero-copy):** the front `Gfx::SharedImageBuffer` is **IOSurface-backed**; we
  wrap it as an `MTLTexture` (`newTextureWithDescriptor:iosurface:`) and blit it into a
  `CAMetalLayer` drawable. Identical to AppKit's `presentMetalFrame`, and identical to how
  every other app in this repo presents (Xios). Needs the GPU IOKit entitlements.
- **Fallback (CPU):** `CGImageCreate` over the bitmap's pixels → `CALayer.contents`
  (`kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst`). Used when
  `MTLCreateSystemDefaultDevice()` returns nil. Note the project-memory CGContext-dangle
  gotcha does NOT bite here: we build a `CGImage` from an existing shared buffer (via a
  `CGDataProvider`), we never hand CoreGraphics a Swift-owned pointer.

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

Ladybird is **multiprocess-only** (no single-process build flag exists). The four helpers
must be bundled inside the `.app` and spawned. The good news, verified against the engine
source:

- iOS defines `AK_OS_IOS` (keyed off `-D__IOS__`), **not** `AK_OS_MACOS`. So iOS compiles
  the **`#else` IPC branch** in `Libraries/LibWebView/Process.cpp`: an `AF_UNIX`
  `socketpair` whose child end is handed over via the **`SOCKET_TAKEOVER`** env var, spawned
  with **`posix_spawn`** — both proven under this jailbreak (bun/opencode). No Mach bootstrap
  server, no `--mach-server-name` (it is gated on the macOS-only `mach_server_name()`).
- Helper path resolution (`Libraries/LibWebView/Utilities.cpp:101`): the **same-dir candidate
  `"<app_dir>/<HelperName>"` is always compiled** (line 111). We make `application_directory()`
  return the bundle root by passing `[NSBundle mainBundle].bundlePath` to `WebView::Application`
  as the "ladybird binary path". So `WebContent` etc. resolve to
  `/var/jb/Applications/Ladybird.app/WebContent`, where we ship them.
- Resources: the iOS default resource root (`find_prefix(app_dir)/share/Lagom`) points
  *outside* the bundle, so `IOSApplication::boot` **explicitly reinstalls**
  `Core::ResourceImplementationFile` at `<bundle>/share/Lagom`. No engine source patch needed.

**Bundle layout** (self-contained):
```
/var/jb/Applications/Ladybird.app/
  Ladybird        UI exe (statically links the engine)
  WebContent RequestServer ImageDecoder WebWorker   helpers (same-dir candidate finds them)
  share/Lagom/…   engine resources (resource root overridden here at boot)
  Info.plist  AppIcon.png
```

### Signing / entitlements
AMFI checks entitlements **per binary**, so the UI exe and each helper are signed
separately (Mac `ldid`, DER entitlements, via `xsign`):
- `entitlements/ladybird-app.entitlements` — `can-allow-non-platform` (load /var/jb
  fakesigned dylibs), `get-task-allow`, the GPU/IOSurface IOKit user clients (Metal present,
  same set as Xios.app), `/var/jb` + `/tmp` file exceptions.
- `entitlements/ladybird-helper.entitlements` — shared by the four helpers:
  `can-allow-non-platform`, `get-task-allow`, `/var/jb` + `/tmp` file exceptions. GPU clients
  are intentionally omitted (raster M0 paints on CPU inside WebContent); add them to
  WebContent only at M3 (Skia-on-Metal).

### Single-process fallback
There is **no** in-process mode in Ladybird, so there is no code fallback. If `posix_spawn`
of a helper were ever blocked under the JB, the fallback is operational, not architectural:
ship the helpers at FHS `/var/jb/libexec/ladybird/` and rely on the (also-compiled) libexec
candidate instead of same-dir — but spawning from `/var/jb` is already proven, so this is a
non-issue.

## Language choice: Objective-C++ (.mm), not Swift

The engine-facing layer is **ObjC++** for the same reason AppKit is: a `.mm` TU can
`#include` LibWebView's C++ headers and `#import <UIKit/UIKit.h>` together, call the C++ API
directly (templates, `ErrorOr`, `Function<>` callbacks, `Gfx::Bitmap`), and share the pure-C++
bridge unchanged. Swift↔C++ interop is too immature for LibWebView's heavily-templated API,
and the same clang-19 + 16.5-SDK cross toolchain that builds the engine builds `.mm` but not
a Swift toolchain targeting that SDK. A thin Swift chrome layer over the ObjC++ core is
possible later but buys nothing for M0.

## Build (mechanical, once the engine lands)

`build-ladybird-app.sh` is the driver. It is intentionally gated: it refuses to run until
`LADYBIRD_ENGINE_STAGE` (the engine agent's staged helpers + `share/Lagom`) and
`LADYBIRD_UI_BIN` (the cross-built UIKit `Ladybird` Mach-O) are set. Steps:
1. **[BLOCKED-ON-ENGINE]** cross-compile the frontend: copy `Sources/` + `CMakeLists.txt`
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

## What's blocked on the engine finishing
- Step-1 cross-compile / link (needs the built Lagom static libs + the 4 helper executables).
- Confirming a few engine symbol spellings used here (marked BLOCKED-ON-ENGINE in-source):
  `ViewImplementation` protected members (`m_client_state`, `m_backup_*`), `SharedImageBuffer::iosurface_handle()`, and the `Web::MouseEvent`/`KeyEvent`/`PinchEvent` aggregate field order. All are taken from the AppKit path, which is the 1:1 reference.
- The final `Depends` closure (harfbuzz/freetype/fontconfig/curl+openssl/sqlite3/xml/codecs).

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
