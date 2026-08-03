# Public Readiness

Status as of 2026-08-01: the public refs are clean, but one external cleanup
remains. GitHub Support must purge the cached, now-unreachable pre-rewrite
commit before the history cleanup is complete. Everything else on the original
list is done.

## Current Blocker

The old archival branch was deleted after its active descendants had already
been rewritten. No branch, tag, or pull-request ref reaches the old history, but
GitHub still serves the former archival tip directly by commit URL. Ask GitHub
Support to purge that cached view and its unreachable objects, which contain:

- `x11/apps/iosc-shell/design/.sf/SFNS.ttf` — Apple's proprietary San Francisco font
  (redistribution violates Apple's license).
- `x11/docs/x11-coordination-postmortem.zip` — private exported transcript.
- `x11/linux-build/src-tarballs/*.tar`, `*.tar.xz`, `*.tar.gz` — vendored upstream tarballs
  (~84 MB working tree, more in history). Untracked and git-ignored since 2026-07-08; the
  recipes re-fetch them from upstream, so a purge reclaims the pack weight with no source
  loss. Curated header subdirs (`dbus-headers/`, `libei-1.3.0/src/`) stay tracked as build
  inputs — do **not** purge those paths.

The final reachable history passed `git filter-repo --analyze`, a targeted path
scan, and a Gitleaks scan across all public refs. After GitHub confirms the
cache purge, verify that the former archival commit URL returns `404` and mark
this checklist complete.

## Settled

- **License** (2026-07-08): MIT `LICENSE` at the repo root, copyright Max Leiter.
- **Artifact policy**: source, recipes, patches, package skeletons, and docs are tracked.
  Final `.deb`s and generated build outputs are not — `.gitignore` drops `repo/debs/`
  payloads, `x11/wayland/out/`, and the vendored tarball blobs.
- **Site lockfile**: `x11/site/bun.lock` is committed and CI installs with
  `bun install --frozen-lockfile`.

## Package Hosting (live)

Vercel serves the small mutable APT metadata and landing page:

- `repo/Packages`
- `repo/Packages.gz`
- `repo/Release`
- `repo/InRelease`
- `repo/Release.gpg`
- depictions, icons, banners, and the HTML repo index

Use Vercel Blob for `.deb` payloads. This is live:

- Blob store: `xios-debs` (`store_J7LqAmqSi8Q1vMG4`), public, `iad1`.
- Public package URLs are reachable through the `repo.maxleiter.com/debs/*`
  redirect.
- `repo.maxleiter.com/debs/*` and `dev.repo.maxleiter.com/debs/*` redirect to Blob.
- `repo/.vercelignore` excludes `debs/`, so Vercel deployments carry only metadata/site assets.

Why:

- The index has grown past 550 package stanzas, and the payloads behind them are far larger
  than the metadata they are indexed by.
- Vercel CLI static source uploads are limited by plan, and Vercel's documented limit is 100 MB on Hobby and 1 GB on Pro.
- Public Blob storage is designed for public assets and large downloads.
- Vercel recommends treating blobs as immutable, which matches the existing rule that public `.deb` filenames must never be replaced.

How it is wired (done — this is a record, not a runbook):

1. Public Blob store `xios-debs`, payloads at stable `debs/<filename>.deb` pathnames with
   `cache-control-max-age=31536000` and no random suffix, uploaded by
   `bin/upload-debs-to-blob.sh` (set `BLOB_DRY_RUN=1` to preview).
2. `Packages` keeps `Filename: debs/<filename>.deb`; `repo.maxleiter.com/debs/*` redirects to
   the Blob URL for the same pathname. Redirects were chosen over absolute Blob URLs in
   `Filename` so apt, Sileo, Zebra, and Cydia all keep working.
3. `debs/` stays in `repo/.vercelignore`, so deployments carry only metadata and site assets.
4. `bin/publish-repo.sh` / `bin/publish-staging.sh` upload new payloads to Blob before
   deploying signed metadata, and refuse to overwrite a public Blob path whose remote size
   differs from the local package.

To re-verify that every indexed package actually resolves to Blob (the sweep run at cutover
reported `bad=0 not_blob=0`):

```bash
python3 - <<'PY'
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

base = 'https://repo.maxleiter.com/'
files = [line.split('Filename: ', 1)[1]
         for line in Path('repo/Packages').read_text().splitlines()
         if line.startswith('Filename: ')]

def check(path):
    url = base + quote(path, safe='/._-~')
    with urlopen(Request(url, method='HEAD'), timeout=20) as response:
        return path, response.status, response.geturl()

bad = []
not_blob = []
with ThreadPoolExecutor(max_workers=24) as pool:
    for future in as_completed([pool.submit(check, path) for path in files]):
        path, status, url = future.result()
        if status != 200:
            bad.append((path, status))
        elif 'public.blob.vercel-storage.com' not in url:
            not_blob.append((path, url))

print(f'checked={len(files)} bad={len(bad)} not_blob={len(not_blob)}')
PY
```

Do not use a Vercel rewrite/proxy for package downloads unless redirects fail in package managers. A proxy would keep the nice URL, but it routes package bytes through Vercel's request path and is a worse fit for large downloads.

## GitHub Actions Policy

`.github/workflows/ci.yml` runs on PRs and pushes to `main`, and is the whole of CI:

- local-only file guard
- Python syntax checks (`py_compile` over tracked `*.py`)
- shell syntax checks (`bash -n` over tracked `*.sh`)
- package dependency metadata check (`bin/lib/check-repo-solvable.py repo/Packages`)
- Xios site build (`bun install --frozen-lockfile && bun run build`)

Do not deploy production from arbitrary PRs.

Production publication can become a maintainer-only manual workflow later, but it needs explicit secrets and policy:

- `VERCEL_TOKEN`
- `BLOB_READ_WRITE_TOKEN`
- APT signing key material, or a separate signing step before CI
- protection so only trusted maintainers can publish

The current local `bin/publish-repo.sh` flow remains the source of truth for metadata signing and deployment. It uploads new `.deb` payloads to Blob before publishing metadata that references them, and refuses to overwrite a public Blob path when the remote size differs from the local package.

## Public PR Expectations

Public contributors should be able to:

- build and test documentation/site changes
- run syntax and metadata checks
- edit recipes, patches, package skeletons, compositor/app code, and docs
- open PRs without access to Max's iPad, Vercel project, GPG key, or Blob token

Maintainers still need to perform:

- on-device validation
- final package signing
- package upload
- APT repo signing
- production deployment

## Cleanup Backlog

- Decide whether generated repo depictions/icons/banners stay committed or are rebuilt only during publish.
- Decide whether binary package skeleton payloads such as `x11/packages/x11-xvfb/var/jb/usr/bin/Xvfb` and `x11/packages/xios-server/var/jb/usr/bin/Xios` stay as bootstrap artifacts.

The vendored-tarball question is settled (untracked and git-ignored since 2026-07-08; the
recipes fetch from upstream), and the site lockfile now exists — both fold into the history
purge above rather than standing as open decisions.
