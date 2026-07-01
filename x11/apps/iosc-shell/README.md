# iosc-shell — our own desktop shell for the iosc compositor

The panel / launcher / overview that makes `iosc` feel like a desktop, built as
**layer-shell clients** of the compositor (not chrome baked into `iosc.c`). Design
and the iosc-side protocol hand-off: **`../../docs/iosc-shell.md`**.

This complements `../iosc-desktop/` (which turns Linux apps into iOS Home Screen
icons); this is the chrome *inside* the Xios display.

## What's here

| File | Role |
|---|---|
| `shell-draw.h` | shared wl_shm software renderer (5x7 bitmap font, `shell_canvas`, draw primitives, `.desktop` scan, launch). Header-only, `static`; both clients compile their own copy (separate executables → no link conflict). One renderer, no divergent copies. |
| `ioscpanel.c` | the panel: a `zwlr_layer_shell_v1` client anchored top — launcher tiles + taskbar + clock. |
| `ioscoverview.c` | the app overview: a full-screen `OVERLAY` layer surface — grid of installed apps + open windows; tap to launch/raise, Escape or background tap to dismiss. |
| `protocols/` | vendored protocol XML: `wlr-layer-shell`, `wlr-foreign-toplevel-management`, `xdg-shell` (authoritative copies from wlr-protocols / wayland-protocols). |
| `build-panel.sh` | cross-compile + link + sign **both** clients for rootless iOS arm64 (Docker, mirrors `wayland/build-iosc.sh`). |
| `compile-check.sh` | source/codegen validation only (compiles both clients to objects against the iOS SDK; no link). Run in `procursus-xbuild`. |
| `panel-ent.xml` | ad-hoc entitlements (a wl_shm client: no GPU/IOSurface entitlements needed). |

## Build

```sh
# full build of both clients (needs the W0 wayland sysroot; auto-located from the
# repo's libwayland-dev_*.deb, or pass SYSROOT=/path/to/extracted):
./build-panel.sh                 # -> out/ioscpanel, out/ioscoverview (ldid-signed)

# source/codegen check only (no W0 sysroot needed):
docker run --rm --entrypoint /bin/bash -v "$PWD":/work \
    procursus-xbuild:bookworm-arm64 /work/compile-check.sh
```

**Validated:** both clients + the generated protocol code cross-compile clean to
iOS arm64 via the cctools `aarch64-apple-darwin-clang` + iPhoneOS SDK in
`procursus-xbuild:bookworm-arm64`. The link resolves `wl_*`/`zwlr_*` against the
W0 `libwayland-client.dylib` (`wayland-w0-ios-build`).

## Run (on-device)

```sh
scp out/iosc{panel,overview} root@ipad:/var/jb/usr/local/bin/
# start iosc + show Xios first (see wayland/run-iosc.sh), then:
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/var/jb/tmp ioscpanel     # the top bar
WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/var/jb/tmp ioscoverview  # the app grid
```

## Blocking dependency

Both clients **build today** but **cannot map until iosc implements
`zwlr_layer_shell_v1`** (and the taskbar / open-windows row stay empty until
`zwlr_foreign_toplevel_management_v1`). Both are specified, struct-level, in
`../../docs/iosc-shell.md` §5 — additive, isolated changes to `iosc.c`. Each client
exits with `compositor lacks zwlr_layer_shell_v1` on a compositor without it.

The richer GTK4 path for the overview (gtk4-layer-shell) is also built —
`../../linux-build/out/gtk4-layer-shell_1.3.0_iphoneos-arm64.deb` — and becomes
usable once iosc has layer-shell; see `../../docs/iosc-shell.md` §4.
