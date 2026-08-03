# Contributing

This repository is open for public development. It has two tracks:

- top-level jailbreak tweaks, apps, package-repo tooling, and small iOS utilities
- `x11/`, the Xios/X11/Wayland desktop stack and its Procursus/Docker build system

Start with `README.md`, then read `x11/README.md` and `x11/AGENTS.md` for Xios work.
Fast-moving status lives in `x11/docs/handoff/`.

## Before Opening a PR

- Keep changes focused. Separate code, packaging, generated repo output, and docs when practical.
- Do not commit local secrets, `.env` files, device hostnames beyond documented examples, Vercel project state, signing keys, certificates, provisioning profiles, or copied proprietary Apple assets.
- Do not commit `.deb` files or generated package outputs unless a maintainer explicitly asks for a release artifact change.
- Use the existing scripts instead of reconstructing signing, deployment, or Procursus commands by hand.
- For `x11/`, keep rootless `/var/jb` assumptions unless the change is explicitly target-aware.

## Local Development

Most code can be edited and syntax-checked without a jailbroken device. Runtime verification still matters for UIKit, IOSurface, Metal, launchd, package installation, and compositor input paths.

Useful entry points:

```bash
bin/build.sh tweaks/<Name>
bin/install.sh tweaks/<Name>
bin/publish-staging.sh
bash x11/linux-build/run.sh
x11/wayland/build-iosc.sh
```

`device.env` at the repo root is intentionally ignored. Use it for local `THEOS_DEVICE_IP`, `THEOS_DEVICE_PORT`, and related deployment overrides.

One-time setup per clone, so `repo/Packages` merges instead of conflicting:

```bash
bin/setup-repo-guards.sh
```

## Publishing Packages

Publishing is local. The steps that matter — uploading payloads to Blob, DER-signing the graphics packages, and the Procursus shadow gate — all need the real `.deb` files, which never leave the machine that built them.

```bash
bin/publish-staging.sh                 # payloads to Blob + deploy dev.repo.maxleiter.com
git add repo/Packages && git commit    # review the diff: it is what goes public
bin/publish-repo.sh                    # production
```

Committing `repo/Packages` is part of the procedure, not paperwork: production publishes the committed index, so the diff you commit is the change users receive. A prod publish refuses to run while `repo/Packages` differs from `HEAD`, and staging is what uploads the payloads — so never run the production step alone for something you just built.

(`--only pkg[,pkg]` scopes a publish differently: it starts from the index the target already serves and swaps in just the named packages.)

CI does not publish. It validates the index on every PR — regenerates it from the committed `repo/Packages`, checks solvability, audits, and fails on version drift.

Working in a worktree while `main` releases no longer drifts silently. `repo/Packages` merges structurally (newer version per package wins), and `bin/lib/check-version-collisions.py` fails the build if you would either reuse a published version with different bytes (bump it — Blob filenames are immutable) or publish an index behind what is already live (rebase).

## Validation

Before sending a PR, run the narrowest checks that apply:

```bash
git ls-files '*.sh' | xargs -n1 bash -n
python3 -m py_compile $(git ls-files '*.py')
python3 bin/lib/check-repo-solvable.py repo/Packages
python3 bin/lib/audit-repo.py --no-payloads
python3 bin/lib/check-version-collisions.py --against https://repo.maxleiter.com/Packages
```

For the Xios site:

```bash
cd x11/site
bun install --frozen-lockfile
bun run build
```

If a change affects device runtime behavior, include the device smoke test you ran. If you could not test on-device, say so clearly in the PR.

## Package Publishing

Production package publishing is maintainer-controlled. PRs should not deploy to Vercel, upload to Blob storage, rotate the APT signing key, or replace public `.deb` bytes. Public package filenames are immutable; bump the package version or revision instead.

## License

This project is MIT licensed; see [`LICENSE`](LICENSE). Contributions are accepted under the same terms.

Note that this applies to the code in this repository only. Vendored upstream sources and patches carry their own upstream licenses, and no Apple-proprietary asset may be committed (see `docs/PUBLIC-READINESS.md`).
