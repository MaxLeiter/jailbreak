# QtWayland ANGLE/IOSurface Bring-Up

This is the accelerated Qt path for Plasma on iosc:

`QtQuick/QRhi OpenGL -> QtWayland wayland-egl -> /var/jb/lib/angle/libEGL.dylib -> iosc EGL shim -> ANGLE Metal -> IOSurface wl_buffer -> iosc GPU compositor`.

## Current Implementation

- `qtbase` round 3 enables `INPUT_opengl=es2` and `FEATURE_egl=ON`, with EGL/GLES resolved from the staged ANGLE package under `/var/jb/lib/angle`.
- `qtwayland` now keeps its stock `wayland-egl` client buffer integration. The ANGLE package installs the iosc EGL shim as `libEGL.dylib`, so Qt's normal Wayland EGL calls are intercepted and translated to ANGLE Metal plus IOSurface buffers.
- `qt6-base` and `qt6-wayland` depend on `angle`; both recipes add `/var/jb/lib/angle` as an LC_RPATH where needed.
- GPU entitlements still belong on the executable that creates the ANGLE Metal display, not on Qt library packages. QtGui executables also need `platform-application` on this Darwin/iOS build because they link UIKit; without it ANGLE returns `EGL_NO_DISPLAY` even though non-UIKit EGL clients work. For smoke tests that means `qt-wayland-gl-smoke`/`qml`; for Plasma that means `kwin_wayland`, `plasmashell`, and any GL-initializing helper process.

## Load-Bearing EGL Contract

The shim must continue to match the path already validated for GTK4/GSK:

1. Client `EGL_PLATFORM_WAYLAND` display requests are accepted by injected client extension strings.
2. The real display is created with `eglGetPlatformDisplayEXT`, `EGL_PLATFORM_ANGLE_ANGLE`, `EGL_DEFAULT_DISPLAY`, and `EGLint` attributes selecting `EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`.
3. Window configs requested as `EGL_WINDOW_BIT`/ES3 are mapped to ANGLE pbuffer configs and reported back as window-capable.
4. `eglCreate*WindowSurface` allocates an IOSurface swapchain and exposes it as pbuffers via `EGL_ANGLE_iosurface_client_buffer`.
5. `eglSwapBuffers` fences with EGL sync, attaches the released IOSurface-backed `wl_buffer`, commits the `wl_surface`, and rotates to the next released buffer.

## Validation

Run these on device after rebuilding `angle`, `qt6-base`, `qt6-wayland`, and `qt6-declarative` against the round-3 base:

```sh
export DYLD_LIBRARY_PATH=/var/jb/usr/lib:/var/jb/lib/angle
export WAYLAND_DISPLAY=/var/jb/tmp/wayland-0
export QT_QPA_PLATFORM=wayland
export QT_LOGGING_RULES='qt.qpa.wayland=true;qt.scenegraph.general=true'
export IOSC_EGL_DEBUG=1

qml -platform wayland /var/jb/tmp/Hello.qml
```

Expected evidence:

- stderr includes `iosc_egl: shim loaded`, `GetPlatformDisplay(WAYLAND)`, and `window surface`.
- `qt.scenegraph.general` reports an OpenGL/ES renderer, not the software scenegraph.
- `iosc.log` reports imported IOSurface buffers for the Qt window.
- Moving or animating the Qt window does not produce wl_shm upload churn.

Fallback check:

```sh
QT_QUICK_BACKEND=software qml -platform wayland /var/jb/tmp/Hello.qml
```

That should still paint through wl_shm, preserving the software bring-up path.

## Private QtWayland Plugin Fallback

Only build a custom `wayland-graphics-integration-client/iosurface` plugin if stock `wayland-egl` rejects the shim during validation. The plugin should not invent new graphics plumbing; it should move the existing `iosc_egl_shim.c` swapchain logic behind QtWayland's private graphics-integration ABI:

- create the ANGLE Metal display with the exact EXT/EGLint path above;
- create IOSurface pbuffers with `EGL_ANGLE_iosurface_client_buffer`;
- bind `iosc_iosurface` on the client's Wayland display;
- attach/release triple-buffered IOSurface `wl_buffer`s on swap;
- expose the plugin as `QT_WAYLAND_CLIENT_BUFFER_INTEGRATION=iosurface`.

That fallback is private-ABI sensitive, so keep it tied to the pinned Qt 6.6.3 source tree.
