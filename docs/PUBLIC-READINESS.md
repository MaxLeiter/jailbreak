# Public Readiness

Status as of 2026-07-03: close, but not ready to make public without cleanup.

## Current Blockers

1. Choose and commit a `LICENSE`. Without it, people can read the code but should not treat it as open source.
2. Purge copied proprietary assets and private exported transcripts from history before making an existing private repository public. The tracked `x11/apps/iosc-shell/design/.sf/SFNS.ttf` file and `x11/docs/x11-coordination-postmortem.zip` have been removed from the index in the public-prep pass, but if the repository history is preserved, remove them with `git filter-repo` or publish from a clean new history.
3. Decide the long-term artifact policy. Source, recipes, patches, package skeletons, and docs belong in Git. Final `.deb`s and generated build outputs should not; the current index removes `repo/debs/` package payloads and `x11/wayland/out/` generated binaries.

## Package Hosting Recommendation

Use Vercel for the small mutable APT metadata and landing page:

- `repo/Packages`
- `repo/Packages.gz`
- `repo/Release`
- `repo/InRelease`
- `repo/Release.gpg`
- depictions, icons, banners, and the HTML repo index

Use Vercel Blob for `.deb` payloads. This is live:

- Blob store: public package payload store configured in Vercel.
- Public package URLs are reachable through the `repo.maxleiter.com/debs/*`
  redirect.
- `repo.maxleiter.com/debs/*` and `dev.repo.maxleiter.com/debs/*` redirect to Blob.
- `repo/.vercelignore` excludes `debs/`, so Vercel deployments carry only metadata/site assets.

Why:

- The local package repo currently has 441 `.deb`s and `repo/debs` is about 318 MB.
- Vercel CLI static source uploads are limited by plan, and Vercel's documented limit is 100 MB on Hobby and 1 GB on Pro.
- Public Blob storage is designed for public assets and large downloads.
- Vercel recommends treating blobs as immutable, which matches the existing rule that public `.deb` filenames must never be replaced.

Migration runbook:

1. Create a public Blob store for package payloads.
   ```bash
   cd repo
   vercel blob create-store xios-debs --access public
   vercel env pull
   ```
2. Upload every package to stable pathnames such as `debs/<filename>.deb` with `cache-control-max-age=31536000` and no random suffix.
   ```bash
   BLOB_DRY_RUN=1 bin/upload-debs-to-blob.sh
   bin/upload-debs-to-blob.sh
   ```
3. Keep `Filename: debs/<filename>.deb` in `Packages`.
4. Configure `repo.maxleiter.com/debs/*` to redirect to the public Blob URL for the same pathname. Prefer redirects over changing `Filename` to absolute Blob URLs until apt, Sileo, Zebra, and Cydia behavior is verified.
5. Keep `debs/` in `repo/.vercelignore` so Vercel deploys only metadata and site assets.

Validation used for the cutover:

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

Use Actions for PR validation:

- local-only file guard
- Python syntax checks
- shell syntax checks
- package dependency metadata checks
- Xios site build

Do not deploy production from arbitrary PRs.

Production publication can become a maintainer-only manual workflow later, but it needs explicit secrets and policy:

- `VERCEL_TOKEN`
- `BLOB_READ_WRITE_TOKEN`
- APT signing key material, or a separate signing step before CI
- protection so only trusted maintainers can publish

The current local `bin/publish-repo.sh` flow remains the source of truth for metadata signing and deployment. New `.deb` payloads must be uploaded to Blob before publishing metadata that references them.

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
- Decide whether vendored source tarballs under `x11/linux-build/src-tarballs/` stay committed or move to documented fetch steps.
- Decide whether binary package skeleton payloads such as `x11/packages/x11-xvfb/var/jb/usr/bin/Xvfb` and `x11/packages/xios-server/var/jb/usr/bin/Xios` stay as bootstrap artifacts.
- Add a lockfile for `x11/site` if reproducible site builds matter for CI.
- Run a history scan before public launch: `gitleaks`, `git filter-repo --analyze`, or an equivalent secret/artifact audit.
