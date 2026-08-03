#!/usr/bin/env python3
"""Audit pinned linux-build recipe versions against their upstream sources.

The recipes are the inventory: this script reads Make assignments and download
URLs directly, so adding a recipe cannot silently bypass the report.  It uses
official archive indexes (including GNOME cache.json) or upstream git tags and
has no third-party Python dependencies.

This is deliberately an auditor, not an auto-bumper.  Cross-port patches,
desktop release cohorts, Procursus ABI shadows, and the iOS toolchain all make a
blind "latest wins" policy unsafe.  linux-build/upstream-version-policy.json
declares the exceptional tracks and holds.

A policy rule may set "security": true alongside its "hold".  Most holds are a
scheduling choice -- an ABI cohort that has to move as one lane -- and reading
"held" as "fine for now" is correct for those.  It is not correct for a pin that
ships parsing code for untrusted input on an upstream that no longer receives
fixes.  Those report as "security-held", sort first, and get their own callout,
so the two never blur together in the same list.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request


X11_ROOT = Path(__file__).resolve().parents[2]
RECIPE_ROOTS = (X11_ROOT / "linux-build/recipes", X11_ROOT / "linux-build/recipes-ladybird")
POLICY_PATH = X11_ROOT / "linux-build/upstream-version-policy.json"
CACHE_DIR = Path(os.environ.get("XIOS_UPSTREAM_CACHE", Path.home() / ".cache/xios-upstream-versions"))
ASSIGN_RE = re.compile(r"^([A-Z][A-Z0-9_]*)\s*[:?+]?=\s*([^#\n]+)", re.M)
REF_RE = re.compile(r"\$\(([A-Z][A-Z0-9_]*)\)")
VERSION_VAR_RE = re.compile(r"_(?:VERSION|COMMIT)$")
ARCHIVE_SUFFIX_RE = re.compile(r"(?:\.tar\.(?:xz|gz|bz2|zst)|\.tgz|\.zip)(?:\{.*)?$")
UNSTABLE_RE = re.compile(r"(?:^|[._+~-])(alpha|beta|rc|pre|preview|snapshot|dev)(?:[._+~-]|\d|$)", re.I)
GIT_NETWORK_SLOTS = threading.Semaphore(1)


def cache_get(url: str, refresh: bool, timeout: int = 30) -> str:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()
    cached = CACHE_DIR / key
    if not refresh and cached.exists() and time.time() - cached.stat().st_mtime < 6 * 3600:
        return cached.read_text(errors="replace")
    req = urllib.request.Request(url, headers={"User-Agent": "xios-upstream-audit/1"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        data = response.read().decode("utf-8", "replace")
    cached.write_text(data)
    return data


def cached_git_tags(repo: str, refresh: bool) -> list[str]:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(("git:" + repo).encode()).hexdigest()
    cached = CACHE_DIR / key
    if not refresh and cached.exists() and time.time() - cached.stat().st_mtime < 6 * 3600:
        output = cached.read_text(errors="replace")
    else:
        proc = None
        # GitHub/GitLab will intermittently reset a burst of parallel smart-HTTP
        # requests. Keep the overall audit concurrent but serialize git hosts a
        # little and retry transient transport failures.
        with GIT_NETWORK_SLOTS:
            for attempt in range(3):
                proc = subprocess.run(
                    ["git", "-c", "http.version=HTTP/1.1", "ls-remote", "--tags", "--refs", repo],
                    text=True, capture_output=True, timeout=60,
                )
                if proc.returncode == 0:
                    break
                time.sleep(attempt + 1)
        assert proc is not None
        if proc.returncode:
            raise RuntimeError(proc.stderr.strip() or
                               f"git ls-remote failed for {repo} (exit {proc.returncode})")
        output = proc.stdout
        cached.write_text(output)
    return [line.rsplit("refs/tags/", 1)[-1] for line in output.splitlines() if "refs/tags/" in line]


def natural_key(version: str) -> tuple:
    return tuple((0, int(part)) if part.isdigit() else (1, part.lower())
                 for part in re.findall(r"\d+|[^\d]+", version))


def stable_versions(versions: list[str]) -> list[str]:
    return sorted({v.strip() for v in versions
                   if re.search(r"\d", v) and not UNSTABLE_RE.search(v)}, key=natural_key)


def resolve(value: str, variables: dict[str, str]) -> str | None:
    """Resolve the simple Make expressions used by version assignments."""
    out = value.strip()
    for _ in range(12):
        old = out
        out = re.sub(
            r"\$\(shell echo \$\(([A-Z0-9_]+)\) \| cut -(?:d\.|f-?\d+ -d\.|d\. -f-?\d+)\)",
            lambda m: ".".join(resolve(variables.get(m.group(1), ""), variables).split(".")[:2])
            if resolve(variables.get(m.group(1), ""), variables) else m.group(0), out,
        )
        out = re.sub(
            r"\$\(basename \$\(([A-Z0-9_]+)\)\)",
            lambda m: ".".join((resolve(variables.get(m.group(1), ""), variables) or "").split(".")[:2]), out,
        )
        out = REF_RE.sub(lambda m: variables.get(m.group(1), m.group(0)).strip(), out)
        if out == old:
            break
    if "$(" in out or not re.search(r"\d", out):
        return None
    return out.strip()


def source_url_for(text: str, variable: str) -> str | None:
    needle = f"$({variable})"
    for line in text.splitlines():
        if needle not in line or "http" not in line:
            continue
        start = line.find("http")
        url = line[start:].strip()
        # DOWNLOAD_FILES closes with one Make-function ')'. Keep parentheses
        # belonging to variable references and remove only that outer closer.
        if "DOWNLOAD_FILES" in line and url.endswith(")"):
            url = url[:-1]
        return url
    return None


def expand_url(template: str, variable: str, current: str,
               variables: dict[str, str]) -> str | None:
    marker = "XIOSVERSIONMARKER"
    out = template.replace(f"$({variable})", marker)
    for _ in range(12):
        old = out
        out = re.sub(
            r"\$\(shell echo XIOSVERSIONMARKER \| cut -f-?(\d+) -d\.\)",
            lambda m: ".".join(current.split(".")[:int(m.group(1))]), out,
        )
        out = re.sub(
            r"\$\(shell echo XIOSVERSIONMARKER \| cut -d\. -f-?(\d+)\)",
            lambda m: ".".join(current.split(".")[:int(m.group(1))]), out,
        )
        out = out.replace("$(basename XIOSVERSIONMARKER)", ".".join(current.split(".")[:2]))
        out = re.sub(
            r"\$\(shell echo \$\(([A-Z0-9_]+)\) \| cut -d\. -f-?(\d+)\)",
            lambda m: ".".join((resolve(variables.get(m.group(1), ""), variables) or "").split(".")[:int(m.group(2))]), out,
        )
        out = re.sub(
            r"\$\(shell echo \$\(([A-Z0-9_]+)\) \| cut -f-?(\d+) -d\.\)",
            lambda m: ".".join((resolve(variables.get(m.group(1), ""), variables) or "").split(".")[:int(m.group(2))]), out,
        )
        out = re.sub(
            r"\$\(basename \$\(([A-Z0-9_]+)\)\)",
            lambda m: ".".join((resolve(variables.get(m.group(1), ""), variables) or "").split(".")[:2]), out,
        )
        out = REF_RE.sub(lambda m: resolve(variables.get(m.group(1), ""), variables) or m.group(0), out)
        if out == old:
            break
    out = out.replace(marker, current)
    if "$(" in out or "{" in out:
        return None
    return out


def infer_track(template: str | None, variables: dict[str, str],
                variable: str, current: str) -> str | None:
    if not template:
        return None
    for ref in REF_RE.findall(template):
        if ref.endswith("_MAJOR_V") or ref.endswith("_MINOR"):
            value = resolve(variables.get(ref, ""), variables)
            if value:
                return value
    token = re.escape(f"$({variable})")
    shell_cut = re.search(rf"\$\(shell echo {token} \| cut (?:-f-?(\d+) -d\.|-d\. -f-?(\d+))\)", template)
    if shell_cut:
        count = int(shell_cut.group(1) or shell_cut.group(2))
        return ".".join(current.split(".")[:count])
    return None


def default_track(current: str, source_url: str | None) -> str | None:
    """Choose a conservative compatibility line when a recipe has no policy.

    A numeric source-directory component that prefixes the current version is
    an explicit upstream series (GNOME 46, GNOME 3.46, etc.). Otherwise use
    SemVer's major line, or major.minor for pre-1.0 packages.
    """
    if source_url:
        parsed = urllib.parse.urlsplit(source_url)
        # These hosts use numeric directory names as maintained release
        # series. Git forge URLs instead put the exact tag in a directory, so
        # treating every numeric path component as a track would pin forever.
        if parsed.netloc in {"download.gnome.org", "ftp.gnome.org", "archive.xfce.org"}:
            components = parsed.path.split("/")[:-1]
            candidates = [part for part in components
                          if re.fullmatch(r"\d+(?:\.\d+)*", part)
                          and (current == part or current.startswith(part + "."))]
            if candidates:
                return max(candidates, key=len)
    match = re.match(r"(\d+)(?:\.(\d+))?", current)
    if not match:
        return None
    if match.group(1) == "0" and match.group(2) is not None:
        return f"0.{match.group(2)}"
    return match.group(1)


def git_source(template: str, variable: str) -> tuple[str, re.Pattern[str]] | None:
    parsed = urllib.parse.urlsplit(template)
    host = parsed.netloc
    if host not in {"github.com", "gitlab.com", "gitlab.freedesktop.org", "codeberg.org", "git.sr.ht"}:
        return None
    parts = parsed.path.strip("/").split("/")
    if len(parts) < 2:
        return None
    suffix = "" if host == "git.sr.ht" else ".git"
    repo = f"https://{host}/{parts[0]}/{parts[1].removesuffix('.git')}{suffix}"
    token = f"$({variable})"
    tag_template = None
    path = parsed.path
    patterns = (
        rf"/releases/download/([^/]*{re.escape(token)}[^/]*)/",
        rf"/-/releases/([^/]*{re.escape(token)}[^/]*)/",
        rf"/-/archive/([^/]*{re.escape(token)}[^/]*)/",
        rf"/refs/tags/([^/]*{re.escape(token)}[^/]*)",
        rf"/archive/([^/]*{re.escape(token)}[^/]*)",
    )
    for pattern in patterns:
        match = re.search(pattern, path)
        if match:
            tag_template = ARCHIVE_SUFFIX_RE.sub("", match.group(1))
            break
    if not tag_template:
        return None
    expression = re.escape(tag_template).replace(re.escape(token), r"(?P<version>[0-9][0-9A-Za-z._+~-]*)")
    return repo, re.compile(rf"^{expression}$")


def gnome_versions(template: str, refresh: bool) -> list[str] | None:
    match = re.search(r"(?:download\.gnome\.org/sources|ftp\.gnome\.org/pub/gnome/sources)/([^/]+)", template)
    if not match:
        return None
    package = match.group(1)
    payload = json.loads(cache_get(f"https://download.gnome.org/sources/{package}/cache.json", refresh))
    if isinstance(payload, list) and len(payload) > 1 and isinstance(payload[1], dict):
        package_map = payload[1].get(package)
        if isinstance(package_map, dict):
            return list(package_map)
    return []


def generic_archive_versions(url: str, current: str, refresh: bool) -> list[str]:
    parsed = urllib.parse.urlsplit(url)
    filename = Path(parsed.path).name
    if current not in filename:
        return []
    expression = re.escape(filename).replace(re.escape(current), r"(?P<version>[0-9][0-9A-Za-z._+~-]*)")
    page_url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, str(Path(parsed.path).parent) + "/", "", ""))
    page = html.unescape(cache_get(page_url, refresh))
    return [match.group("version") for match in re.finditer(expression, page)]


def policy_for(key: str, policy: dict) -> dict:
    merged: dict = {}
    for rule in policy.get("rules", []):
        patterns = rule["match"] if isinstance(rule["match"], list) else [rule["match"]]
        if any(fnmatch.fnmatch(key, pattern) for pattern in patterns):
            merged.update({k: v for k, v in rule.items() if k != "match"})
    merged.update(policy.get("overrides", {}).get(key, {}))
    return merged


def versions_from_policy(rule: dict, refresh: bool) -> list[str] | None:
    source = rule.get("source")
    if not source:
        return None
    if source["kind"] == "html":
        page = html.unescape(cache_get(source["url"], refresh))
        regex = re.compile(source["regex"])
        return [m.group("version") for m in regex.finditer(page)]
    if source["kind"] == "git":
        tags = cached_git_tags(source["url"], refresh)
        regex = re.compile(source["regex"])
        return [m.group("version") for tag in tags if (m := regex.fullmatch(tag))]
    raise ValueError(f"unknown policy source kind: {source['kind']}")


def audit_one(record: dict, policy: dict, refresh: bool) -> dict:
    key = record["key"]
    rule = policy_for(key, policy)
    result = {**record, "status": "unknown", "latest": None,
              "candidate": None, "track": rule.get("track") or record.get("track")
              or default_track(record["current"], record.get("source_url")),
              "note": rule.get("hold") or rule.get("note"),
              "security": bool(rule.get("security")), "error": None}
    if rule.get("ignore"):
        result["status"] = "ignored"
        result["note"] = rule["ignore"]
        return result
    try:
        versions = versions_from_policy(rule, refresh)
        template = record.get("source_template")
        if versions is None and template:
            versions = gnome_versions(template, refresh)
        if versions is None and template and (git := git_source(template, record["variable"])):
            repo, regex = git
            versions = [m.group("version") for tag in cached_git_tags(repo, refresh)
                        if (m := regex.fullmatch(tag))]
        if versions is None and record.get("source_url"):
            versions = generic_archive_versions(record["source_url"], record["current"], refresh)
        versions = stable_versions(versions or [])
        if not versions:
            return result
        result["latest"] = versions[-1]
        tracked = versions
        if result["track"]:
            prefix = str(result["track"])
            tracked = [v for v in versions if v == prefix or v.startswith(prefix + ".")]
        if not tracked:
            result["status"] = "track-missing"
            return result
        result["candidate"] = tracked[-1]
        current_key = natural_key(result["current"])
        candidate_key = natural_key(result["candidate"])
        if current_key < candidate_key:
            # A hold on a security-relevant pin is still a hold -- it cannot be bumped
            # today -- but it must not read like the benign ABI-cohort holds around it.
            # Those are a scheduling choice; this one means users run unpatched code.
            if rule.get("hold"):
                result["status"] = "security-held" if rule.get("security") else "held"
            else:
                result["status"] = "update"
        elif current_key > candidate_key:
            result["status"] = "ahead"
        elif result["latest"] != result["candidate"]:
            result["status"] = "track-current"
        else:
            result["status"] = "current"
    except Exception as exc:  # network/source failures belong in the report
        result["error"] = str(exc)
    return result


def inventory() -> list[dict]:
    records: list[dict] = []
    for root in RECIPE_ROOTS:
        for path in sorted(root.glob("*.mk")):
            text = path.read_text(errors="replace")
            variables = {name: value.strip() for name, value in ASSIGN_RE.findall(text)}
            for variable, raw in variables.items():
                if not VERSION_VAR_RE.search(variable):
                    continue
                # Aliases are audited at their concrete cohort variable.
                if re.fullmatch(r"\$\([A-Z0-9_]+_(?:VERSION|COMMIT)\)", raw.strip()):
                    continue
                current = resolve(raw, variables)
                if not current:
                    continue
                template = source_url_for(text, variable)
                source_url = expand_url(template, variable, current, variables) if template else None
                rel = path.relative_to(X11_ROOT).as_posix()
                records.append({
                    "key": f"{rel}:{variable}", "file": rel, "variable": variable,
                    "current": current, "source_template": template, "source_url": source_url,
                    "track": infer_track(template, variables, variable, current),
                })
    return records


# Report order. Everything unlisted sorts after these, alphabetically by status.
STATUS_ORDER = {"security-held": 0, "update": 1, "track-missing": 2, "unknown": 3, "held": 4}


def sort_key(r: dict) -> tuple:
    return (STATUS_ORDER.get(r["status"], 50), r["status"], r["key"])


def security_holds(results: list[dict]) -> list[dict]:
    return [r for r in results if r["status"] == "security-held"]


def render_text(results: list[dict]) -> str:
    counts = {status: sum(r["status"] == status for r in results)
              for status in sorted({r["status"] for r in results})}
    lines = ["Xios upstream version audit", "  " + ", ".join(f"{k}={v}" for k, v in counts.items()), ""]
    held = security_holds(results)
    if held:
        lines.append("!! SECURITY-RELEVANT HOLDS -- shipped to users on an unpatched upstream:")
        for r in held:
            lines.append(f"     {r['key']}: {r['current']} (upstream {r['latest'] or '?'})")
            if r.get("note"):
                lines.append(f"       {r['note']}")
        lines.append("")
    for r in results:
        if r["status"] in {"current", "ignored"}:
            continue
        target = r["candidate"] or "?"
        latest = f"; upstream {r['latest']}" if r["latest"] and r["latest"] != target else ""
        note = f" — {r['note']}" if r.get("note") else ""
        error = f" — ERROR: {r['error']}" if r.get("error") else ""
        lines.append(f"{r['status']:13} {r['key']}: {r['current']} -> {target}{latest}{note}{error}")
    return "\n".join(lines) + "\n"


def render_markdown(results: list[dict]) -> str:
    counts = {status: sum(r["status"] == status for r in results)
              for status in sorted({r["status"] for r in results})}
    lines = ["# Xios upstream version audit", "",
             "Generated from the pinned versions in `linux-build/recipes/` and official upstream sources.", "",
             " | ".join(f"**{k}:** {v}" for k, v in counts.items()), ""]
    held = security_holds(results)
    if held:
        lines += ["> **Security-relevant holds.** These pins ship to users on an upstream that no",
                  "> longer receives fixes. They are held for a build reason, not a scheduling one,",
                  "> so the hold is the bug to fix -- not a status to acknowledge.", ""]
        for r in held:
            lines.append(f"> - `{r['key']}` at **{r['current']}** (upstream {r['latest'] or '?'})"
                         + (f" -- {r['note']}" if r.get("note") else ""))
        lines.append("")
    lines += ["| Status | Recipe pin | Current | Candidate | Latest | Track / note |", "|---|---|---:|---:|---:|---|"]
    for r in results:
        if r["status"] in {"current", "ignored"}:
            continue
        note = r.get("note") or (f"track {r['track']}" if r.get("track") else "")
        if r.get("error"):
            note = (note + "; " if note else "") + "error: " + r["error"]
        lines.append(f"| {r['status']} | `{r['key']}` | {r['current']} | {r['candidate'] or ''} | {r['latest'] or ''} | {note} |")
    lines.extend(["", "`track-current` means the maintained compatibility line is current while a newer upstream line exists.", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("text", "markdown", "json"), default="text")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--refresh", action="store_true", help="ignore the six-hour source cache")
    parser.add_argument("--include", help="fnmatch filter for recipe-pin keys")
    parser.add_argument("--strict-coverage", action="store_true", help="fail if a non-ignored pin cannot be resolved")
    parser.add_argument("--fail-on-update", action="store_true")
    args = parser.parse_args()
    policy = json.loads(POLICY_PATH.read_text())
    records = inventory()
    if args.include:
        records = [r for r in records if fnmatch.fnmatch(r["key"], args.include)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        results = list(executor.map(lambda r: audit_one(r, policy, args.refresh), records))
    results.sort(key=sort_key)
    if args.format == "json":
        output = json.dumps(results, indent=2) + "\n"
    elif args.format == "markdown":
        output = render_markdown(results)
    else:
        output = render_text(results)
    if args.output:
        args.output.write_text(output)
    else:
        print(output, end="")
    if args.strict_coverage and any(r["status"] in {"unknown", "track-missing"} and not r.get("note") for r in results):
        return 2
    if args.fail_on_update and any(r["status"] == "update" for r in results):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
