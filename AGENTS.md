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

## Publishing Stays Local; CI Validates

- **Publishing is a local step and deliberately stays one.** The gates that matter most need the real `.deb` payloads, which are gitignored and exist only on the authoring host: `bin/lib/check-procursus-shadow.py` (Apple `nm` over Mach-O), DER entitlement re-signing, and the Blob upload. A CI runner cannot do any of it, so automating the remaining metadata deploy would buy one command in exchange for putting the repo signing key in GitHub — not a good trade. It was built and then removed on purpose; don't re-add it without a reason that survives that argument.
- CI (`.github/workflows/ci.yml`, job `APT index`) validates the index instead: it regenerates from the committed `repo/Packages`, checks solvability, audits the index, and fails on version drift. No secrets, no deploy.
- Publish with `bin/publish-staging.sh`, then `bin/publish-repo.sh --from-index` for production.
- **Prefer `--from-index` for production.** A bare `publish-repo.sh` regenerates from `repo/debs`, which holds everything anyone has built on the box, so it ships the whole accumulated delta rather than your change. `--from-index` publishes exactly what is committed, which is reviewable in the diff. It skips the payload gates, so the debs must already be in Blob — run the normal staging publish from the tree that built them first.
- `--from-index` and `--only` are the two answers to "don't ship the whole accumulated tree delta", and they compose: `--only` reconciles against **what the target serves**, `--from-index` publishes **what git says**. With `--only`, the drift gate runs `--warn-regressions`, since being behind the target is that mode's premise.
- `publish-repo.sh` refuses to publish prod or staging with no signing key in the keyring, checked up front before it does any work (`ALLOW_UNSIGNED=1` overrides; `--preview` only warns). An unsigned index is not a missing nicety — apt rejects the whole repo.

## Parallel Branches and Version Drift

- `repo/Packages` is the tracked manifest and the single source of truth CI publishes from. Derived siblings (`Packages.gz`, `Release`, `InRelease`, `Release.gpg`, `Packages.pv`, `Packages.sha`) are **gitignored** — `Release` embeds a `Date:` line and the rest are binary, so tracking them made every parallel branch conflict.
- `repo/Packages` merges structurally via the `aptindex` driver (`.gitattributes` -> `bin/lib/merge-packages.py`): newer version per package wins, so two branches publishing different packages never conflict. Register it once per clone with `bin/setup-git-merge-driver.sh` (worktrees inherit it).
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
