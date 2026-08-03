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
- `sbprobe5.c` — **the `container` re-test. Run 2026-08-02. Its bootstrap row gave a FALSE
  PASS; read the warning in the source.** On a synthetic process `container` looked ideal:
  every renderer primitive survived and every write outside the container was denied
  (`/var/jb/tmp` and `/tmp` included). But it looked up an Apple *system* bootstrap service,
  and `container` denies the *app-registered* lookup a real helper does. Its write-denial rows
  are still good; its "renderer can run" conclusion was not.
- `sbinject.c` — **the one that settled `container`, and the cheapest tool here.** Confines
  *real* helpers by interposing `bootstrap_look_up` via `DYLD_INSERT_LIBRARIES`, so
  confinement lands where a source patch would (after the handshake) with **no engine
  rebuild**. Result: WebContent dies allocating its paint backing store
  (`PageClient.cpp:176`), ImageDecoder cannot pass Mach port descriptors
  (`TransportMachPort.cpp:75`) and silently decodes nothing. Both profiles are now closed.
  Reach for this before writing another synthetic probe.

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
`sbinject` env: `LADYBIRD_SANDBOX_PROCS` (default `WebContent,ImageDecoder`), `LADYBIRD_SANDBOX_PROFILE` (default `container`), `LADYBIRD_SANDBOX_WHEN` (`after-bootstrap` default, or `constructor` to reproduce the ordering failure). Built as a
dylib: add `-dynamiclib` to the clang line above. Launching ladybird on device also needs
`DYLD_LIBRARY_PATH=/var/jb/usr/lib/ladybird-tls:/var/jb/usr/lib:/var/jb/lib/angle` — the
ladybird-tls rpath bug, testing only.
