# Ladybird sandbox confinement probes

Throwaway device probes behind the findings in
[`../../docs/ladybird-sandbox-confinement.md`](../../docs/ladybird-sandbox-confinement.md).
Kept because the conclusion (named kernel profiles cannot host a Ladybird helper) is a
negative result, and negative results get re-litigated unless the measurement is rerunnable.

- `sbprobe.c` — bootstrap handshake ordering. Registers a custom Mach service in a parent,
  spawns a child that confines either before or after `bootstrap_look_up`, and reports which
  order survives. Also checks writes.
- `sbprobe4.c` — **the one that settled it.** `poll()`, `select()` and `kevent()` on
  descriptors created *before* confinement. All three are denied, so no fd-based event loop can
  run inside the profile. Run this first if anyone revisits the idea.
- `sbprobe3.c` — CoreText under confinement (family enumeration, glyph lookup), cold and warm.
  Fonts were a plausible second blocker and turned out fine.
- `sbprobe2.c` — the allocation matrix a new `IPC::Transport` needs (Mach ports, port set,
  the notify `pipe()`, a thread), plus network and write controls. Takes a profile name, so
  `com.apple.WebKit.WebContent` and `container` can be compared directly.
- `sbprobe5.c` — **the `container` re-test. Run 2026-08-02; `container` is usable.** The
  negative result above is only about `com.apple.WebKit.WebContent`; `container` had been set
  aside for a reason that weighed the wrong axis (network egress rather than filesystem write).
  Measured as both `root` and `mobile`: every renderer primitive survives (including
  `bootstrap_look_up`, so there is no ordering constraint), all reads survive, and every write
  outside the process's container is denied — `/var/jb/tmp` and `/tmp` included. Numbers and
  the important caveat (for a `mobile` helper, `/var/jb/usr/*` was already denied by file
  permissions, so the win is concentrated in the root-run flavor) are in the doc.
  Run `none` and `confined` and diff them; a row denied in both modes is file permissions or a
  missing file, not confinement.

Build and run (host needs the iPhoneOS SDK and `ldid`):

```sh
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.2 -o sbprobe sbprobe.c
ldid -S sbprobe
scp -i ~/.ssh/id_ed25519 sbprobe root@MaxsiPad.local:/var/jb/tmp/
ssh -i ~/.ssh/id_ed25519 root@MaxsiPad.local '/var/jb/tmp/sbprobe parent before'
```

`sbprobe` modes: `none` / `before` / `after`.
`sbprobe2` args: `<none|confined> [profile-name]`.
`sbprobe5` args: `<none|confined> [profile-name]` (profile defaults to `container`).
