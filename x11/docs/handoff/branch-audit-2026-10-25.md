# Branch and worktree audit (2026-10-25)

A read-only audit against origin/main `ccaa0126`, the merge of PR #13, which is also what production serves. Local `main` in the main checkout is 21 commits behind it and has none of its own. "Unmerged" means `git cherry` commits whose patches are not upstream. No PR is open.

## Has value

| Branch (worktree) | Unmerged | What it is | Landing it takes |
|---|---|---|---|
| claude/update-plans | 46 | WebKitGTK 2.54, Qt 6.10, KF6 6.30, Plasma 6.7 recipes (230 files) | Two rebase conflicts (`kwin-ios-fixes.sh`, `plasma-workspace-ios-fixes.sh`). Nothing is built or published. Needs a full KDE and WebKit rebuild plus device tests |
| claude/upd-wave-core | 17 | wayland 1.24, ffmpeg 5.1.10, libxslt CVE backports | No conflicts. ffmpeg unbuilt. Rebuild, bump, stage, device test |
| claude/upd-wave-gnome | 12 | libsoup 3.8, gmime, librsvg, libadwaita, exempi | No conflicts. Rebuild the GNOME stack and smoke-test Shell on device (libsoup 3.8 is ABI-sensitive) |
| claude/xwayland-24 | 4 | Xwayland 24.1.13 (34 CVEs) | No conflicts. Rebuild and device-test glamor/X11 apps. Highest security value |
| claude/ladybird-rebase | 7 | Ladybird rebased on upstream | No conflicts, but it still indexes wl4 (main ships wl5). Rebuild, bump past wl5, device test |
| claude/ipad-mcp-computer-use-dba20c | 9 | ipadctl daemon and iPad MCP server (+4.5k lines, additive) | No conflicts. Merge and PR; it already runs from that worktree |
| claude/xios-v2-ship | 10 | Xios v2 app rewrite, rebased, with the ioscd error port | No conflicts. Device test, then PR. `claude/xios-v2-app` is this minus its last commit |
| claude/xios-fileprovider | 6 | App Intents, share sheet, OPEN_URL, FileProvider | One conflict (`project.yml`). Rebase after v2 lands, rebuild, device test |
| claude/krita-inkscape | 6 | Krita and Inkscape lane | Two conflicts (`build-krita.sh`, `handoff/INDEX.md`). Rebuild and a Krita boot test |
| claude/nice-bose-345589 | 4 | Thermal frame-rate clamp, memory shedding, shell badge | Conflicts in XScreen, ioscd.c and XiosUpscale.swift. Re-port onto Xios v2 |
| claude/ios-features-graphics-50ff62 | 1 | `x11/docs/ios-platform-features.md` (224 lines) | Cherry-pick the doc |
| claude/pull-to-refresh-ipad-ffebf4 | 1 | Wording fix in 2 tweak metas | Cherry-pick |
| claude/abbrtap-staged-wip | 1 | AbbrTap tweak (4 files) plus a games.md note | `bin/build.sh tweaks/AbbrTap` and a device test |
| webkit-jit-hwgl (uncommitted) | none | WebKit JIT with hardware GL: `webkitgtk.mk`, `XiosMetalEventBroker`, patches 0015-0018, plan, probe, entitlements | **Commit it to a branch before touching the worktree.** Likely conflicts with update-plans' WebKit work |
| agent-ac57bfb0126d4420e (uncommitted) | none | July non-JB path seam (`xios_paths.h`, untracked) | **Commit it to a branch before removing the worktree.** Its XScreen edit clashes with v2 |

## Stale (unmerged but superseded, so `-d` refuses; your call on `-D`)

- claude/xios-v2-app: v2-ship minus one commit. Once v2-ship merges, `-d` works.
- claude/elated-blackwell-e95bbc: indexes ladybird-wayland wl5, which main already ships.
- claude/strange-driscoll-4d583b: its 2 commits are the first 2 of xios-fileprovider.
- backup/track3-pre-port: a superset of nice-bose. Its MetalFX commit landed as 7a5a61fc.
- backup/wip-before-origin-sync-20260730, claude/kde-osk-return-and-iosurface-race: stash-style WIP snapshots (541 and 633 files).

The main checkout's staged AbbrTap files are byte-identical to `claude/abbrtap-staged-wip`, so nothing is lost there. Its modified `x11/docs/handoff/games.md` still needs a `git diff` look before you fast-forward it.

## Safe to remove (fully merged, no real uncommitted work)

Run this from a checkout whose HEAD contains origin/main, so `-d` checks against the right base. It never uses `-D` or `--force`. The `restore`/`clean` lines discard only regenerated repo output and stale edits, which were checked in this audit.

```bash
W=/Users/max/Documents/jailbreak/.claude/worktrees
git worktree remove $W/doom
git worktree remove $W/kde-plasma-session-timeout-fe4d86   # claude/audit-followups, PR #6 merged
git worktree remove $W/shadow-prune
git worktree remove $W/sharp-burnell-99dfb4                # ipad-pages-organize, 0 ahead
git worktree remove $W/untrack-repo-debs
git worktree remove $W/repo-x11-packages-0406aa            # xios-v2-m0, PR #10 merged
for p in practical-torvalds-3a2d5b slopwiki-xios-audit-49654c repo-fhs-pulse-publish strange-fermi-9d536d; do
  git -C $W/$p restore . && git -C $W/$p clean -fdq       # generated repo/ output and stale edits only
  git worktree remove $W/$p
done
for b in claude/doom claude/audit-followups claude/shadow-prune claude/ipad-pages-organize-120cbc \
  claude/untrack-repo-debs claude/xios-v2-m0 claude/practical-torvalds-3a2d5b \
  claude/slopwiki-xios-audit-49654c claude/publish-fhs-1.0.5-pulseaudio-ios2 \
  claude/repo-x11-packages-0406aa claude/sweep-fixes claude/github-issue-11-71a5be \
  claude/xios-app-v2 claude/common-library-mod-96159a claude/audit-cleanup-pass-6b4add \
  claude/audit-fix-rebuild claude/ipad-perf-optimization-158318 claude/openjdk-awt-x11-lane-44510a \
  claude/analytics-package-tracking-ca17fd claude/security-sweep-de8157 \
  claude/iosc-desktop-ipad-bug-047979 claude/wonderful-jennings-65df30 \
  backup/main-pre-origin-sync-20260730 backup/origin-main-pre-sync-20260730 games-to-main tmp-main; do
  git branch -d "$b"
done
```

Leave the `agent-*` worktrees and `claude/gaps-cleanup` alone while that work is in flight.
