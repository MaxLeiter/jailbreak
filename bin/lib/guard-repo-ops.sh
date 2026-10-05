#!/usr/bin/env bash
# Claude Code PreToolUse hook: refuse hand-edits of generated repo output, which
# destroy work silently rather than failing.
#
# Wired up by bin/setup-repo-guards.sh. Reads the hook JSON on stdin; exit 2
# blocks the call and shows stderr to the agent, exit 0 allows it.
#
# Scope is deliberately narrow. Guards that belong to a script live IN that
# script, where they protect every caller (make-repo.py refuses to shrink the
# index; publish-repo.sh refuses an uncommitted prod index;
# sync-packages-to-repo.py is dry-run by default and --apply needs --only). An
# edit is an editor action with no script involved, so it is guarded here.
set -uo pipefail

# Read the hook JSON here and hand it over in the environment: the python below
# arrives on stdin as a heredoc, so stdin is not available to read data from.
HOOK_PAYLOAD="$(cat)"
export HOOK_PAYLOAD

exec python3 <<'PYEOF'
import json, os, re, shlex, sys

try:
    payload = json.loads(os.environ.get("HOOK_PAYLOAD") or "")
except Exception:
    sys.exit(0)

tool = payload.get("tool_name") or ""
tool_input = payload.get("tool_input") or {}


def strip_heredocs(cmd):
    """Drop heredoc bodies before pattern-matching.

    A command that merely *mentions* a dangerous invocation must not be blocked.
    Commit messages and generated docs are written with `<<'EOF'` heredocs and
    routinely quote the very commands this hook guards -- the first version of
    this hook blocked the commit that introduced it.
    """
    out, lines = [], cmd.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        for m in re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line):
            marker = m.group(2)
            i += 1
            while i < len(lines) and lines[i].strip() != marker:
                i += 1
            break
        i += 1
    return "\n".join(out)


def forced_deb_adds(cmd):
    """Pathspecs a `git add -f` would force past the .deb / repo/debs ignore rules.

    Tokenized with shlex, so a commit message that quotes the command stays one
    token and is not mistaken for an invocation. A forced sweep (`.`, `-A`, `repo`)
    counts too: from the repo root it sweeps up all of repo/debs.
    """
    try:
        lex = shlex.shlex(cmd, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        hit = re.search(r"\bgit\b[^;&|\n]*\b(add|stage)\b[^;&|\n]*"
                        r"\s(-[A-Za-z]*f[A-Za-z]*|--force)\b[^;&|\n]*(\.deb\b|repo/debs)", cmd)
        return [hit.group(0)] if hit else []
    hits = []
    for i, tok in enumerate(tokens):
        if tok.rsplit("/", 1)[-1] != "git":
            continue
        j = i + 1
        while j < len(tokens) and tokens[j].startswith("-"):
            j += 2 if tokens[j] in ("-C", "-c", "--git-dir", "--work-tree", "--namespace") else 1
        if j >= len(tokens) or tokens[j] not in ("add", "stage"):
            continue
        force = sweep = after_dashdash = False
        specs = []
        for a in tokens[j + 1:]:
            if set(a) <= set("();<>|&"):
                break
            if after_dashdash or not a.startswith("-") or a == "-":
                specs.append(a)
            elif a == "--":
                after_dashdash = True
            elif a.startswith("--"):
                force |= a == "--force"
                sweep |= a == "--all"
            else:
                force |= "f" in a[1:]
                sweep |= "A" in a[1:]
        if not force:
            continue
        hits += [s for s in specs
                 if re.search(r"\.deb\b|repo/debs", s)
                 or s.rstrip("/") in ("", ".", ":", "*", "repo", "./repo")]
        if sweep and not specs:
            hits.append("-A")
    return hits


if tool == "Bash":
    # No Bash rule is active. The one that lived here blocked a bare
    # sync-packages-to-repo.py back when it applied by default and deleted debs;
    # the script is now dry-run by default and refuses --apply without --only.
    # A rule added here should match against `cmd`, never the raw command.
    cmd = strip_heredocs(tool_input.get("command") or "")

elif tool in ("Edit", "Write", "NotebookEdit"):
    path = tool_input.get("file_path") or ""
    # Each profile (repo/profiles/<name>/, e.g. rootful) is its own generated
    # tree with the same layout as the rootless one at repo/.
    generated = (
        r"/repo/(profiles/[^/]+/)?"
        r"(Packages(\.gz|\.pv|\.sha)?|Release(\.gpg)?|InRelease"
        r"|index\.html|site\.css|sileo-featured\.json|sitemap\.xml|robots\.txt"
        r"|depictions/.*|icons/.*|banners/.*)$"
    )
    if re.search(generated, path):
        sys.stderr.write(
            f"BLOCKED: {path} is generated output, not source. Editing it by hand works\n"
            "until the next publish regenerates the file and silently discards the change.\n"
            "\n"
            "Change the input instead:\n"
            "  - page layout, depiction markup, section/glyph logic -> bin/lib/make-repo.py\n"
            "  - per-package copy (tagline/description/changelog)   -> repo/meta/<pkg>.json\n"
            "  - package fields (Depends, Version, Description)     -> that package's control\n"
            "\n"
            "Then regenerate (no .deb payloads needed):\n"
            "    python3 bin/lib/make-repo.py --from-index\n"
            "\n"
            "Genuinely patching an emergency artifact? Say so explicitly and use a shell\n"
            "redirect instead of the edit tools, so it is visible in the transcript.\n"
        )
        sys.exit(2)

# repo/debs/ and *.deb are gitignored: payloads go to Vercel Blob, and only
# repo/Packages is tracked. `git add -f` is the one way past that, and it is
# how 19 staged debs sat in git from 2026-07-29 until 2026-10-01.
if tool == "Bash":
    forced = forced_deb_adds(strip_heredocs(tool_input.get("command") or ""))
    if forced:
        sys.stderr.write(
            f"BLOCKED: `git add -f` would force .deb payloads into git: {' '.join(forced)}\n"
            "repo/debs/ and *.deb are gitignored on purpose. Payloads reach users through\n"
            "the publish procedure (Vercel Blob); git tracks only the index. CI fails on any\n"
            "tracked .deb.\n"
            "\n"
            "To record a publish, commit the index:  git add repo/Packages\n"
            "To force-add some other ignored file, name that file explicitly.\n"
        )
        sys.exit(2)

sys.exit(0)
PYEOF
