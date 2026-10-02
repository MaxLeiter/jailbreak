#!/usr/bin/env python3
"""Exercise bin/lib/guard-repo-ops.sh against the cases that matter."""
import json, subprocess, sys

GUARD = "bin/lib/guard-repo-ops.sh"
SYNC = "x11/tools/" + "sync-packages-to-repo.py"

# The commit message that the first version of the hook wrongly blocked: prose
# inside a heredoc that quotes the guarded command.
commit_msg_cmd = (
    "git commit -q -F - <<'EOF'\n"
    "publish: guard the silent failures\n"
    "\n"
    "The hook blocks a bare " + SYNC + " because it applies by\n"
    "default and deletes debs.\n"
    "EOF"
)

CASES = [
    ("bare invocation",              "Bash", {"command": SYNC}, 2),
    ("bare, with a path prefix",     "Bash", {"command": "python3 " + SYNC}, 2),
    ("with --dry-run",               "Bash", {"command": SYNC + " --dry-run"}, 0),
    ("mentioned in a heredoc",       "Bash", {"command": commit_msg_cmd}, 0),
    ("unrelated command",            "Bash", {"command": "git status"}, 0),
    ("edit repo/Packages",           "Edit", {"file_path": "/x/repo/Packages"}, 2),
    ("edit a depiction",             "Edit", {"file_path": "/x/repo/depictions/iosc.html"}, 2),
    ("edit a banner",                "Write", {"file_path": "/x/repo/banners/kwin.png"}, 2),
    ("edit the generator",           "Edit", {"file_path": "/x/bin/lib/make-repo.py"}, 0),
    ("edit per-package meta",        "Edit", {"file_path": "/x/repo/meta/iosc.json"}, 0),
    ("edit a package control",       "Edit", {"file_path": "/x/x11/packages/meta/xios-kde/DEBIAN/control"}, 0),
]

DEB = "repo/debs/iosc_0.9.47_iphoneos-arm64.deb"
CASES += [
    ("force-add a staged deb",       "Bash", {"command": "git add -f " + DEB}, 2),
    ("--force the debs dir",         "Bash", {"command": "git add --force repo/debs/"}, 2),
    ("-fv on a build-output deb",    "Bash", {"command": "git add -fv x11/linux-build/out/kwin_6.1.5+ios33_iphoneos-arm64.deb"}, 2),
    ("quoted deb glob",              "Bash", {"command": "git add -f 'repo/debs/*.deb'"}, 2),
    ("git -C, --, mid-chain",        "Bash", {"command": "cd /x && git -C /x add -f -- " + DEB + " && git commit -m x"}, 2),
    ("forced sweep: .",              "Bash", {"command": "git add -f ."}, 2),
    ("forced sweep: -fA",            "Bash", {"command": "git add -fA"}, 2),
    ("git stage -f",                 "Bash", {"command": "git stage -f " + DEB}, 2),
    ("second line of a script",      "Bash", {"command": "git status\ngit add -f " + DEB}, 2),
    ("unbalanced quote fallback",    "Bash", {"command": "git add -f " + DEB + " \"oops"}, 2),
    ("add the index",                "Bash", {"command": "git add repo/Packages"}, 0),
    ("unforced add of a deb",        "Bash", {"command": "git add " + DEB}, 0),
    ("force-add a non-deb file",     "Bash", {"command": "git add -f x11/packages/meta/xios-kde/DEBIAN/control"}, 0),
    ("untrack the debs",             "Bash", {"command": "git rm --cached " + DEB}, 0),
    ("force-add quoted in -m",       "Bash", {"command": "git commit -m \"never git add -f " + DEB + "\""}, 0),
    ("force-add in a heredoc",       "Bash", {"command": "git commit -F - <<'EOF'\nno git add -f " + DEB + "\nEOF"}, 0),
]

fails = 0
for name, tool, tool_input, want in CASES:
    payload = json.dumps({"tool_name": tool, "tool_input": tool_input})
    p = subprocess.run(["bash", GUARD], input=payload, capture_output=True, text=True)
    ok = p.returncode == want
    fails += not ok
    print(f"{'ok  ' if ok else 'FAIL'}  {name:28} exit={p.returncode} want={want}")

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
