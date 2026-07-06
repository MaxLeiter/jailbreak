# Xios Architecture Rewrite TODO

Status owner: keep this file as the cross-cutting architecture backlog. Use the
handoff files for subsystem-specific state and device evidence.

## Selected Tracks

The user-selected set is original items `1, 2, 4, 5, 6, 7, 8, 9`.
Original item `3` was iosc-only static layer caching and is intentionally
excluded from this cross-stack list.

1. Original #1: `iosc` subsystem split
   - Continue extracting `iosc.c` into modules with stable internal APIs.
   - Next seams: output/damage bookkeeping, surface lifecycle, input routing,
     render planning, protocol bridges.
   - Rule: each split must build and smoke independently; do not mix behavior
     rewrites into pure extraction commits.

2. Original #2: explicit compositor scene/render plan
   - Add a per-frame render plan that classifies surfaces, visible regions,
     damage, and backend draw operations before GL work begins.
   - Target shape: gather surfaces -> classify roles/layers -> compute visible
     regions -> emit draw ops -> renderer consumes draw ops.
   - This is about correctness and maintainability first; performance work like
     static layer caching can come later.

3. Original #4: versioned IOSurface GPU protocol
   - Keep `iosc_iosurface` as the shared ABI for iosc, Xwayland, ANGLE, Qt/GTK,
     and future Ladybird GPU paths.
   - Extend the current enum/format work into versioned capabilities: origin,
     format, alpha, colorspace, fence/sync, and explicit protocol errors.
   - Add a conformance smoke client that can be run against iosc and nested KWin.

4. Original #5: single session supervisor model
   - Make `ioscd` the owner of session lifecycle and status.
   - Make `xios-session` a CLI client plus preset runner, not an independent
     state authority.
   - Convert launch scripts into supervised preset units with one structured
     status tree instead of scattered tmp-file state.

5. Original #6: Xios.app host split
   - Split `XScreen.swift` responsibilities into display connection, input
     routing, session control, Metal presentation, and overlay control.
   - Keep the existing UIKit/Metal behavior intact while extracting seams.
   - First target: isolate the IOSurface/DDX adopt/drain/reconnect state machine.

6. Original #7: native iPadOS backend boundary
   - Treat classic one-output IOSurface and native per-window IOSurfaces as two
     compositor backends over the same surface/input core.
   - Clarify which state is shared and which is backend-specific.
   - Validate coexistence, per-window touch transform, keyboard hints, and
     jetsam replay as part of the boundary.

7. Original #8: capability profiles for launch/runtime
   - Replace ad hoc env var bundles with named profiles: `iosc-client-gpu`,
     `iosc-platform-gl`, `kde-kwin`, `plasma-egl`, `gtk-wayland`,
     `xwayland-glamor`, and native host profiles.
   - Each profile should declare required env, entitlement tier, package deps,
     and smoke checks.

8. Original #9: formal hardware entitlement/signing pipeline
   - Declare GPU/IOSurface entitlement profiles and verify them in build/publish
     tooling.
   - Reject packages where GPU-accelerated graphics binaries carry Procursus
     `no-container`, miss required IOKit markers, or only partially match a
     profile.
   - Keep macOS DER re-signing mandatory before install/publish.

## Current First Slice

Implement profile validation in `linux-build/resign-graphics-packages.py`.
That script already runs in the publish path and already inspects every Mach-O in
graphics debs, so it is the right first guardrail for tracks 7 and 8.

The first implementation defines publish-time hardware profiles for
`gpu-client`, `platform-gl`, `iosurface-ipc`, and `platform-iosurface` binaries,
then rejects incoherent packages before DER re-signing.

## Current Second Slice

Start the runtime capability registry in
`apps/iosc-desktop/xios-capability-profiles.sh`. It names the first cross-stack
profiles, ties each one to an entitlement tier, records package/smoke
expectations, and prints sourceable env blocks. Launchers can now move duplicated
GTK/Qt/KDE/Xwayland env bundles into this shared registry one caller at a time.
