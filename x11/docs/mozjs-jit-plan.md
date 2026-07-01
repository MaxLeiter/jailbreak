# mozjs 115 JIT on iOS — de-risk + plan (#46)

Goal: JIT-enable SpiderMonkey 115 on iOS **without clobbering the working JIT-less recipe**,
so gjs / GNOME Shell JS runs faster on-device. The JIT-less build is SOLVED and shipping
(see [[x11-mozjs-ios-build]]); this is the follow-on speed track.

## Device W^X capability — DE-RISKED on-device (2026-07-01)

Probe: `ports/mozjs/tools/wxprobe.c` (compile on-device with the Procursus clang, sign with
`ldid -S ports/mozjs/tools/ent-jit.xml`). Forks each strategy so a codesigning `SIGKILL`/`SIGBUS`
is captured as the child's termination signal. Ran on **iPad7,12 / T8010 / A10 Fusion,
iOS 17.6.1, palera1n rootless**, as a root CLI process.

| strategy | result | meaning |
|---|---|---|
| `pthread_jit_write_protect_np` (dlsym) | **absent** | no APRR fast path on A10 (APRR arrived with A11) |
| `mmap RW` → write → `mprotect RX` → exec | **PASS** | the W^X-compliant flip works — this is our path |
| repeated RW↔RX flips × 1024, exec each | **PASS** | re-patching a live code region is correct |
| `mmap PROT_READ\|WRITE\|EXEC` (persistent RWX) | **SIGBUS** | kernel forbids simultaneously-writable-executable pages |
| `mmap ... MAP_JIT` | **EINVAL (22)** | MAP_JIT rejected on A10 — Apple fast-WX alloc is dead here |

Notably the mprotect flip **PASS**ed even with the baseline signing (no `dynamic-codesigning`
entitlement, only `platform-application`), because a root process under this checkm8 jailbreak
already clears AMFI's mprotect-to-executable gate. We still ship the `dynamic-codesigning`
entitlement for the **sandboxed app** case (Xios), where the gate is enforced per-process.

### Flip cost (the honest-read number)

`mprotect` RW↔RX **flip-pair: ~1122 ns** (~561 ns per single `mprotect`) on the A10.
`sys_icache_invalidate(8B)`: ~38 ns. So each code-patch batch costs ~1 µs of syscall. SpiderMonkey
flips once per patched code region (not per instruction), so for gjs UI glue (compile-once,
patch-occasionally) this is negligible; even 10k flips/sec ≈ 1% overhead. The pathological case is
IC-thrash code; the benchmark will bound it.

## Consequence for the patch (patch 0005 — runtime-adaptive W^X)

SpiderMonkey 115 hardcodes the **Apple fast-WX** path on Darwin/arm64
(`JS_USE_APPLE_FAST_WX`): it allocates the executable pool with `MAP_JIT` and toggles
writability with `pthread_jit_write_protect_np`. On the A10 that path is **doubly broken** —
`MAP_JIT` EINVALs at allocation and `pthread_jit_write_protect_np` is absent (writes to RX pages
would SIGBUS). So the patch must route Darwin/arm64 to the **generic `mprotect` reprotect path**:

- allocate the executable pool **without** `MAP_JIT` (plain `mmap`, pages default RX, reserve
  `PROT_NONE`), and
- use `ReprotectRegion` (mprotect RW to patch, RX to run) instead of the pthread toggle.

Runtime-adaptive (so a future A11+ device gets the fast path): at JIT init, feature-detect
`pthread_jit_write_protect_np` via `dlsym` **and** probe `MAP_JIT` (a one-page `mmap` test). Use
the fast path only if both succeed; otherwise the mprotect path. On A10 this always selects
mprotect.

## Build (task #6, #8)

Separate variant so the JIT-less debs are never overwritten:
- `build_info/mozjs115-jit.mozconfig` — same as the JIT-less one but `--enable-jit`
  (drop `--disable-jit`), and a distinct `MOZ_OBJDIR`.
- recipe emits `libmozjs-115-jit` (or a suffixed package) into `out/` alongside the JIT-less deb.
- Docker: image `procursus-xbuild:bookworm-arm64` survived the restart; the mozjs source tree on
  `procursus-vol-gtk` was cleaned (only `.build_complete` remains), so a fresh extract + patch
  series (0001-0005) is required.

Benchmark plan: a small mozjs JSAPI harness (reuse the on-device JSAPI test from the JIT-less
validation) running (a) a compute micro-loop and (b) a gjs-representative allocation/marshalling
loop, interpreter build vs JIT build, wall-clock on the A10. Report honest deltas incl. any
IC-thrash regression.
