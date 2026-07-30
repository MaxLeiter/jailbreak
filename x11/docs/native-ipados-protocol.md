# iosc per-window rendezvous (native iPadOS flavor) — implementation spec

Audience: the iosc maintainer (iosc-protocols). This specifies the compositor
half of the native flavor's per-window presentation. The client half is already
written and type/compile-checked:

- `x11/apps/iosc-host/Sources/iosc_native_proto.h` — the wire contract (shared).
- `x11/apps/iosc-host/Sources/NativeClient.c` — the reference client.
- `x11/apps/iosc-host/Sources/IoscInput.c` — input, with the new `XIOS_IN_BIND`.

Design rationale and the iPadOS-side lifecycle are in
`x11/docs/native-ipados-plan.md`. This doc is only the iosc-side contract.

Scope note: this protocol is now implemented by `wayland/xios_canvas.c`,
`wayland/iosc.c`, and `apps/iosc-host/Sources/NativeClient.c`; remaining work is
device validation and polish. FRAMING IS AGREED (2026-07-01, iosc-protocols):
the shared 32-byte `xios_msg` record ('XMS1'), core codes 0x01-0x0f owned by
iosc-protocols (HELLO/DIRTY/CURSOR), range 0x40-0x5f reserved for native.
Protocol v1 uses native `XIOS_MSG_NATIVE_FRAME` rather than core DIRTY. Every
frame carries exactly one 32-byte broker token and a non-zero shared-event
value; there is no unfenced variant or older-version branch. This spec and the
reference client are written against the shared header.

---

## 1. What changes, and what does not

The other three flavors (GNOME / KDE / X11) are unchanged: iosc composites every
mapped window into ONE output IOSurface (`xios_surface_create`) and the single
Xios app presents it. That path stays byte-identical.

Native mode adds a SECOND presentation topology. It is selected per launch by
ioscd's explicit `LAUNCH_NATIVE` request and may also be forced at the
compositor layer with `iosc -native`/`IOSC_NATIVE=1` for debugging. It is not a
build-time choice: classic and native compositor namespaces can coexist on the
same device. In native mode
iosc gives each `xdg_toplevel` its own "canvas" IOSurface and hands it to a
per-app host app over a new socket. The host Metal-presents that canvas in its own
UIWindowScene. So iPadOS multitasking, not iosc, is the window manager.

Everything native mode needs already exists in single-output form; the work is to
run it per-window:

| Existing (single output) | Native (per window) |
|---|---|
| `xios_surface_create()` makes one output IOSurface | allocate one canvas IOSurface per toplevel |
| `deliver_surface_port()` hands the output port to the Xios app | hand each canvas port to the owning host (§5) |
| `xios_notify_dirty()` streams a DIRTY record | send `XIOS_MSG_NATIVE_FRAME` with `window_id` and a broker fence (§6) |
| `iosc_gl_init(output, w, h)` + `recomposite_all()` paint the whole stack into the output | paint ONE toplevel (+ its popups/subsurfaces) into ITS canvas (§4) |
| input hit-tests a shared coordinate space | a bound connection is pre-scoped to one window (§7) |

---

## 2. Mode gate

Read native mode from the runtime launch configuration (`-native`,
`IOSC_NATIVE=1`, or ioscd's native mode for a `LAUNCH_NATIVE` request). When set:

- create the `iosc-native.sock` listener (§3) in addition to the normal startup;
- keep allocating the output IOSurface as today (harmless; native hosts just
  never adopt it, and it keeps the readback/probe tooling working), OR skip it to
  save memory — implementer's choice, not load-bearing;
- toplevels get a per-window canvas + configure sized to their host's scene (§6)
  instead of the shared cascade placement;
- `recomposite_all()` becomes per-canvas (§4).

When unset, none of the above runs and iosc behaves exactly as now. ioscd keeps
classic on `wayland-0`/`iosc-input.sock`/`xios.json` and native on
`wayland-native-0`/`iosc-native-input.sock`/`xios-native.json`, so both paths can
be live together.

---

## 3. The socket

Serve `IOSC_NATIVE_SOCK` = `/var/jb/tmp/iosc-native.sock`. The socket must not
fall back to world-writable permissions: current code chowns/chmods for the
mobile host when possible and otherwise degrades to root-only 0600 with a
warning. One connected host = one app_id = the windows of one Linux app. Register
the listen fd on the wl event loop next to the input socket. Per-connection
state:

```
struct native_host {
    int          fd;
    char         app_id[256];   // from BIND
    mach_port_t  reply_port;    // send-right into the host, from BIND (§5)
    int          scene_w, scene_h, scale;
    struct wl_list link;
};
```

Framing is the shared typed record `xios_msg` (fixed 32 bytes: magic 'XMS1',
type, window_id, length, then int32 a,b,c,d) + optional `length`-byte payload.
See `iosc_native_proto.h` (which mirrors the authoritative shape). Read a whole
header, then the payload, then dispatch on `type`; unknown types are protocol
errors while the product is unreleased.

---

## 4. Per-window compositing

Today `iosc_gl_init(output_iosurface, w, h)` binds ONE render target (the output
pbuffer) and `recomposite_now()` paints the whole `g_mapped[]` stack into it.

Native mode paints ONE toplevel into ITS canvas. Two viable shapes; recommend B.

- A. Keep one GL context, add `iosc_gl_set_target(iosurface, w, h)` that rebinds
  the pbuffer/FBO to a given canvas, and loop: for each dirty toplevel, set target
  = its canvas, `iosc_gl_begin` / draw the toplevel + its subsurfaces + its popups
  / `iosc_gl_end`. Cheapest change; one context, N targets.
- B. Same, but only repaint canvases whose window is dirty (the per-surface
  `gl_dirty` flag from the P0.2 texture cache already tracks this). A cursor move
  or one window's damage repaints only that canvas. This is the native analogue of
  the P0.4 coalesced repaint and is what keeps N windows cheap.

The composited content per canvas = the toplevel's own buffer (GPU IOSurface via
`iosc_gl_draw_iosurface`, or wl_shm via `iosc_gl_draw_shm`) plus any mapped
`IOSC_ROLE_SUBSURFACE` children plus any mapped `IOSC_ROLE_POPUP` whose parent is
this toplevel, drawn at their offsets. No cross-window stacking: each canvas holds
exactly one toplevel's tree. Occlusion / z-order between apps is iPadOS's job.

After painting a canvas, publish the producer `MTLSharedEvent` through the
package-owned broker and send `XIOS_MSG_NATIVE_FRAME` for that window (§6).
Production must not publish an unfenced frame; the CPU barrier is an explicit
diagnostic-only mode. Orientation:
reuse the M7 conventions (`flip_v=1` for ANGLE-rendered client IOSurfaces,
`flip_v=0` for wl_shm) exactly as the output path does; the host samples the
canvas the same way the Xios app samples the output, so the same placement/content
flips apply.

Fast path (v2, later): when a toplevel has NO popups/subsurfaces and a GPU client
buffer, skip the compositor pass entirely and deliver the client's own buffer
IOSurfaces to the host (see §9).

---

## 5. Canvas delivery (mach port)

Reverse of the client-import path, and identical in shape to
`deliver_surface_port()` in `xios_surface.c`:

1. On BIND the host passes `msg.d` = a mach receive-port NAME in ITS task, and
   `get-task-allow` is set on the host (it is; see `iosc-host/entitlements.plist`).
   `task_for_pid()` the host by the socket peer pid
   (`wl_client`-style `LOCAL_PEERPID` on the native socket), then
   `mach_port_extract_right(MACH_MSG_TYPE_COPY_SEND)` to get a send right to the
   host's reply port. Store it as `reply_port`. (This mirrors
   `deliver_surface_port` lines 1–20, but the port travels host→iosc via BIND
   instead of app→server via the ddx hello.)
2. To deliver a canvas for WINDOW_NEW / WINDOW_GEOM: `IOSurfaceCreateMachPort(canvas)`
   then `mach_msg(MACH_SEND_MSG | MACH_SEND_TIMEOUT)` a one-descriptor complex
   message to `reply_port`, exactly like `deliver_surface_port` lines 20–40.
   `mach_port_deallocate` the created port after send.

Ordering contract the client relies on: write the `XIOS_MSG_WINDOW_NEW` /
`XIOS_MSG_WINDOW_GEOM` socket record FIRST, then send the matching canvas port.
Current code queues the delivery from the compositor thread and performs the
potentially blocking `task_for_pid`/timed `mach_msg` work on the native
reader/delivery path. One canvas per NEW/GEOM record; keep them one-to-one so
arrival order correlates. A monotonically changing canvas generation binds the
latest frame fence to the storage it authorizes; after a reconnect, the latest
valid fence is replayed only after the matching canvas port has been delivered.

---

## 6. Messages

All records are `xios_msg` (§3); params are `a,b,c,d`; geometry is physical
pixels. `window_id` is COMPOSITOR-assigned (a monotonic u32, stored on
`struct iosc_surface`); the host echoes it back on RESIZE/ACTIVATE/CLOSED.

### host -> iosc (native codes 0x40+)

- `XIOS_MSG_BIND` (0x40): payload = app_id; `a`=scene_w, `b`=scene_h, `c`=scale,
  `d`=reply-port name; `window_id`=0. Record the host; extract `reply_port` (§5).
  From now, any toplevel that matches this app_id (§8) is presented to this host.
  If a matching toplevel already exists (host relaunched after a jetsam kill),
  immediately emit `XIOS_MSG_WINDOW_NEW` + canvas for each live matching toplevel
  — this is the re-attach path that makes host jetsam invisible to the Linux app.
- `XIOS_MSG_RESIZE` (0x41): `a`=w, `b`=h for `window_id`. Send the toplevel an
  `xdg_toplevel.configure` at (w,h) (÷scale for logical), let the client ack +
  commit, then reallocate that window's canvas to the new size and emit
  `XIOS_MSG_WINDOW_GEOM` + a fresh canvas. Coalesce rapid resizes (Split View
  drag) the same way `recomposite_all` coalesces repaints.
- `XIOS_MSG_ACTIVATE` (0x42): `a`=1 active / 0 inactive for `window_id`. On
  active, `surface_raise()` is irrelevant (no shared stack) but
  `keyboard_set_focus()` to this toplevel IS: the key scene's window owns
  wl_keyboard. On inactive from the window that currently holds focus,
  `keyboard_set_focus(NULL)`.
- `XIOS_MSG_CLOSED` (0x43): the user swiped the scene away. Send
  `xdg_toplevel.close` to `window_id`'s client. If the client ignores it, ioscd
  may SIGTERM after a grace period (host-side policy, not iosc's concern).

### iosc -> host (native codes 0x50+, plus core DIRTY/CURSOR)

- `XIOS_MSG_WINDOW_NEW` (0x50): a toplevel matched this host and mapped. `a`=w,
  `b`=h, `c`=stride, `d`=flags (`XIOS_NWIN_MAXIMIZED`/`FULLSCREEN`); payload =
  title. Canvas mach_msg follows (§5). Assign `window_id` here.
- `XIOS_MSG_WINDOW_GEOM` (0x51): canvas reallocated after a RESIZE. `a`=w, `b`=h,
  `c`=stride. Fresh canvas mach_msg follows. Release the old canvas after the host
  has had a chance to swap (a frame later, or on the next DIRTY).
- core `XIOS_MSG_DIRTY` (0x02) with `window_id`: that canvas changed; sent after
  each per-canvas repaint (§4). `a,b,c,d` = damage rect (all 0 = whole canvas);
  the current host re-presents the whole canvas either way. Coalesce like the
  output DIRTY byte.
- `XIOS_MSG_WINDOW_TITLE` (0x52): payload = new title. Fire from the existing
  `xt_set_title` path (which already stores title on `struct iosc_surface`) when
  the surface belongs to a bound host.
- `XIOS_MSG_WINDOW_GONE` (0x53): the toplevel unmapped or the client exited. Fire
  from the existing unmap/destroy path even if WINDOW_NEW is still in-flight.
  Free the canvas. A GONE for a window the host never observed is a harmless
  no-op and prevents orphan scenes during map/unmap races.
- core `XIOS_MSG_CURSOR` (0x03) with `window_id`: `a`=x `b`=y, `c`=shape_id
  (cursor-shape-v1 enum, 0=hidden), `d`=flags (bit0 visible); optional
  `xios_cursor_bitmap` payload for client-supplied cursor images. The host maps
  shape_id to a per-scene `UIPointerStyle` and drains any bitmap payload.
  Optional / later; wire it off the cursor-shape request iosc already handles.

---

## 7. Input scoping (`XIOS_IN_BIND`)

iosc's input reader (`xios_input_socket.c` + the `handle_*` paths in iosc.c)
currently hit-tests one shared coordinate space. Native input is already
per-window: each UIWindowScene's `HostScreenView` opens its own
`iosc-native-input.sock` connection and sends one `XIOS_IN_BIND` record (type 8,
`code` = window id) before any event (`IoscInput.c` in iosc-host). Classic Xios
desktop input continues to use `iosc-input.sock`, so both compositor namespaces
can be live on-device.

Implemented in iosc's input reader:

1. `XIOS_IN_BIND 8u` is defined in the authoritative header
   `x11/wayland/xios_input_socket.h` and its `xios-glue-stub.h` twin.
2. The shared reader tags each input client connection with its bound window.
   Unbound connections keep output-wide hit-testing; `XIOS_IN_BIND` stores the
   target window on that connection.
3. For a bound connection, route events directly to that window's toplevel with NO
   hit test: `MOTION`/`BUTTON`/`TOUCH`/`TABLET` coordinates are already
   canvas-local (the host maps them), so deliver straight to that surface's
   `wl_pointer`/`wl_touch`/tablet; a `KEY` moves `keyboard_set_focus` to that
   window if it is not already focused, then delivers. Focus otherwise follows the
   `XIOS_MSG_ACTIVATE` messages (§6).

Unbound connections (the Xios app, other flavors) keep the current shared
hit-test path verbatim.

---

## 8. Matching a toplevel to a host

Primary key: the Wayland `app_id` (`xt_set_app_id`, already stored on
`struct iosc_surface`). On toplevel map, find the bound host whose `app_id`
matches and present there. This is the same key `wm_find_toplevel_by_app_id`
(iosc-wm.sock) already uses, so the machinery exists.

Fallbacks, in order:

1. session id: ioscd `setsid()`s every client launch, so the toplevel client's
   session id identifies which ioscd launch (and thus which host) spawned it. iosc
   can read the client pid's sid; a host can report its expected child sid at BIND
   if we want this exact (optional refinement).
2. catch-all: a toplevel matching NO bound host goes to the plain Xios app (the
   shared output), so nothing is ever unreachable. In pure native mode with no
   Xios app running, hold it unpresented until a matching BIND arrives (the host
   is still launching), then deliver via the §6 BIND re-attach path.

Helper windows whose app_id differs from the launcher's IOSCAppID (some apps set a
distinct toplevel app_id per window) land via fallback 1 or 2.

---

## 9. Popups, subsurfaces, scale

- Popups (`IOSC_ROLE_POPUP`) and subsurfaces (`IOSC_ROLE_SUBSURFACE`) are NOT
  separate scenes: iPadOS cannot draw outside a scene. Composite them into their
  parent toplevel's canvas (§4). Constrain `xdg_positioner` placement to the
  toplevel bounds (flip/slide via the positioner's `constraint_adjustment`) so a
  menu never needs pixels outside the window. GTK scrolls/squeezes an
  over-tall menu; acceptable.
- Scale: advertise `wl_output` scale 2 (or the device scale) so GTK renders hidpi;
  the canvas is physical pixels; the host maps scene points × contentScaleFactor,
  exactly as the Xios app does.

## 9b. v2 fast path (later, optional)

When a toplevel has no popups/subsurfaces and renders via a GPU client buffer
(the common steady state), skip the compositor pass: deliver the client's own
buffer IOSurface ports to the host (it already triple-buffers via the EGL shim),
and let a per-window `XIOS_MSG_DIRTY` carry the buffer index (a spare param or a
new native code; decide then). Zero compositor work, zero copies. Fall back to §4
the moment a popup maps. All primitives exist
(`xios_import_client_iosurface` + the shim's buffer rotation); this is purely an
optimization and should come after v1 is on-device.

---

## 10. Shared framing agreement (RESOLVED 2026-07-01)

Native reuses the typed app-socket record iosc-protocols designed for the
cursor-overlay work. The agreed division:

- ONE symmetric 32-byte header (`xios_msg`, magic 'XMS1') both directions on both
  sockets. `iosc_native_proto.h` mirrors it; iosc-protocols' header in the
  compositor tree is authoritative — when it lands, either include it from the
  shared glue or keep the mirror byte-identical (same twin discipline as
  `xios-glue-stub.h`).
- Core codes 0x01-0x0f are iosc-protocols': HELLO (0x01), DIRTY (0x02), CURSOR
  (0x03). Native REUSES DIRTY and CURSOR with `window_id` set rather than
  defining per-window variants; that is the payoff of the shared envelope.
- 0x40-0x5f is RESERVED for native lifecycle codes; current assignments are §6
  (0x40-0x43 host to compositor, 0x50-0x53 compositor to host). Codes 0x44-0x4f
  and 0x54-0x5f are free for native growth.
- Separate socket confirmed: iosc-native.sock is typed from byte 0.
- iosc-protocols flags any field change when the cursor-overlay implementation
  lands; expected stable.

---

## 11. Validation

Mirror the existing test-client pattern (`iosc-gpu-client`, `iosc-layer-test`):
a tiny `iosc-native-test` that BINDs an app_id, maps a toplevel, and checks it
receives WINDOW_NEW + a canvas whose center pixel matches what a known client
painted (readback via `IOSurfaceLock`, same as the M-series probes). Then the real
path: `ioscd` in native mode + one generated host bundle (`gen-launchers.sh
--native`) + a GTK app, tap the icon, confirm the app appears in its own scene and
in the app switcher. Basic native launch has been reported working; keep logging
resize/focus/text/close/coexistence/jetsam-replay results in
`docs/handoff/native-ipados.md`. On-device photons are the lead's confirm.
