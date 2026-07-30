#!/usr/bin/env python3
"""Scope a generated APT index down to a few packages, for a one-package publish.

The repo tree is the STAGING state: repo/debs holds everything we have ever built,
and make-repo.py indexes all of it. Publishing to prod from that tree therefore
ships every accumulated delta, not the one package you meant. The documented
workaround used to be moving other people's debs out of repo/debs, regenerating,
publishing, then putting them back -- which races any concurrent publish and, if
it dies halfway, leaves the tree misindexed.

This does it without touching the tree. Given the index the target is ALREADY
serving, it keeps every stanza as published and replaces (or adds) only the named
packages from the freshly generated local index. Everything else on the target
stays byte-identical to what it was, including packages whose debs are no longer
on this machine, because their stanzas are reused verbatim rather than recomputed.

Writes Packages, Packages.gz and Release into --repo (a deploy staging copy, not
the working tree). Sign after this, not before: the Release hashes change.

  scope-index.py --repo <deploy>/repo --live https://repo.maxleiter.com/Packages \\
                 --only iosc,xios-session
"""
import argparse
import email.utils
import gzip
import hashlib
import os
import sys
import urllib.request


def parse_stanzas(text):
    """[(package_name, stanza_text)] in file order. Blank-line separated."""
    out = []
    for chunk in text.replace("\r\n", "\n").split("\n\n"):
        chunk = chunk.strip("\n")
        if not chunk.strip():
            continue
        name = None
        for line in chunk.split("\n"):
            if line.startswith("Package:"):
                name = line.split(":", 1)[1].strip()
                break
        if not name:
            print("scope-index: skipping a stanza with no Package: field", file=sys.stderr)
            continue
        out.append((name, chunk))
    return out


def field(stanza, key):
    for line in stanza.split("\n"):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="deploy copy of repo/ to rewrite")
    ap.add_argument("--live", required=True, help="URL of the index the target serves now")
    ap.add_argument("--only", required=True, help="comma-separated package names to publish")
    ap.add_argument("--origin", default="", help="Origin/Label/Name for Release (else reuse)")
    ap.add_argument(
        "--allow-noop",
        action="store_true",
        help="rewrite the live index even when every scoped package is byte-identical",
    )
    args = ap.parse_args()

    names = [n.strip() for n in args.only.split(",") if n.strip()]
    if not names:
        sys.exit("scope-index: --only listed no packages")

    local_path = os.path.join(args.repo, "Packages")
    if not os.path.exists(local_path):
        sys.exit(f"scope-index: no generated index at {local_path}")
    local = parse_stanzas(open(local_path, encoding="utf-8").read())
    local_by_name = {}
    for name, stanza in local:
        local_by_name[name] = stanza   # make-repo.py already kept one (newest) per name

    missing = [n for n in names if n not in local_by_name]
    if missing:
        sys.exit("scope-index: not in the generated index (is the deb in repo/debs?): "
                 + ", ".join(missing))

    # The target's current truth. A failure here must stop the publish: scoping
    # against a guess would silently unpublish whatever we could not read.
    try:
        with urllib.request.urlopen(args.live, timeout=60) as r:
            live_text = r.read().decode("utf-8", "replace")
    except Exception as exc:                                  # noqa: BLE001
        sys.exit(f"scope-index: cannot read the live index at {args.live}: {exc}")
    live = parse_stanzas(live_text)
    live_names = {n for n, _ in live}
    print(f"scope-index: live index has {len(live)} package(s)")

    kept, replaced, added, identical = [], [], [], []
    for name, stanza in live:
        if name in names:
            kept.append((name, local_by_name[name]))
            if local_by_name[name].strip() == stanza.strip():
                identical.append((name, field(stanza, "Version")))
            else:
                replaced.append((name, field(stanza, "Version"),
                                 field(local_by_name[name], "Version")))
        else:
            kept.append((name, stanza))
    for name in names:
        if name not in live_names:
            kept.append((name, local_by_name[name]))
            added.append((name, field(local_by_name[name], "Version")))

    for name, was, now in replaced:
        print(f"   {name}: {was} -> {now}")
    for name, ver in added:
        print(f"   {name}: NEW at {ver}")
    for name, ver in identical:
        print(f"   {name}: {ver} is already live, byte-identical")
    if not replaced and not added:
        if not args.allow_noop:
            sys.exit("scope-index: every named package is already live unchanged. Nothing "
                     "would reach the target, so this publish is a no-op -- if you expected "
                     "a new version, the deb in repo/debs is stale (rebuild and repackage).")
        print("scope-index: metadata republish requested; preserving the live index")

    packages = "\n\n".join(s for _, s in kept) + "\n"
    open(local_path, "w", encoding="utf-8").write(packages)
    with open(os.path.join(args.repo, "Packages.gz"), "wb") as f:
        f.write(gzip.compress(packages.encode(), 9, mtime=0))

    # Release: keep the identifying fields the generator wrote, refresh Date and
    # the index hashes. Rewriting rather than regenerating keeps this file's
    # ownership with make-repo.py.
    rel_path = os.path.join(args.repo, "Release")
    head = []
    for line in open(rel_path, encoding="utf-8").read().split("\n"):
        if line.startswith(("MD5Sum:", "SHA256:", " ")):
            continue
        if line.startswith("Date:"):
            line = f"Date: {email.utils.formatdate(usegmt=True)}"
        if line.strip():
            head.append(line)

    def h(name):
        b = open(os.path.join(args.repo, name), "rb").read()
        return name, len(b), hashlib.md5(b).hexdigest(), hashlib.sha256(b).hexdigest()

    idx = [h("Packages"), h("Packages.gz")]
    rel = head + ["MD5Sum:"] + [f" {m} {s} {n}" for n, s, m, _ in idx]
    rel += ["SHA256:"] + [f" {sh} {s} {n}" for n, s, _, sh in idx]
    open(rel_path, "w", encoding="utf-8").write("\n".join(rel) + "\n")

    print(f"scope-index: deploying {len(kept)} package(s); "
          f"{len(replaced)} replaced, {len(added)} added, "
          f"{len(kept) - len(replaced) - len(added)} untouched")


if __name__ == "__main__":
    main()
