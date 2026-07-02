# Rootless Xwayland XWM for iosc (`iosc_xwm`) — plan + resume-here

Goal: make **rootless** Xwayland work under the iosc Wayland compositor, so each
X11 window becomes an **individual iosc surface** (toplevel or popup), instead of
today's rootful path where the whole X screen is one `xdg_toplevel` with an in-X
window manager (fluxbox/twm) inside it (see `run-xwayland.sh`, `docs/xwayland-
plan.md`).

Rootless requires the compositor to be an **X window manager (XWM)**. iosc had
none. This adds a self-contained XWM module that iosc.c calls into.

## Status (this deliverable)

- `wayland/iosc_xwm.h` — public API + the glue contract iosc.c must satisfy.
- `wayland/iosc_xwm.c` — the XWM. Cross-compiles clean (0 warnings) for
  iphoneos-arm64; link resolves against libwayland-server + the generated
  xwayland-shell-v1 protocol (xcb_* left to the device build's `-lxcb`).
- `wayland/protocols/xwayland-shell-v1.xml` — vendored staging protocol (the
  association mechanism). Build must `wayland-scanner` it.
- **iosc.c and the build scripts are NOT touched** (frozen + concurrent edits).
  All the integration is captured as a checklist below.

Clean-room: designed only from the xwayland-shell-v1 XML, ICCCM, EWMH, and the
libxcb core API. No wlroots/Weston/Mutter/Sway xwm code was read.

## Architecture

```
X11 client ─X protocol─▶ Xwayland (-rootless, -wm <fd>) ─┬─ wl_surface (one per X window)
                                                          └─ xwayland_shell_v1 assoc
   iosc_xwm.c  ◀── wm xcb socket ── Xwayland                     │ commit
       │  (spawn, WM_S0, redirect, events, focus/close bridge)    ▼
       └── glue ──▶ iosc.c: give the wl_surface a toplevel/popup role, map it
```

- **Spawn**: `posix_spawn` of `/var/jb/usr/bin/Xwayland -rootless -wm <fd>
  -displayfd <fd> -terminate`. `-wm` fd is one end of a `socketpair`; the XWM
  drives the other end with `xcb_connect_to_fd`. `-displayfd` reports the chosen
  X display number, which the module `setenv`s as `DISPLAY` for later X clients.
  `WAYLAND_DISPLAY` is exported so Xwayland finds iosc (default `wayland-0`).
- **Become the WM**: intern atoms; select
  `SubstructureRedirect|SubstructureNotify|PropertyChange` on the root (checked —
  BadAccess means another WM already owns it); create a 1×1 window; own `WM_S0`
  (ICCCM manager selection); publish `_NET_SUPPORTED`,
  `_NET_SUPPORTING_WM_CHECK`, `_NET_WM_NAME=iosc-xwm`.
- **Association (race-free, modern path)**: the module advertises
  `xwayland_shell_v1` as a wl_global, **bindable only by the Xwayland client**
  (pid recorded at spawn; other clients get an implementation error). Xwayland
  calls `get_xwayland_surface(wl_surface)` then `set_serial(lo,hi)` (double-
  buffered), and puts the same 64-bit serial on the X window via the
  `WL_SURFACE_SERIAL` client message. The module matches the two timelines:
  - `set_serial` is applied on `wl_surface.commit` (via the `iosc_xwm_surface_
    commit` hook iosc.c calls), recording `surface→serial`.
  - the `WL_SURFACE_SERIAL` ClientMessage records `xwindow→serial`.
  - when a window has both a serial-matched wl_surface and a MapRequest (or is
    override-redirect), it is **adopted** — handed to iosc.c via
    `iosc_xwm_adopt_surface`. Both arrival orders are handled.
- **Window lifecycle**: MapRequest (WM maps the frame, reads WM_PROTOCOLS /
  WM_CLASS / geometry / window-type, tries adopt), ConfigureRequest (honored;
  forwarded to iosc for popups), UnmapNotify (unadopt, WM_STATE=Withdrawn,
  reset serial so a re-map re-associates), DestroyNotify (free), PropertyNotify
  (`_NET_WM_NAME`/`WM_NAME` retitles the iosc surface).
- **override-redirect** X windows (menus, tooltips, DND, combo/dropdown by
  `_NET_WM_WINDOW_TYPE`) are adopted as **POPUP-band, unmanaged**, positioned at
  their X (x,y).
- **Focus/close bridge**: `iosc_xwm_notify_focus` mirrors iosc keyboard focus to
  X (`WM_TAKE_FOCUS` if advertised, else `SetInputFocus`, plus
  `_NET_ACTIVE_WINDOW`). `iosc_xwm_request_close` sends `WM_DELETE_WINDOW` (else
  `XKillClient`).

## Deferred / TODO(polish) (marked in `iosc_xwm.c`)

- `WM_NORMAL_HINTS` min/max/aspect sizing (needs `xcb_icccm` or manual parse).
- `_NET_WM_STATE` (maximize/fullscreen), `WM_CHANGE_STATE` (iconify),
  `_NET_WM_MOVERESIZE` (interactive move/resize initiated from the client).
- X11 clipboard/primary-selection bridge (separate CLIPBOARD/PRIMARY owner windows
  + `wl_data_device`/`zwlr_data_control` — coordinate with `clipboard-plan.md`).
- X cursor theme (iosc draws cursor-shape-v1; X apps set X cursors we ignore).
- `_NET_CLIENT_LIST` upkeep (advertised in `_NET_SUPPORTED` but not maintained).
- Registry-hiding of the shell global from non-Xwayland clients (bind is already
  hard-refused by pid; a `wl_display_set_global_filter` is display-wide so it must
  be owned by iosc.c — see integration note 6).

## iosc.c integration checklist (the frozen edits)

All of these are additive; none change existing behavior when `IOSC_XWAYLAND` is
unset.

1. **`#include "iosc_xwm.h"`** near the other module includes.

2. **Implement the 5 glue functions** (the `(B)` contract). Suggested placement:
   just after `surface_unmap`/`keyboard_set_focus` are defined so they can call
   them. New surface flag needed: add `int is_xwayland;` (and optionally
   `void *xwm;`) to `struct iosc_surface`.

   ```c
   struct wl_display *iosc_xwm_wl_display(void) { return g_display; }

   int iosc_xwm_adopt_surface(struct wl_resource *res,
                              const struct iosc_xwm_window_info *info) {
       struct iosc_surface *s = wl_resource_get_user_data(res);
       if (!s) return -1;
       if (s->role != IOSC_ROLE_NONE && !s->is_xwayland) return -1; /* has xdg role */
       s->is_xwayland = 1;
       s->role = info->override_redirect ? IOSC_ROLE_POPUP : IOSC_ROLE_TOPLEVEL;
       snprintf(s->title,  sizeof s->title,  "%s", info->title[0]  ? info->title  : "X11");
       snprintf(s->app_id, sizeof s->app_id, "%s", info->wm_class);
       if (info->override_redirect) { s->dx = info->x; s->dy = info->y; }
       if (!s->mapped && s->current_buffer) surface_map(s);
       else if (!s->mapped) s->configured = 1; /* map on first buffer commit */
       return 0;
   }

   void iosc_xwm_unadopt_surface(struct wl_resource *res) {
       struct iosc_surface *s = wl_resource_get_user_data(res);
       if (!s || !s->is_xwayland) return;
       surface_unmap(s);
       s->is_xwayland = 0; s->role = IOSC_ROLE_NONE;
   }

   void iosc_xwm_configure_surface(struct wl_resource *res, int x, int y, int w, int h) {
       struct iosc_surface *s = wl_resource_get_user_data(res);
       if (!s || !s->is_xwayland) return;
       if (s->role == IOSC_ROLE_POPUP) { s->dx = x; s->dy = y; }
       /* TODO: managed-toplevel resize path. */ (void)w; (void)h;
       if (s->mapped) recomposite_all();
   }

   void iosc_xwm_set_title(struct wl_resource *res, const char *title) {
       struct iosc_surface *s = wl_resource_get_user_data(res);
       if (!s || !s->is_xwayland) return;
       snprintf(s->title, sizeof s->title, "%s", title ? title : "");
       if (s->role == IOSC_ROLE_TOPLEVEL) { ftl_broadcast_state(s); }
   }
   ```

   NOTE: because Xwayland surfaces have **no `xdg_toplevel`**, guard the existing
   toplevel paths that assume it. Specifically:
   - `surface_map`: it calls `keyboard_set_focus` and `ftl_toplevel_mapped` for
     toplevels — both fine with `xdg_toplevel==NULL`. The native-mode
     `xios_canvas_announce` block is also fine (uses window_id/app_id/title).
   - The **close** paths that call `xdg_toplevel_send_close(s->xdg_toplevel)`
     (native `NATIVE_CMD_CLOSED`, any decoration/taskbar close) must branch:
     `if (s->is_xwayland) iosc_xwm_request_close(s->resource); else if
     (s->xdg_toplevel) xdg_toplevel_send_close(...);`.
   - `toplevel_send_configure` (native resize) dereferences `s->xdg_surface`;
     skip it for `is_xwayland` (or route to `iosc_xwm_configure_surface`).

3. **Commit hook**: at the top of `surface_commit` (iosc.c:2026), right after
   `struct iosc_surface *s = wl_resource_get_user_data(r);`, add:
   ```c
   iosc_xwm_surface_commit(r);   /* apply pending Xwayland association (no-op otherwise) */
   ```
   Adoption (role + map) happens synchronously here; the rest of `surface_commit`
   then processes this commit's buffer and recomposites, so the first buffered
   commit both associates and shows content.

4. **Focus mirror**: in `keyboard_set_focus` (iosc.c:3887), after `g_kbd_focus =
   s;`, add:
   ```c
   iosc_xwm_notify_focus(s ? s->resource : NULL);
   ```

5. **Start it (gated)**: in `main()`, after the globals are created and the event
   loop exists (just before `wl_display_run`, iosc.c:7056), add:
   ```c
   if (env_truthy(getenv("IOSC_XWAYLAND")))
       if (iosc_xwm_start(wl_display_get_event_loop(g_display)) != 0)
           fprintf(stderr, "iosc: Xwayland XWM failed to start\n");
   ```
   and `iosc_xwm_shutdown();` after `wl_display_run` returns (before
   `wl_display_destroy`).

6. **`IOSC_MAX_SURFACES` bump**: X apps open many short-lived surfaces (menus,
   tooltips, combo popups). Raise `#define IOSC_MAX_SURFACES 16` (iosc.c:256) to
   at least **64**. (This also helps the zombie-surface stacking noted in
   `handoff/iosc-compositor.md`.)

7. **(optional) registry hide**: to also hide `xwayland_shell_v1` from non-
   Xwayland clients' `wl_registry`, iosc.c may install a
   `wl_display_set_global_filter` that returns false for the shell global unless
   `iosc_xwm_is_xwayland_client(client)`. Bind is already hard-refused without
   this, so it is cosmetic/hardening.

## build-iosc.sh integration checklist (frozen)

1. **Scanner step** (add beside the other `wayland-scanner` calls, ~line 209):
   ```sh
   XWLSHELL_XML="$X11/wayland/protocols/xwayland-shell-v1.xml"
   wayland-scanner server-header "$XWLSHELL_XML" "$GEN/xwayland-shell-v1-server-protocol.h"
   wayland-scanner private-code  "$XWLSHELL_XML" "$GEN/xwayland-shell-v1-protocol.c"
   ```
2. **Compile/link line** for `iosc` (~line 233): add the sources
   ```
       "$X11/wayland/iosc_xwm.c" \
       "$GEN/xwayland-shell-v1-protocol.c" \
   ```
   and link **libxcb**: add `-lxcb` (with `-L` for its lib dir if not already on
   the rpath). The `$INCS` already has `-I$GEN`; add the xcb include dir from the
   sysroot.
3. **Sysroot dep**: `xdeb_extract` must pull **`libxcb1` + a `libxcb-dev`** (for
   `xcb/xcb.h`, `xcb/xproto.h`) for iphoneos-arm64. `libxcb1_1.14` exists in the
   repo, but **no `libxcb-dev` iOS deb exists yet** — one must be built/added
   (headers only; the module uses just core libxcb, NOT xcb-util/xcb-icccm, so no
   extra runtime dep). This is the one genuinely new build input.
4. Xwayland already ships (`xwayland_23.2.7`) and supports `-rootless -wm
   -displayfd -terminate` (verified in `run-xwayland.sh`).

## Runtime / device bring-up (after integration)

- Launch iosc, then the Xios app (as in `run-xwayland.sh`), then run iosc with
  `IOSC_XWAYLAND=1` — the XWM spawns Xwayland itself (do NOT also start the
  rootful Xwayland from `run-xwayland.sh`). X clients are launched with the
  `DISPLAY` the module sets (`:N`), e.g. `DISPLAY=:1 xterm`.
- Debug: `IOSC_XWM_DEBUG=1` traces association/adopt; `IOSC_XWAYLAND_BIN`
  overrides the Xwayland path.

## Standalone compile-check (reproduce)

The throwaway harness lives in the session scratchpad
(`.../scratchpad/xwm-compile-check.sh`, not committed). It: extracts
`libwayland-dev` from `repo/debs`, installs host `libxcb1-dev` headers (isolated
so they don't shadow the iOS SDK), `wayland-scanner`s the vendored XML, and cross-
compiles. The exact command that succeeds:

```
CC=aarch64-apple-darwin-clang
SDK=/root/cctools/bin/../SDK/iPhoneOS.sdk
$CC -arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra \
    -Wno-unused-parameter \
    -I<sysroot>/var/jb/usr/include -I<gen> -I<x11>/wayland -I<xcb-include-dir> \
    -c <x11>/wayland/iosc_xwm.c -o iosc_xwm.o
```

Result: **0 errors, 0 warnings.** A follow-up link against libwayland-server +
the generated `xwayland-shell-v1-protocol.c` + a glue stub resolves all module
symbols (xcb_* deferred to the device build's `-lxcb`).

## Spec ambiguities encountered

- **Serial byte order**: the XML says the `WL_SURFACE_SERIAL` client message
  carries lo in `l[0]`, hi in `l[1]`; `set_serial` takes `serial_lo`, `serial_hi`.
  We reconstruct `(hi<<32)|lo` on both sides. Unambiguous once read carefully.
- **"implementation-defined error"** for non-Xwayland binds — we use
  `wl_client_post_implementation_error`; any protocol error is spec-compliant.
- **Reparenting**: the protocol is silent on framing; for a rootless compositor we
  do NOT reparent (Xwayland owns the frame/buffer). The XWM only redirects and
  maps, matching how modern rootless XWMs behave.
- **WM_Sn replace handshake**: full "wait for old WM to release the selection"
  is unnecessary for a fresh iosc session (we own the display from the start), so
  we take `WM_S0` with `CurrentTime` directly. Documented as a simplification.
```
