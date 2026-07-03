# Procursus Overlay Monorepo Plan

Plan for making this repo the single source of truth for the X11/iOS distribution while
still using Procursus as the upstream build system, dependency graph, and bootstrap
compatibility layer.

## Decision

Use a hybrid model:

- **Build off Procursus** for the toolchain, base packages, target metadata, packaging
  conventions, and bootstrap-specific install prefixes.
- **Self-host the distribution**: our repo owns the overlay recipes, patches, app code,
  package templates, target matrix, generated apt repo, smoke tests, and docs.
- **Do not fully fork or replace Procursus yet**. A fully standalone toolchain would be
  possible, but it would move too much surface area onto us before we have rootless/rootful
  variants and Xios stabilized.

The practical goal is a monorepo that can diverge locally when needed, then rebase or
resync from Procursus deliberately.

## Why Not Full Self-Host Yet

LLMs make recipe authoring and patch wrangling cheaper, but they do not remove the hard
parts:

- iOS sysroot and Darwin cross-linking details
- rootless vs rootful prefix behavior
- `libiosexec`, dyld, rpaths, and ad-hoc signing conventions
- Procursus package names and dependency closure
- CFVER and firmware-version compatibility
- dpkg metadata, maintainer scripts, triggers, and repo publishing
- real on-device validation

Procursus already solved much of the boring substrate. Rebuilding that now would slow the
actual product work: Xvnc/Xvfb, Xios, GTK/XFCE/GNOME, and eventually the per-window
compositor.

## Goals

1. **One repo owns the product.**
   Everything specific to X11-on-iOS lives here: patched packages, custom recipes, Xios,
   package templates, launchers, repo metadata, and test scripts.

2. **Upstream sync is explicit and repeatable.**
   We pin Procursus to a known commit, apply local overlays in a deterministic order, and
   make drift visible when upstream changes.

3. **Local divergence is easy.**
   A package can be overridden without editing a live Procursus checkout by hand. The overlay
   should support replacing makefiles, patching makefiles, adding build_info controls, and
   injecting source patches.

4. **Target variants are first-class.**
   Rootless `/var/jb`, rootful `/`, and CFVER variants should be build targets, not one-off
   script edits.

5. **Published repos are safe to consume.**
   Rootless and rootful packages with the same Debian architecture must not collide in one
   flat apt namespace.

## Non-Goals

- Replacing Procursus's full package universe.
- First-class support for every non-Procursus bootstrap in the first pass.
- Legacy 32-bit support.
- Building every desktop package for every target before the server path is proven.

## Proposed Layout

Keep the current repo shape, but make the build inputs more structured:

```text
x11/
  apps/
    Xios/
  docs/
  linux-build/
    Dockerfile
    build.sh
    build-gtk.sh
    build-gnome.sh
    build-wayland.sh
    targets/
      rootless-1900.env
      rootful-1900.env
    overlay/
      procursus.lock
      makefiles/
      build_info/
      patches/
      scripts/
  packages/
    templates/
      x11-fonts-sf/
      x11-xvfb/
      xios-server/
      xfce4/
  ports/
    tigervnc/
    mozjs/
  repo/
    profiles/
      rootless/
      rootful/
  tests/
```

This can be incremental. The immediate value comes from adding `targets/`, moving manual
package trees toward templates, and pinning Procursus.

## Upstream Model

Use a pinned upstream Procursus checkout, not an untracked floating clone.

Minimum viable form:

```text
linux-build/overlay/procursus.lock
```

Example contents:

```text
repo=https://github.com/ProcursusTeam/Procursus.git
commit=<known-good-sha>
```

The build scripts should:

1. Clone or update Procursus to exactly that commit.
2. Refuse to build if the checkout has uncommitted local edits.
3. Apply our overlay idempotently.
4. Emit a short overlay report: files replaced, files patched, controls added, source
   patches installed.

Later, add:

```bash
./linux-build/sync-procursus.sh --to <new-sha>
```

That script should update the lock, re-apply overlays, and report failed anchors or changed
upstream files.

## Overlay Types

Support four kinds of local divergence:

1. **Additive recipes**
   New package makefiles copied into `Procursus/makefiles/`, plus matching control files
   copied into `Procursus/build_info/`.

2. **Replacement recipes**
   Whole makefiles that intentionally replace an upstream recipe, for example a local
   `libepoxy.mk` with EGL/ANGLE behavior.

3. **Patch injections**
   Small edits to upstream makefiles using stable anchors. These should fail loud if an
   anchor disappears.

4. **Source patches**
   Quilt-style patch series under `ports/<pkg>/patches/`, mirrored into Procursus build
   patch locations during build.

The overlay report should distinguish these so an upstream sync can be reviewed quickly.

## Target Matrix

Move the hardcoded values out of scripts:

```text
target_id=rootless-1900
memo_target=iphoneos-arm64-rootless
memo_cfver=1900
prefix=/var/jb
subprefix=/usr
repo_profile=rootless
version_suffix=+rootless1
```

Rootful example:

```text
target_id=rootful-1900
memo_target=iphoneos-arm64
memo_cfver=1900
prefix=
subprefix=/usr
repo_profile=rootful
version_suffix=+rootful1
```

Every build entry point should accept a target:

```bash
./linux-build/build-target.sh rootless-1900 tigervnc-package
./linux-build/build-target.sh rootful-1900 x11-xvfb-package
```

The old scripts can remain as wrappers around the default rootless target until the matrix
is stable.

## Package Generation

The current package payloads are rootless-specific because they contain files under
`/var/jb`. Replace committed payload trees with package templates and generated staging.

For example:

```text
packages/templates/xios-server/
  control.in
  postinst.in
  files/
    usr/bin/xios-server.sh.in
```

The packager receives `prefix`, `subprefix`, target id, version suffix, and built binaries,
then emits the correct filesystem tree:

- rootless: `/var/jb/usr/bin/Xios`
- rootful: `/usr/bin/Xios`

The same applies to maintainer scripts:

- rootless: `mkdir -p /var/jb/var/lib/xkb`
- rootful: `mkdir -p /var/lib/xkb`

## Xios Portability

Xios needs a small portability layer before rootful or relocated bootstraps are clean.

Server side:

- Add `-xios-socket <path>` and `-xios-config <path>` to the DDX, or equivalent env vars.
- Stop hardcoding `/var/jb/tmp/xios-ddx.sock` and `/var/jb/tmp/xios.json`.
- Keep defaults target-specific in the launcher.

App side:

- Derive candidate prefixes at runtime: `/var/jb`, `/`, and later relocated jbroot paths.
- Read config/socket paths from a small app config file or scan known locations.
- Avoid a single baked `/var/jb/usr/lib` rpath if rootful support becomes first-class.

Launcher side:

- Move `W/H/DPI` defaults into target/device config.
- Keep user overrides via env vars.
- Add a small `xios-detect-geometry` helper later if needed.

## Repo Publishing

Do not publish rootless and rootful packages with the same package/version/architecture in
one flat repo.

Use one of these:

```text
https://repo.maxleiter.com/rootless ./
https://repo.maxleiter.com/rootful ./
```

or:

```text
Suites: rootless
Suites: rootful
```

The repo generator should take a profile:

```bash
./bin/lib/make-repo.py --profile rootless
./bin/lib/make-repo.py --profile rootful
```

Each profile owns its package input directory, `Packages`, `Release`, depictions, and
published install instructions.

## Rehosted Dependencies

Keep rehosting runtime dependencies, but tie them to target profiles:

- rootless Procursus deps from `iphoneos-arm64-rootless` / CFVER 1900
- rootful Procursus deps from `iphoneos-arm64` / matching CFVER

Rehosted packages should be marked as imported, not edited. If we need to patch one, it
graduates into our overlay recipes.

## Sync Workflow

Normal development:

```bash
./linux-build/build-target.sh rootless-1900 tigervnc-package
./linux-build/package-target.sh rootless-1900 xios-server
./bin/lib/make-repo.py --profile rootless
```

Upstream sync:

```bash
./linux-build/sync-procursus.sh --to <new-sha>
./linux-build/build-target.sh rootless-1900 smoke
./linux-build/build-target.sh rootful-1900 smoke
```

Review output should answer:

- Did any overlay anchors fail?
- Did any replacement recipe now conflict with upstream?
- Did package dependency names change?
- Did generated payload paths change?
- Did smoke tests pass on device?

## Milestones

### M1: Pin and report

- Add `procursus.lock`.
- Make clone/update honor the pin.
- Emit an overlay report.
- Keep current rootless behavior unchanged.

### M2: Target matrix

- Add `rootless-1900.env`.
- Replace hardcoded `MEMO_TARGET=iphoneos-arm64-rootless` and `MEMO_CFVER=1900` in build
  scripts with target loading.
- Keep old commands as compatibility wrappers.

### M3: Generated packages

- Convert `x11-fonts-sf`, `x11-xvfb`, `xios-server`, and `xfce4` to templates.
- Generate rootless packages from templates.
- Verify byte-level install paths and maintainer scripts.

### M4: Rootful smoke target

- Add `rootful-1900.env`.
- Build only the server/font set first:
  `x11-fonts-sf`, `tigervnc-standalone-server`, `x11-xvfb`, `xios-server`.
- Publish to a separate rootful repo profile.
- Validate install and launch on a real rootful Procursus device.

### M5: Desktop stack matrix

- Bring GTK/XFCE/GNOME recipes onto the target matrix.
- Fix recipe exceptions such as hardcoded `/var/jb` ANGLE/libepoxy paths.
- Add smoke tests per target before publishing.

## Open Questions

- Should rootful packages carry `+rootful1` revisions or live entirely in a separate suite
  with unchanged versions?
- Should Xios app be one adaptive binary or separate rootless/rootful builds?
- How much of the repo generator should live inside `x11/` versus the parent jailbreak
  workspace?
- Do we want a local mirror of Procursus source tarballs for long-term reproducibility?

## Recommendation

Start with M1-M3. That gives us the monorepo feel, cheap divergence, and deterministic
upstream sync without committing to the full rootful or non-Procursus matrix immediately.
Once package generation is target-aware, rootful becomes a controlled build and validation
problem instead of a manual fork of the tree.
