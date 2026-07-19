# KDE output-management in iosc

iosc implements the KDE output-management protocol family so kscreen-doctor,
libkscreen and Plasma can enumerate and reconfigure iosc's single output
directly, including a runtime scale change. This is what lets the KDE flavor's
scale control actually resize the desktop instead of only telling nested KWin to
tag its buffer.

## Protocols and versions

Vendored XMLs live in `wayland/protocols/` (plasma-wayland-protocols 1.13.0,
MIT-CMU). Advertised globals:

- `kde_output_device_v2` v8 (plus `kde_output_device_mode_v2` v1)
- `kde_output_management_v2` v9 (plus `kde_output_configuration_v2` v9)
- `kde_primary_output_v1` v2
- `kde_output_order_v1` v1

libkscreen 6.1.5 binds device at v8, management at v9 and order at v1; it does
not bind primary (plasma-workspace does). The versions above match exactly.

All four are registered in `register_wayland_globals()` and the implementation
lives in the "KDE output-management family" block in `wayland/iosc.c`.

## Output identity

The output reports a single stable name, `IOSC-1` (`IOSC_OUTPUT_NAME`), across
`wl_output` v4 name, `zxdg_output_v1` name, `kde_output_device_v2` name+uuid,
`kde_output_order_v1` and `kde_primary_output_v1`. The device uuid is set equal
to the name so `kde_primary_output_v1` resolves whether the consumer keys on the
name or the uuid (the XML comment says uuid, modern Plasma matches by name).

The device advertises exactly one mode: the current physical mode
(`g_width`x`g_height` @ 60000 mHz, marked preferred and current). The mode object
is a server-created event resource tracked per device resource; it is recreated
only when its size changes (rotation), so a scale-only change keeps the client's
mode reference valid. Each recreation bumps a per-device mode generation; a
configuration's `mode` request records the generation, and `apply` rejects a
reference whose generation is stale (rotation between `create_configuration` and
`apply`), even if the allocator reused the address. `capabilities` is 0 (no
overscan/vrr/rgb-range/HDR), which is honest and does not gate the scale
control.

## Scale semantics

Scale is an integer, clamped to [1, 4]. A fractional request (wl_fixed) is
rounded to the nearest integer and the rounded value is applied.

On a scale-only change the physical IOSurface size stays fixed, unconditionally,
and the logical size becomes ceil(physical/scale), so a larger scale gives a
larger UI. The reconfigure core (`output_reconfigure_px(pw, ph, transform,
scale)`, with the old `output_reconfigure(lw, lh, transform)` kept as the
rotation-path wrapper) takes physical dims directly: a scale-only apply passes
the current physical size through unchanged instead of round-tripping it through
logical, so the invariant holds even when the physical size is not divisible by
the new scale, and repeated scale changes cannot drift the IOSurface size. When
the physical size is unchanged the core skips `xios_surface_resize` and
`iosc_gl_resize`, so the Xios app connection is not dropped and the IOSurface is
not reallocated.

`g_natural_lw`/`g_natural_lh` (the transform-0 logical dims used by a later
`XIOS_IN_OUTPUT` rotation with x=y=0) are re-derived from the natural-orientation
physical size and the current scale on every reconfigure, so a rotation after a
scale change uses the post-change logical size instead of reverting.

After a change, the core re-advertises every output global in one place
(`broadcast_output_all`): `wl_output`, `zxdg_output_v1`, the
`wp_fractional_scale_v1` preferred_scale (scale*120) to all tracked clients, and
the KDE device/order/primary bursts. Fullscreen and maximized toplevels are
re-configured with the new logical size by the existing per-surface loop.

## Configuration apply

`kde_output_configuration_v2` collects pending state, then `apply` validates and
commits it once. Accepted and acted on: `enable` (disabling the only output is
rejected with `failed`), `mode` (only the advertised mode object at its recorded
generation is accepted; a stale or foreign mode is `failed`), `transform` (0-7,
mapped 1:1 to the wl_output transform and routed through the same reconfigure
path `XIOS_IN_OUTPUT` uses), `scale` (rounded and clamped as above), `position`
(single output, ignored).

Accepted and ignored, one stderr line each, so kscreen stays happy without us
pretending to support them: `overscan`, `set_vrr_policy`, `set_rgb_range`,
`set_primary_output`, `set_priority`, `set_high_dynamic_range`,
`set_sdr_brightness`, `set_wide_color_gamut`, `set_auto_rotate_policy`,
`set_icc_profile_path`, `set_brightness_overrides`, `set_sdr_gamut_wideness`,
`set_color_profile_source`, `set_brightness`.

`apply` sends `applied` on success and `failed` on a rejected or failed change
(including an IOSurface resize failure). On a successful change the output state
is re-broadcast exactly once, from inside the reconfigure core, before `applied`;
a no-op apply broadcasts a fresh snapshot from the apply path instead, so the
applying client's view is current either way. A second `apply` posts the
`already_applied` protocol error. A configuration destroyed without apply, or
outliving its apply, frees cleanly.

## Fullscreen buffer_scale stretch

A nested compositor such as KWin runs as an iosc client pinned to a fixed buffer
size and, when the user sets the KDE UI scale, tags its host surface with
`wl_surface.set_buffer_scale(ceil(scale))` and sends no viewporter or
fractional-scale. iosc otherwise maps that to `buffer_px / buffer_scale` logical,
so the fullscreen desktop shrinks to a fraction of the output.

To fix this, a fullscreen xdg toplevel in the shared-output composite path
(`surface_fills_output`) is always drawn filling the whole output
(`composite_surface_at` forces the destination rect to `0,0,g_width,g_height`),
regardless of its buffer size or buffer_scale. The source rect stays the full
buffer, honoring any viewport source. The native-mode per-window path
(`native_composite_toplevel`) is deliberately excluded, so it is unaffected.

Damage for a stretched surface falls back to full-surface
(`output_damage_add_surface_dirty_rects` and `surface_rect` via
`surface_output_size`), because the per-rect buffer-to-output math does not hold
under the stretch. This is correctness over performance and only triggers for
mismatched fullscreen clients.

## Input remapping

Because the fullscreen surface is stretched, output-logical input coordinates
must be scaled into the surface's own logical space before delivery, or clicks
land in the wrong place. `surface_local_coords(s, x, y, &sx, &sy)` is the single
helper all input paths use: for a stretched fullscreen surface it computes
`surface_local = (output_logical - dx) * surface_logical / output_logical`
(dx/dy are 0 for fullscreen); for every other surface it is the plain translate
by the surface origin and is bit-for-bit identical to the old
`wl_fixed_from_int(coord - origin)` for integer inputs.

Call sites routed through the helper: `wl_pointer` enter and motion, `wl_touch`
down and motion, `zwp_tablet_tool_v2` motion (pen), and `wl_data_device` drag
enter and motion. Hit-testing (`surface_at`) and the pointer-confinement clamp
(`confine_point`) use `surface_output_size`, so a stretched fullscreen surface is
hit and confined across the whole output. Fullscreen configure senders still
request `output_logical_width/height`; the stretch is only a fallback for clients
that ignore their configure.

## On-device test plan

Host verification passed on 2026-07-18: `wayland/build-iosc.sh` generated all
four protocol families, cross-compiled the compositor and test clients for
arm64 iOS, and signed the compositor. The resulting payload is versioned as
`iosc 0.9.18` so it does not overwrite the already-published 0.9.17 artifact.

Runtime validation remains deferred while the device is offline. Run these
from a terminal on the device once it is reachable.

1. Enumerate: `WAYLAND_DISPLAY=<iosc socket> kscreen-doctor --outputs`. Expect one
   output named `IOSC-1`, enabled, one mode at the physical size, current scale.
2. Scale up: `kscreen-doctor output.1.scale.2` then `.3`. Expect the desktop UI
   to grow, the IOSurface to stay the same physical size (no Xios reconnect in the
   iosc log), and `wp_fractional_scale` clients (iosc-shell) to re-render at the
   new scale. `kscreen-doctor --outputs` should report the new scale and the new
   logical size (physical/scale).
3. Rotation after scale: set a non-default scale, then rotate the iPad. Expect the
   post-rotation logical size to reflect the scale (derived from `g_natural_*`),
   not revert to the launch scale.
4. KDE flavor: open systemsettings, Display and Monitor, change Global Scale, and
   confirm the change applies (Plasma drives `kde_output_management_v2.apply`).
5. Nested KWin fullscreen: run the KDE session and confirm the desktop fills the
   whole output at any UI scale (no quarter-screen shrink) and that pointer and
   touch land correctly across the whole surface.
