# Device snapshots

Pre-change captures of the iPad's dpkg state, kept so a wiped or rejailbroken
device can be rebuilt to a known point.

## xios-snapshot-20260726-160057

Taken 2026-07-26 16:00 local, immediately before the KWin GL bring-up work, on
iPad7,12 / A10 / Darwin 23.6.0 (Dopamine, rootless `/var/jb`).

The iPad went down later that day. It was back in use by early August (the
device tests logged from then through October ran on it). This
manifest is kept as a known-good restore point for a future wipe, not as a
description of what the device runs today.

| File | What it is |
|---|---|
| `selections.txt` | `dpkg --get-selections`, 851 packages |
| `versions.txt` | `Package Version Status` per package. Use this, not selections, to pin versions |
| `holds.txt` | 8 held packages. **Re-apply these first**: holding them is what kept hand-deployed components from being clobbered by apt |
| `*.sources` | apt sources, including the staging repo the device tracked |

### Restoring after a rejailbreak

1. Bootstrap the jailbreak and Procursus, add the sources in `*.sources`.
   Note the device tracked **staging** (`dev.repo.maxleiter.com`), not production.
2. Re-apply the holds in `holds.txt` **before** installing anything.
3. Install from `versions.txt` rather than `selections.txt`; several packages
   were newer than what production shipped then. Today production is ahead of
   this snapshot for every Xios package, so for those prefer the current
   flavor metas (`xios-gnome`, `xios-kde`, `xios-native`, `xios-x11`).
4. Do **not** run `apt --fix-broken`; it can remove `libmutter`.

### Known-good versions worth carrying forward

The device ran `kwin 6.1.5+ios3` at snapshot time. Everything after that in the
GL chain is newer and better (production has `kwin 6.1.5+ios33` as of
2026-10-25), so never restore KWin from this manifest.

## Loose files

- `nonjb-m0-seam.patch`, `xios_paths.h`: the non-JB port M0 relocation seam,
  rescued from a stale worktree (base `40f36a6`). `main` has moved a long way on
  `iosc.c` since, so this will not rebase mechanically. The header is reusable
  verbatim; the call-site edits are better redone fresh. Kept only so the design
  is not lost.
