# Upstream dependency updates

The source versions in `linux-build/recipes/` are the authoritative dependency
inventory. Run this from `x11/` for the live report:

```bash
python3 linux-build/tools/audit-upstream-versions.py --refresh
```

For a Markdown artifact (also produced by the scheduled GitHub workflow):

```bash
python3 linux-build/tools/audit-upstream-versions.py \
  --format markdown --output /tmp/xios-upstream-versions.md
```

The auditor reads recipe assignments and official upstream archive indexes or
git tags. It has no PyPI dependency. Results are cached for six hours under
`~/.cache/xios-upstream-versions`; `--refresh` bypasses the cache.

## Reading the report

- `update`: a newer stable version exists inside the maintained track. This is
  the normal update queue.
- `held`: a newer candidate exists, but the policy records a toolchain, ABI, or
  cohort reason not to bump it alone.
- `track-current`: the maintained line is current, while a newer upstream line
  exists. This makes deliberate lag visible without turning it into noise.
- `unknown`: the recipe pin has no source resolver yet, or upstream could not be
  reached. Unknowns are work items; do not read them as current.

Exceptional tracks and holds live in
`linux-build/upstream-version-policy.json`. Keep each hold narrow and include a
real reason. A permanent unreviewed ignore defeats the inventory.

## Update procedure

1. Refresh the report and select one leaf package or one declared cohort.
2. Read upstream release notes, ABI/toolchain changes, and security notices.
3. Bump the upstream version variable, leaving the upstream source version free
   of the `+iosN` package revision marker.
4. Rebase every `ports/<pkg>/patches/series` patch against the exact new archive.
   Do not convert failed patches into inline recipe mutation.
5. Remove that package's stale `build_work` and stage entries, then build its
   specialized lane. The shared named Docker volume is a cache, not proof that
   the new source compiled.
6. Inspect the produced package version, Mach-O dependencies, rootless paths,
   entitlements, and dependency closure. If it shadows Procursus, run the
   top-level `bin/lib/check-procursus-shadow.py` gate before device rollout.
7. Publish to staging, test the affected runtime on the iPad, and only then
   publish the immutable versioned payload to production.

Desktop stacks move as cohorts:

- GNOME applications/libraries follow their recipe's declared source series;
  Mutter, Shell, GJS, SpiderMonkey, and GTK are one integration lane.
- Qt, KDE Frameworks, Plasma, and KDE release-service applications move as one
  ABI/tooling lane.
- WebKitGTK is held on the newest C++20-compatible line until the cross compiler
  lane advances.
- Procursus-shadowing libraries must remain drop-in supersets even when a newer
  upstream release exists.

The weekly workflow is informational: it never rewrites recipes, packages, or
the APT index. That keeps an upstream release from bypassing cross-build and
physical-device proof.
