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

fails = 0
for name, tool, tool_input, want in CASES:
    payload = json.dumps({"tool_name": tool, "tool_input": tool_input})
    p = subprocess.run(["bash", GUARD], input=payload, capture_output=True, text=True)
    ok = p.returncode == want
    fails += not ok
    print(f"{'ok  ' if ok else 'FAIL'}  {name:28} exit={p.returncode} want={want}")

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
