# Agent Notes

This repo has two big tracks:

- Top-level jailbreak tweak/app packaging, static APT repo publishing, and small iOS utilities.
- `x11/`, a larger native X11/Wayland-on-iOS desktop stack with its own build system and notes.

Prefer stable instructions here. For fast-moving status, read the relevant README, `x11/docs/handoff/`, and local diffs before acting.

## Before Editing

- Expect a dirty worktree. Do not revert unrelated local changes or generated repo output unless the user explicitly asks.
- Use `rg` / `rg --files` for searches.
- Use `apply_patch` for manual edits.
- Keep rootless iOS assumptions in mind, but check the current README/scripts instead of hardcoding device facts here.

## Top-Level Layout

- `tweaks/`: Theos tweak projects. Each tweak normally has a `Makefile`, `control`, filter plist, and Logos source.
- `apps/`: iOS app projects and app-side artifacts.
- `bin/`: host-side entry points — build, install, simulator, logging, and repo-publish scripts. Repo-pipeline internals (index generator, solvability check, audit) live in `bin/lib/`.
- `repo/`: generated static APT/Sileo repo deployed by Vercel.
- `x11/`: native X11/Wayland/iOS desktop stack. See `x11/AGENTS.md`.
- `jarvis/`: on-device AI assistant (bun agent daemon + web console, runs on the iPad). See `jarvis/AGENTS.md` and `jarvis/docs/PLAN.md`.

## Tweak Workflow

- Build a tweak with `bin/build.sh tweaks/<Name>`.
- Install to the jailbroken device with `bin/install.sh tweaks/<Name>`.
- Watch logs with `bin/logs.sh <needle>`.
- Theos builds should remain rootless unless the user explicitly requests another package scheme.
- When switching package schemes or simulator/device targets, clean first. The helper scripts generally do this where needed.

## Simulator Workflow

- Use `bin/sim.sh tweaks/<Name>` for simulator iteration via simject.
- Simulator work is only a fast loop. Confirm behavior on the jailbroken device before treating a tweak as done.
- Simulator-loaded dylibs must be signed after final file mutations; use the helper script rather than hand-copying when possible.

## Static APT Repo Publishing

- The package repo is generated from `repo/debs/` by `bin/lib/make-repo.py` (repo-pipeline internals live in `bin/lib/`; `bin/` itself holds only entry points).
- `bin/publish-staging.sh` (= `bin/publish-repo.sh --staging`) regenerates, audits, signs, uploads package payloads to Vercel Blob, and deploys the low-cache staging repo (served at dev.repo.maxleiter.com) for iteration.
- `bin/publish-repo.sh` regenerates, audits, signs, uploads package payloads to Vercel Blob, and deploys production metadata/site assets.
- Treat production `.deb` URLs as immutable. Never replace the bytes of a public `.deb` at the same filename; bump the package version or revision so the filename changes.
- Keep APT metadata (`Packages`, `Packages.gz`, `Release`, `InRelease`, `Release.gpg`) revalidated instead of long-lived immutable.
- Keep staging package directories out of Vercel deployments. Do not remove `repo/.vercelignore` entries for staging output unless the publish flow changes deliberately.
- If a publish script fails because `repo/debs` changed during generation/signing, rerun after the active build finishes.
- If a publish script fails during Blob upload because an existing remote `.deb` has a different size, do not overwrite it; bump the package version/revision so the filename changes.

## Publishing: The Procedure

Follow this in order. Every step is safe to rerun.

```bash
bin/build.sh tweaks/<Name>                  # 1. build (or the x11/ build for that package)
cp tweaks/<Name>/packages/*.deb repo/debs/  # 2. stage the payload
bin/publish-staging.sh                      # 3. payloads -> Blob, deploy dev.repo, regenerate repo/Packages
                                            # 4. test on device against dev.repo.maxleiter.com
git add repo/Packages && git commit         # 5. review the diff: it is what step 6 makes public
bin/publish-repo.sh                         # 6. production
```

- **Step 5 is not bookkeeping.** Step 6 publishes the *committed* index, so the diff you commit is exactly the change users receive, and anything uncommitted stays unpublished. `publish-repo.sh` enforces this: a prod publish **refuses to run** while `repo/Packages` differs from `HEAD`.
- **Never run step 6 alone** for a package built on this machine. Step 3 is what uploads the payloads; skipping it publishes an index pointing at 404s.
- Defaults are chosen so the safe thing happens with no flags: **staging rebuilds the index from `repo/debs`** (that is what staging is for), **prod publishes the committed index**. Override with `--from-debs` / `--from-index` when you mean to.
- `--from-index` and `--only` are the two ways to avoid shipping the accumulated tree delta, and they compose: `--only` reconciles against **what the target serves**, `--from-index` publishes **what git says**. With `--only` the drift gate runs `--warn-regressions`, since being behind the target is that mode's premise.
- Publishing needs no network secrets beyond your Vercel login, but it does need the signing key: prod and staging refuse to publish unsigned, checked before any work (`ALLOW_UNSIGNED=1` overrides; `--preview` only warns). An unsigned index makes apt reject the whole repo.

### Why this is not a GitHub Action

The gates that matter need the real `.deb` payloads, which are gitignored and exist only on the authoring host: `check-procursus-shadow.py` (Apple `nm` over Mach-O), DER entitlement re-signing, and the Blob upload. A Linux runner can do none of it, so CI could only ever deploy the metadata half — saving one command in exchange for putting the repo signing key in GitHub secrets. That workflow was written, tested end to end, and deleted on purpose. Don't re-add it without an argument that survives this one.

CI (`.github/workflows/ci.yml`, job `APT index`) validates instead: regenerate from the committed `repo/Packages`, check solvability, audit, and fail on version drift. No secrets, no deploy.

### Guardrails that will stop you

- `make-repo.py` with no `--from-index` **refuses** when `repo/debs` is missing payloads for more than 5% of the index. A worktree always looks like that, because `repo/debs` is gitignored. Use `--from-index`; it regenerates the whole site and index from the committed `Packages` with no payloads at all. (`MAKE_REPO_ALLOW_SHRINK=1` if you truly are retiring packages.)
- A Claude Code PreToolUse hook (`bin/lib/guard-repo-ops.sh`, installed by `bin/setup-repo-guards.sh`) blocks a bare `sync-packages-to-repo.py` — it applies by default and deletes debs — and blocks hand-edits of generated output under `repo/`. Edit the generator or `repo/meta/<pkg>.json` instead.

## Parallel Branches and Version Drift

- `repo/Packages` is the tracked manifest and the single source of truth CI publishes from. Derived siblings (`Packages.gz`, `Release`, `InRelease`, `Release.gpg`, `Packages.pv`, `Packages.sha`) are **gitignored** — `Release` embeds a `Date:` line and the rest are binary, so tracking them made every parallel branch conflict.
- `repo/Packages` merges structurally via the `aptindex` driver (`.gitattributes` -> `bin/lib/merge-packages.py`): newer version per package wins, so two branches publishing different packages never conflict. Register it once per clone with `bin/setup-repo-guards.sh` (shared git config, so worktrees inherit it).
- `bin/lib/check-version-collisions.py` is the drift gate, run by CI and by `publish-repo.sh`. Two failure classes:
  - **collision** — the same `Package`+`Version` is already published with different bytes. Unfixable by merging: the Blob filename is immutable. Bump the version and rebuild.
  - **regression** — the reference index has a newer version than yours, so deploying would roll devices back. Rebase; the merge driver resolves it.
- A worktree that has been open while `main` released will hit *regression*, not silent drift. Rebase before publishing.

## Generated Repo Files

- `repo/Packages`, `repo/Release`, depictions, icons, banners, and signing outputs are generated by the repo tooling.
- Do not hand-edit generated depiction/index files unless you are also updating the generator or intentionally patching an emergency artifact.
- `bin/lib/audit-repo.py` verifies metadata checksums/sizes against deployed package bytes; keep it in the publish path. `--no-payloads` drops exactly the checks that need the payloads, for CI checkouts.
- `bin/lib/make-repo.py` has two modes: default reads `repo/debs/` and regenerates everything including `Packages`; `--from-index` treats the committed `Packages` as authoritative and rebuilds only what derives from it. **Never run the default mode in a worktree with an incomplete `repo/debs/`** — it will silently drop every package whose payload is missing.

## X11 / Xios

- For anything under `x11/`, read `x11/AGENTS.md` first.
- Use `x11/docs/handoff/INDEX.md` and the per-domain handoff docs for current status, open work, and on-device verification notes.
