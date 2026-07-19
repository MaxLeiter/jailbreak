# Loose-ends closure audit

Status authority for the repository-wide sweep performed 2026-07-18 while the iPad was
offline. This file separates implemented host work from package assembly, device-only proof,
intentional compatibility shims, and genuine port blockers. Do not turn every occurrence of
“stub” into a replacement project: several shims are the correct iOS implementation of a Linux
API whose kernel or service does not exist here.

## Closed in this sweep

- `iosc 0.9.18` builds and signs from a clean host invocation. Its four KDE output-management
  XML families generate, the package is present in `linux-build/out` and `repo/debs`, and the
  generated repo indexes 0.9.18.
- The in-progress Mutter output handler now replaces the backing IOSurface before monitor
  reload, instead of changing only Mutter's mode metadata. Startup also honors the existing
  `IOSC_LOGICAL=WxH` session-picker request. The glue contract includes and checks
  `xios_surface_resize`; the next immutable libmutter revision is `46.0+ios3`.
- Native iPadOS host scrolling has a complete AXIS wire path and the host app builds/signs with
  the iPhoneOS SDK. Its shipping package is assigned `xios-launcher-tools 0.1.1`.
- Session teardown and the KDE child monitor now replace stale `up` status with `down`;
  synthetic teardown validation passed. Shipping version is `xios-session 1.0.55`.
- `xios-a11yd` handles VoiceOver browse focus without stealing keyboard focus; the new handler
  passed a host SDK syntax check. Shipping version is `xios-a11y-tools 0.2.15`.
- The iosc shell package and internal build stamp now agree on `0.9.11`.
- ANGLE and TigerVNC source patches now have deterministic `series` files. The duplicate
  TigerVNC patch under `linux-build/patches` was removed and the Procursus overlay consumes the
  port-owned patch stack.
- A full XFCE 4.16 build driver now owns recipe/control staging, host tools, target order,
  artifact collection, and the libgtkintl pass. The old claim that XFCE was blocked on GTK3 was
  removed; it is unvalidated, not architecturally blocked.
- Published recipe status was reconciled against `repo/Packages`. Wayland, epoll-shim,
  libxkbcommon, mozjs, GJS, Nautilus, and the published GTK4/GNOME closure no longer claim to be
  drafts. GNOME Terminal remains draft because its GTK3 VTE flavor is genuinely absent.
- GTK typelib, hardware-bridge, and Mutter handoffs were updated to stop presenting closed or
  historical bring-up work as current blockers.
- The former libgtop empty process shim is gone. `libgtop 2.41.3+ios2` now implements the three
  GNOME Console entry points with Darwin `kern.proc`/`kern.procargs2`; its arm64 runtime package
  is built in `linux-build/out`.
- AccountsService profile mutations now persist and emit change notifications, while the BlueZ
  bridge tracks adapter/device/agent state and rejects unsupported pairing instead of returning
  false success. The rebuilt bridge set is `xios-session-stubs 0.2.5`.
- Plasma Mobile no longer owns inert Milou search QML. Real upstream Milou is packaged as
  `milou 6.1.5+ios1`; `plasma-mobile 6.1.5+ios21` depends on it and carries capability-explicit,
  iOS-backed network providers. Obsolete libplasma/plasma-pa no-op QML generators were removed.
- `xios-desktop-stublibs 0.1.1` now includes configurable password-policy parsing, scoring,
  bad-word/repeat/class/sequence checks, and generation instead of fixed pwquality answers.
- KWin's `+ios3` compile-only OpenGL milestone is now a complete nested GPU path.
  `kwin 6.1.5+ios4` enables the ANGLE/Metal compositor, IOSurface output swapchains,
  direct IOSurface client textures, and EGL-backed QPA contexts; the old QPA `nullptr`
  and CPU-copy runtime seams are gone. The clean build also closes the QPA EGL include-order,
  source-list, dylib-visibility, and parallel-autogen failures found during packaging.

## Verification completed

- `bash wayland/build-iosc.sh`: arm64 compositor and clients generated, linked, and signed.
- `apps/iosc-host/build-host.sh`, `apps/iosc-desktop/build-stub.sh`, and the pre-stamp-adjustment
  `apps/iosc-shell/build-panel.sh`: host builds passed.
- `wayland/build-xios-glue.sh`: static and dynamic glue libraries built with the full exported
  Xios API.
- `linux-build/build-backend-check.sh`: the four changed Mutter input/monitor sources passed
  Mutter 46's strict compile flags before the final resize/startup additions. Rerun it for the
  final tree when the shared Docker build clears.
- Shell syntax, package-control required fields, patch-series coverage, Plasma generated-provider
  audit, and `git diff --check` passed.
- Strict host compiles passed for libgtop, AccountsService, BlueZ, and pwquality. libgtop's host
  runtime probe returned a real process list, parent/euid, and argv. Cross-builds produced arm64
  Mach-O bridge/library payloads and the shim-closure candidates listed below. KWin also completed
  a clean 806-step source build plus an incremental link/package pass; its payload links ANGLE
  EGL, Metal, IOSurface, and libepoxy and has the compositor entitlement set.
- Static repo: 561 debs indexed and hash-matched; all Depends/Pre-Depends were solvable.
- Procursus shadow gate: 128 shadowing packages checked, 55 documented waivers, no violations.

## Package queue

These versions intentionally do not reuse published filenames:

| Package | Version | State |
| --- | --- | --- |
| `iosc` | 0.9.18 | Built, copied to `repo/debs`, indexed, host-audited |
| `xios-launcher-tools` | 0.1.1 | Host payload built and staged; `xmkdeb` blocked on Docker API |
| `xios-session` | 1.0.55 | Script verified; deb assembly pending |
| `iosc-shell` | 0.9.11 | Final stamp rebuild and deb assembly pending |
| `xios-a11y-tools` | 0.2.15 | Source syntax-checked; cross-build/deb pending |
| `libmutter-14-0/-dev` | 46.0+ios3 | Final backend compile, full Mutter build, and debs pending |
| `xios-kde` | 0.1.8 | Control now requires iosc >=0.9.18 and session >=1.0.55; rebuild the stale local candidate before copying it to the repo |
| `ladybird-app` | 0.1.23+ios1 | iOS event-loop TODO/ID-wrap cleanup landed; full engine/app rebuild, host re-sign, and device smoke pending |
| `libgtop-2.0-11` | 2.41.3+ios2 | Built; real Darwin process backend; device smoke pending |
| `xios-session-stubs` | 0.2.5 | Built; persistent AccountsService + stateful BlueZ bridge; device smoke pending |
| `xios-desktop-stublibs` | 0.1.1 | Built; expanded pwquality behavior; device smoke pending |
| `milou` | 6.1.5+ios1 | Built from upstream source with real arm64 QML plugin; device smoke pending |
| `plasma-mobile` | 6.1.5+ios21 | Fully rebuilt; depends on real Milou and contains no Milou fallback; device smoke pending |
| `kwin` / `kwin-dev` | 6.1.5+ios4 | Built; real ANGLE/IOSurface renderer and EGL QPA, arm64/linkage/entitlements verified; device smoke pending |

An unrelated GNOME Docker build was active during the earlier audit and was left untouched. It
was no longer running at final validation; its outcome was not assessed as part of this shim sweep.

## Genuine remaining port work

1. **XFCE:** run the new foundation prefix, fix Darwin portability as port-owned patch series,
   build the full chain, then add a package-owned rootless `xios-session` runner.
2. **GNOME Terminal:** build/package the GTK3 VTE flavor first; GNOME Console is already the
   functional published terminal.
3. **mako/basu:** upstream requires an sd-bus provider. This needs a deliberate sd-bus strategy,
   not another compile flag.
4. **nwg-look:** Go/cgo-to-iOS tooling is unresolved. The recipe is intentionally a blocker
   record, not a pretend build.
5. **Papers:** the Rust-to-iOS toolchain remains the blocker.
6. **Geary/WebKitGTK:** this is still a large browser-engine/toolchain port, not a leaf app fix.
7. **Xwayland WM polish:** `WM_NORMAL_HINTS`, client-requested `_NET_WM_STATE`/activation, and
   fuller resize semantics remain TODOs. Basic mapping/input works; these affect desktop polish.
8. **Ladybird:** host/app engine work is substantially built. The iOS event loop no longer has
   a crash-style notifier TODO or unchecked signal-ID increment; rebuild the reserved 0.1.23+ios1
   app and perform the final package/runtime smoke on-device.

## Intentional shims, not loose ends

- login1 and polkit model a single-user iOS session where there is no systemd/logind stack.
  AccountsService is a persistent single-user bridge, not an all-users placeholder.
- udev/gudev, DRM/KMS, dma-buf, and libei links are inert where IOSurface, UIKit input, or iOS
  frameworks replace the Linux subsystem.
- gsound bridges event sounds without pulling a Linux audio daemon.
- Plasma generated QML compatibility providers are audited against real shipped imports. They
  expose iOS capabilities and reject unsupported mutations; real package implementations take
  ownership when available (as Milou now does).
- BlueZ is a D-Bus compatibility bridge backed by iOS BluetoothManager, not an unfinished Linux
  bluetoothd port.

## Device-only closure queue

The iPad was explicitly offline for this sweep. No runtime claim below has been made from host
evidence alone:

1. Install the queued immutable packages and verify their installed versions/hashes.
2. Exercise KDE `kscreen-doctor` enumerate/scale/rotate and System Settings KScreen against
   `iosc 0.9.18`; confirm fullscreen KWin input remains aligned.
3. Exercise Mutter/GNOME startup sizing and rotation; confirm `xios.json`, the replacement
   IOSurface, stage size, and input ratios agree.
4. Verify native-host two-finger touch and Magic Keyboard trackpad scrolling, including axis-stop
   kinetic behavior.
5. Verify stale-session status changes to `down` after KWin/plasmashell exits.
6. Verify VoiceOver browse focus scrolls offscreen content into view without moving keyboard
   focus; then cover action/adjust/scroll gestures.
7. Smoke XFCE only after the entire package chain and launcher exist.
8. Verify GNOME user-name/icon/language persistence, BlueZ discovery/alias/trust/agent behavior,
   GNOME Console process awareness, pwquality UI policy feedback, and Plasma Mobile Milou search.
9. Launch `kwin +ios4` first in an isolated KDE slot; verify OpenGL compositor selection,
   QtQuick internal windows, client IOSurface import, blur/transparency, rotation, and input
   alignment before making it the shared-session or published baseline.

Production publication is intentionally not part of this offline sweep. Regenerate/audit the
repo again after the queued debs are copied, then publish staging before production.
