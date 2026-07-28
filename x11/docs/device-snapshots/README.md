# Device snapshots

Pre-change captures of the iPad's dpkg state, kept so a wiped or rejailbroken
device can be rebuilt to a known point.

## xios-snapshot-20260726-160057

Taken 2026-07-26 16:00 local, immediately before the KWin GL bring-up work, on
iPad7,12 / A10 / Darwin 23.6.0 (Dopamine, rootless `/var/jb`).

**The iPad died later that day and needs rejailbreaking, so this is the last
known-good manifest of that install.**

| File | What it is |
|---|---|
| `selections.txt` | `dpkg --get-selections` — 851 packages |
| `versions.txt` | `Package Version Status` per package — use this, not selections, to pin versions |
| `holds.txt` | 8 held packages. **Re-apply these first**: holding them is what kept hand-deployed components from being clobbered by apt |
| `*.sources` | apt sources, including the staging repo the device tracked |

### Restoring after a rejailbreak

1. Bootstrap the jailbreak and Procursus, add the sources in `*.sources`.
   Note the device tracked **staging** (`dev.repo.maxleiter.com`), not production.
2. Re-apply the holds in `holds.txt` **before** installing anything.
3. Install from `versions.txt` rather than `selections.txt` — several packages
   were newer than what production shipped.
4. Do **not** run `apt --fix-broken`; it can remove `libmutter`.

### Known-good versions worth carrying forward

The device ran `kwin 6.1.5+ios3` at snapshot time. Everything after that in the
GL chain is newer and better — see `x11/docs/handoff/state-2026-07-26.md` and the
`kwin:` commits from 2026-07-26. Rebuild to `+ios11` or later, not to `+ios3`.

## Loose files

- `nonjb-m0-seam.patch`, `xios_paths.h` — the non-JB port M0 relocation seam,
  rescued from a stale worktree (`.claude/worktrees/agent-ac57bfb0126d4420e`,
  base `40f36a6`). `main` has since moved +2558/-587 on `iosc.c` alone, so this
  will not rebase mechanically. The header is reusable verbatim; the call-site
  edits are better redone fresh. Kept only so the design is not lost.
