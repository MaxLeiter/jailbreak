# Rootless / Rootful / CFVER Migration Plan

This is the implementation plan for moving Xios packaging from today's
rootless-only `/var/jb` target to an explicit target matrix covering rootless,
rootful, and Procursus CFVER variants.

The broader strategy lives in `docs/procursus-monorepo-plan.md`. This file is
the concrete migration checklist and acceptance criteria.

## Current State

- The working target is rootless Procursus:
  - `MEMO_TARGET=iphoneos-arm64-rootless`
  - `MEMO_CFVER=1900`
  - install prefix `/var/jb`
  - package architecture `iphoneos-arm64`
- Most scripts, package payload trees, launchers, runtime sockets, rpaths, and
  maintainer scripts assume `/var/jb`.
- Package metadata now has a minimum-OS story:
  - `linux-build/tools/stamp-minos.py` computes Mach-O and dependency-closure
    `MinimumOSVersion` fields.
  - flavor metas use `firmware (>= ...)` and `MinimumOSVersion`.
- Rootful support is only planned. No rootful artifacts should be published
  until the target matrix, package generation, repo separation, and device smoke
  tests exist.

## Goals

1. Keep the current rootless CFVER 1900 output working throughout the migration.
2. Move target-specific values into data files instead of script literals.
3. Generate package payloads from prefix-aware templates.
4. Publish rootless and rootful outputs into separate repo profiles or suites.
5. Make iOS version support explicit through CFVER targets plus
   `MinimumOSVersion` / `firmware` gates.
6. Add smoke tests that prove install paths, maintainer scripts, binary load
   floors, and launch flows for each supported target.

## Non-Goals For The First Pass

- Legacy 32-bit iOS.
- Non-Procursus bootstraps as first-class targets.
- Full GNOME/KDE/rootful matrix on day one.
- A standalone replacement for Procursus.
- Publishing rootful packages before a real rootful-device validation pass.

## Target Model

Add target descriptors under:

```text
linux-build/targets/
  rootless-1900.env
  rootful-1900.env
```

Initial rootless descriptor:

```sh
target_id=rootless-1900
memo_target=iphoneos-arm64-rootless
memo_cfver=1900
prefix=/var/jb
subprefix=/usr
deb_arch=iphoneos-arm64
repo_profile=rootless
version_suffix=+ios1
package_path_prefix=/var/jb
runtime_tmp=/var/jb/tmp
runtime_var=/var/jb/var
default_min_ios=16.0
```

Initial rootful descriptor:

```sh
target_id=rootful-1900
memo_target=iphoneos-arm64
memo_cfver=1900
prefix=
subprefix=/usr
deb_arch=iphoneos-arm64
repo_profile=rootful
version_suffix=+rootful1
package_path_prefix=
runtime_tmp=/var/tmp
runtime_var=/var
default_min_ios=16.0
```

Open decision: rootful runtime temp may need `/tmp` rather than `/var/tmp`
depending on the target bootstrap. Treat this as a validation item, not a
hardcoded assumption.

## Phase 1: Target Loader

Add a small shell helper, likely `linux-build/target-lib.sh`, that can be sourced
by host and container scripts.

Required behavior:

- `xios_load_target <target-id>` loads exactly one file from
  `linux-build/targets/`.
- It exports normalized values:
  - `XIOS_TARGET_ID`
  - `XIOS_MEMO_TARGET`
  - `XIOS_MEMO_CFVER`
  - `XIOS_PREFIX`
  - `XIOS_SUBPREFIX`
  - `XIOS_DEB_ARCH`
  - `XIOS_REPO_PROFILE`
  - `XIOS_VERSION_SUFFIX`
  - `XIOS_RUNTIME_TMP`
  - `XIOS_RUNTIME_VAR`
- It fails if required keys are missing.
- It rejects unsafe target ids containing path separators.
- Existing scripts default to `rootless-1900` when no target is passed.

First conversions:

- `linux-build/build.sh`
- `linux-build/build-gtk.sh`
- `linux-build/build-iosc.sh` callers where applicable
- `apps/iosc-desktop/package-session.sh`
- `wayland/package-iosc.sh`
- `packages/meta/build-meta.sh`
- `packages/xios-fhs/package-fhs.sh`
- `packages/xios-session-stubs/build.sh`

Current partial implementation:

- `linux-build/target-lib.sh` and `linux-build/targets/*.env` define the initial matrix.
- `linux-build/target-env.sh` is the container-side half of the loader. It turns
  the four values the host exports (`XIOS_MEMO_TARGET`, `XIOS_MEMO_CFVER`,
  `XIOS_PREFIX`, `XIOS_SUBPREFIX`) into the derived paths every build script
  needs -- `XIOS_TRIPLE`, `XIOS_BUILD_BASE/WORK/STAGE/DIST`, `XIOS_SYSROOT`,
  `XIOS_USR`, `XIOS_MEMO_ARGS` -- plus the `xios_require_rootless` and
  `xios_ent_prefix_paths` helpers. It defaults to rootless-1900, so a bare
  `docker run ... /work/build-foo.sh` behaves exactly as it did before the
  matrix existed. It is baked into the toolchain image and bind-mounted by the
  host wrappers, and `xios_load_target` sources it too, so host-side and
  container-side scripts share one vocabulary.
- ~70 build and packaging scripts now resolve their build trees and payload
  roots through those variables instead of literals, including the whole
  Ladybird wave series, KWin/KDE, Qt/KF6, GNOME/mutter, Wayland, GTK, the
  opencode/Bun/fff chain, ANGLE, and the iosc/session/a11y packagers. Where a
  recipe has no rootful story yet -- the Ladybird engine stages the device
  prefix as a container symlink, which rootful cannot do without a `--sysroot`
  pass -- it calls `xios_require_rootless` and stops loudly rather than emitting
  a rootful package full of `/var/jb` paths.
- `packages/build-template-package.sh` renders package templates for both rootless and
  rootful payload roots.
- `packages/templates/x11-fonts-sf/` builds verified rootless/rootful debs with
  target-correct payload roots and no rootless literals in the rootful artifact.
- `packages/x11-xvfb/build.sh` assembles `x11-xvfb` from a target-built `Xvfb`
  binary. It preserves the existing rootless binary fallback, but refuses
  non-rootless packaging until `linux-build/out/targets/<target-id>/Xvfb` exists.
- `packages/xios-server/build.sh` assembles `xios-server` from a target-built
  `Xios` binary. It preserves the existing rootless binary fallback, but refuses
  non-rootless packaging until `linux-build/out/targets/<target-id>/Xios` exists.
- `linux-build/build-xserver-target.sh` is the target-aware entrypoint for
  producing patched X server artifacts (`Xvfb`, and currently also `Xios`) under
  `linux-build/out/targets/<target-id>/`.
- `linux-build/build.sh` renders the `Xios` entitlement path exceptions from
  the selected target prefix, so a rootful build does not generate `/var/jb`
  exceptions in `xios-ent.xml`.
- `apps/iosc-desktop/src/ioscd.c` now derives its temp dir, install prefix,
  helper paths, session/a11y status files, compositor sockets, and launcher-sync
  paths at runtime. Rootless stays on `/var/jb/tmp`; rootful defaults to
  `/var/tmp`.
- `apps/iosc-desktop/src/IOSCLaunch.m` probes both rootless and rootful
  `ioscd.sock` locations, and the launcher/ioscd entitlement files include the
  minimal rootful `/var/tmp` socket exceptions alongside the existing rootless
  exceptions.
- `apps/Xios/Sources/XScreen.swift`, `XiosA11y.swift`, and `XSurface.c` now use
  shared runtime temp/prefix helpers for `xios.json`, app request/status/debug
  files, a11y sockets, iosc input/clipboard sockets, and `.desktop` discovery.
  The checked-in Xcode project and `project.yml` include both rootless and
  rootful dylib rpaths for the app binary.
- `linux-build/build-stublibs.sh` is the host-side target-aware runner for the generated
  GNOME compatibility stublib producers.
- `packages/templates/xios-desktop-defaults/` now covers the full current
  `xios-desktop-defaults` payload, including the target-rendered profile
  snippet, and builds rootless/rootful debs through `packages/build-template-package.sh`.
- `apps/iosc-desktop/package-session.sh` accepts a target id, stages through
  `XIOS_PACKAGE_PATH_PREFIX`, keeps rootless repo copying unchanged, and writes
  rootful artifacts under `linux-build/out/targets/<target-id>/`. Rootless
  `xios-session_1.0.15` has been installed on-device from the target-aware
  artifact; the package declares `Replaces: iosc-shell (<= 0.9.9)` for the moved
  `xios-start-a11y` helper.
- Binary packages with compiled-in rootless paths are target-gated until target-built
  rootful artifacts exist.

Acceptance criteria:

- Existing rootless commands still work without a new argument.
- `XIOS_TARGET=rootless-1900` produces the same effective `MEMO_TARGET`,
  `MEMO_CFVER`, architecture, and install prefix as today.
- A dry-run target dump command prints the resolved values for both rootless and
  rootful.

## Phase 2: Prefix Audit And Constants

Inventory every hardcoded path and classify it:

- Package payload path: must come from target prefix.
- Runtime rendezvous path: should come from target runtime values.
- Device-specific current test path: can stay in handoff docs, not code.
- Rootless-only workaround: should be guarded or removed for rootful.
- Procursus build-cache path: must include `MEMO_TARGET` and `MEMO_CFVER`.

High-risk hardcoded areas:

- `/var/jb/usr/lib` rpaths in build scripts and recipes.
- `/var/jb/tmp/xios.json`, `xios-ddx.sock`, Wayland sockets, and capture output.
- `/var/jb/bin/sh` fixes in X server / Xwayland source patches.
- `/var/jb/var/lib/xkb`, D-Bus machine-id, XDG runtime dirs.
- Entitlement path exceptions for `/var/jb`.
- App-side prefix discovery in Xios.app and host/native modes.

Acceptance criteria:

- Add a checked-in audit file or generated report listing every remaining
  `/var/jb` literal and its classification.
- New package scripts do not add unclassified `/var/jb` literals.
- Rootless-only literals are intentionally marked in comments or target guards.

Status: the report is `docs/rootless-rootful-cfver-audit.md`, regenerated by
`linux-build/tools/audit-target-literals.py`.

The "new scripts do not add literals" criterion is now enforced rather than
asked for. `audit-target-literals.py --fail-on-new` diffs the tree against
`linux-build/tools/target-literal-baseline.json` and fails when any file gains
literals, excluding prose. Between 2026-07-03 and 2026-07-29 the audit went from
1865 hits to 2278 as Ladybird/KDE/konsole landed, which is what the baseline is
there to prevent. Record a deliberate change with `--update-baseline`.

The `build-target` dimension is essentially done: 275 hits -> 16, and those
remaining are the intentional `${XIOS_MEMO_TARGET:-iphoneos-arm64-rootless}`
defaults plus the auditor's own literal table. The `/var/jb` dimension is
partly done -- payload roots in the deb-producing scripts are converted, while
device-side runtime scripts (`bin/*-up.sh`, `wayland/run-*.sh`, the
`gir-*-ondevice.sh` family) still hardcode the rootless prefix and should adopt
the runtime probe the app-side code already uses.

## Phase 3: Package Templates

Move committed rootless payload trees toward templates under:

```text
packages/templates/
  xios-server/
  x11-xvfb/
  x11-fonts-sf/
  xios-desktop-defaults/
  xios-session/
  iosc/
  xios-fhs/
  xios-session-stubs/
  meta/
```

Template conventions:

- Use `@PREFIX@`, `@SUBPREFIX@`, `@RUNTIME_TMP@`, `@RUNTIME_VAR@`,
  `@DEB_ARCH@`, `@VERSION@`, and `@MIN_IOS@`.
- Keep files stored relative to the logical prefix where possible:
  `files/usr/bin/foo` becomes `/var/jb/usr/bin/foo` for rootless and
  `/usr/bin/foo` for rootful.
- Generate staging directories under `linux-build/stage/<target-id>/<package>/`.
- Never publish from a staging directory directly. Package first, then copy the
  final deb into the correct repo profile input directory.

First package set:

1. `x11-fonts-sf` - template flow verified for rootless/rootful.
2. `x11-xvfb` - rootless package assembly verified; rootful package is guarded
   pending a target-built rootful `Xvfb` from `linux-build/build-xserver-target.sh`.
3. `xios-server` - rootless package assembly verified; rootful package is
   guarded pending a target-built rootful `Xios` from `linux-build/build-xserver-target.sh`.
4. `xios-desktop-defaults` - template flow completed for rootless/rootful;
   rootful package has no `/var/jb` payload paths or rendered script literals.
5. `xios-session` - target-aware package flow implemented; bundled session
   launch wrappers now derive runtime prefix/temp/lib paths from install
   location or explicit `XS_*` overrides. Rootless package install and iosc
   session smoke are validated on-device.
6. `iosc` / `ioscd` / `Xios.app` - runtime path audit started. `ioscd`, the
   generated launcher stub, the legacy Xios/Xvfb run scripts, and the Xios app
   display/a11y/status paths are now adaptive for rootless/rootful. Remaining
   hits are mostly explicit rootless candidate paths, rpath compatibility, media
   bridge sockets, and generated/project metadata.

Acceptance criteria:

- Generated rootless packages match the existing payload paths.
- Rootful generated packages contain no `/var/jb` payload paths unless the file
  is documentation describing rootless.
- Maintainer scripts are generated with target-correct paths.
- `dpkg-deb -c` and `dpkg-deb -I` snapshots are stored for review.

## Phase 4: Rootful Smoke Target

Start with the smallest useful rootful set:

- `x11-fonts-sf`
- corrected `tigervnc-standalone-server`
- `x11-xvfb`
- `xios-server`
- `iosc` only after compositor runtime paths are target-aware

Rootful-specific fixes likely needed:

- Shell path patch should resolve to `$(MEMO_PREFIX)/bin/sh`; for rootful that is
  `/bin/sh`.
- Entitlements need rootful path exceptions or no rootless path exception.
- Launcher scripts must use `/usr/bin`, `/usr/lib`, `/var/lib`, and target temp
  paths.
- Xios.app must locate rootful config/socket locations or receive them through
  an app config file.

Acceptance criteria:

- Rootful packages build under `MEMO_TARGET=iphoneos-arm64`.
- Rootless and rootful debs cannot collide in the same repo input directory.
- A rootful install smoke test verifies:
  - package installs cleanly with `dpkg -i`
  - expected files land under `/usr` / `/var`
  - XKB helper path is correct
  - server starts far enough to produce status/log output

## Phase 5: Repo Profiles

Split publishing inputs and metadata by target profile.

Candidate layout:

```text
repo/profiles/rootless/debs/
repo/profiles/rootful/debs/
repo/profiles/rootless/Packages
repo/profiles/rootful/Packages
```

or separate published paths:

```text
https://repo.maxleiter.com/rootless ./
https://repo.maxleiter.com/rootful ./
```

Required generator changes:

- `bin/lib/make-repo.py --profile rootless`
- `bin/lib/make-repo.py --profile rootful`
- profile-specific depictions and package indexes
- profile-specific install instructions
- audit guard that refuses mixed rootless/rootful packages in one flat profile

Acceptance criteria:

- Existing rootless publish flow remains available.
- Rootful publish flow can generate metadata locally but is blocked from
  production until device validation passes.
- Repo audit catches package/version/architecture collisions across profiles.

## Phase 6: CFVER Matrix

Treat CFVER as a target dimension, not just an iOS marketing version.

Add target descriptors as needed:

```text
rootless-1800.env
rootless-1900.env
rootful-1700.env
rootful-1900.env
```

Policy:

- A target is supported only if there is a matching Procursus dist/bootstrap and
  a tested dependency closure.
- `MinimumOSVersion` is the binary/dependency load floor.
- `firmware (>= X.Y)` is the package-manager gate for a flavor.
- CFVER selection decides which Procursus dependency universe we build against.

Acceptance criteria:

- Target descriptor names encode bootstrap profile and CFVER.
- Builds use the descriptor's `MEMO_CFVER` everywhere.
- Flavor package `firmware` and `MinimumOSVersion` are generated from the
  dependency-closure output, not edited by hand.

## Phase 7: Desktop Stack Expansion

After server/core packages work on rootful, expand the matrix in this order:

1. Wayland base: `wayland`, `wayland-protocols`, `libxkbcommon`,
   `epoll-shim`, `iosc`.
2. X compatibility: Xwayland, X11 libs, font/XKB stack.
3. GTK3/GTK4 and app utilities.
4. XFCE/lightweight desktop path.
5. GNOME session path.
6. KDE/Qt path.

Do not start with GNOME/KDE rootful; they have too many hardcoded paths and
runtime service assumptions to be the first validation surface.

Acceptance criteria:

- Each expansion step has a package closure report.
- Each step has at least one device smoke test per target.
- Any target-specific recipe exception is documented next to the recipe or in
  the target audit report.

## Phase 8: Validation Harness

Add scriptable smoke tests that can run locally and on device.

Local checks:

- target descriptor lint -- `linux-build/tools/lint-targets.sh`. Every
  descriptor must load, expose the full variable set, name itself
  `<repo_profile>-<memo_cfver>`, keep `package_path_prefix` equal to `prefix`,
  and agree with its `MEMO_TARGET` about whether it is rootless.
- no unclassified rootless literals in generated rootful packages -- and the
  matching control/payload checks below, all in
  `linux-build/tools/check-target-package.py`, which takes a staged root or a
  built `.deb` plus a target id and verifies payload paths sit under the
  target's prefix, no other target's prefix appears in payload paths, no
  foreign prefix appears inside maintainer scripts or shipped text, and
  `DEBIAN/control` Architecture matches the descriptor.
  `packages/build-template-package.sh` runs it on every staged tree, for
  rootless as well as rootful.
- no new rootless literals anywhere -- `audit-target-literals.py --fail-on-new`.
- `dpkg-deb -I` control fields match target -- covered by the Architecture check.
- `dpkg-deb -c` payload paths match target -- covered by the payload path check.
- Mach-O `LC_BUILD_VERSION` floors are reflected in `MinimumOSVersion` -- still
  only `tools/stamp-minos.py`, not yet asserted by a check.
- dependency-closure floor JSON is reproducible -- not started.

Device checks:

- install package set
- verify executable bits and signatures
- run `xios-session status` where applicable
- start Xvfb/Xios/iosc smoke command
- collect logs from target runtime temp
- uninstall or leave a documented cleanup command

Acceptance criteria:

- Rootless smoke tests pass on the current iPad before any rootful migration is
  considered complete.
- Rootful smoke tests must pass on a real rootful Procursus device before
  rootful repo publication is enabled.

## Suggested Work Order

1. Add target descriptors and `target-lib.sh`.
2. Add a literal audit script/report for `/var/jb`, `/var/jb/usr`,
   `/var/jb/tmp`, and `iphoneos-arm64-rootless`.
3. Convert one low-risk package to templates: `x11-fonts-sf`.
4. Convert one binary package: `x11-xvfb`.
5. Convert `xios-server` and make DDX socket/config paths target-aware.
6. Convert ioscd / Xios.app runtime socket/config/status paths to adaptive
   rootless/rootful handling.
7. Add repo profile plumbing in dry-run mode.
8. Build rootless packages from templates and compare against current packages.
9. Add rootful target generation, but keep publish blocked.
10. Validate rootful server/font smoke set on hardware.
11. Expand to Wayland/iosc, then desktop stacks.

## Publication Gates

Rootless profile can publish when:

- generated rootless packages install and launch at parity with current packages
- repo audit passes
- current iPad smoke evidence is captured

Rootful profile can publish when:

- rootful package set is generated from templates
- no rootless payload paths leak into rootful packages
- rootful metadata lives in a separate profile/suite
- a real rootful Procursus device has passed install and launch smoke tests

Additional CFVER targets can publish when:

- the target has a descriptor
- Procursus dependency closure resolves for that CFVER
- `MinimumOSVersion` / `firmware` gates are generated
- target-specific smoke tests pass

## Open Decisions

- Should rootful versions carry `+rootful1`, or should profile separation be the
  only namespace boundary?
- Xios.app is now moving toward one adaptive binary that discovers rootless
  `/var/jb` and otherwise uses rootful paths.
- Rootful compositor/app rendezvous currently uses `/var/tmp`, matching
  `linux-build/targets/rootful-1900.env`; keep validating this on hardware.
- Should repo profile metadata live under top-level `repo/` or under `X11/` and
  be copied out by publish scripts?
- How much generated package staging should be committed versus treated as
  build output?

## Immediate Next Patch After This Plan

Phase 1's skeleton, the container-side loader, the script conversion, and the
local half of Phase 8 are done. The next patch is the first genuinely rootful
artifact, which is what unblocks Phases 3-5:

1. Teach `linux-build/build-xserver-target.sh` to produce
   `linux-build/out/targets/rootful-1900/Xvfb`. Everything around it already
   exists: the wrapper passes the target through, `packages/x11-xvfb/build.sh`
   consumes it, and the `targets` gate drops away once the binary is there.
   This needs no rootful hardware -- `dpkg-deb -c` plus
   `tools/check-target-package.py` tell you whether the deb is right.
2. Same for `Xios` -> `packages/xios-server/build.sh`.
3. Then Phase 5 repo profiles, so the two never share an input directory.

Running the local gate:

```sh
bash x11/linux-build/tools/lint-targets.sh
python3 x11/linux-build/tools/audit-target-literals.py --fail-on-new
python3 x11/linux-build/tools/check-target-package.py <staged-root-or-deb> <target-id>
```

Still rootless-only, in rough priority order:

- Device-side runtime scripts (`bin/x11-up.sh`, `bin/xfce-up.sh`,
  `wayland/run-*.sh`, `apps/iosc-desktop/install-*.sh`, the
  `gir-*-ondevice.sh` family). These run on the iPad, so they want the same
  runtime probe `ioscd.c` and `XScreen.swift` use, not a build-time value.
- `linux-build/recipes/*.mk` and `recipes/*-ios-fixes.sh`, which bake paths into
  packages at recipe level.
- The legacy committed payload trees under `packages/*/var/jb/`, superseded by
  `packages/templates/` but not yet deleted.
- Entitlement XML files, which need a rootful review before rootful signing.
