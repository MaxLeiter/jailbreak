# Contributing

This repository is being prepared for public development. It has two tracks:

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

## Validation

Before sending a PR, run the narrowest checks that apply:

```bash
git ls-files '*.sh' | xargs -n1 bash -n
python3 -m py_compile $(git ls-files '*.py')
python3 bin/lib/check-repo-solvable.py repo/Packages
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
