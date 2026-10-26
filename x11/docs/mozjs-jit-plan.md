# mozjs 115 JIT on iOS

**Status: built and published, opt-in.** `libmozjs-115-jit-0 115.12.0+ios1` is in the repo. It
`Provides`/`Conflicts`/`Replaces` `libmozjs-115-0`, so installing it swaps the JIT build in under gjs
and GNOME Shell. Nothing depends on it, so a default `xios-gnome` install stays on the JIT-less
build. `libmozjs-115-jit-dev 115.12.0+ios2` installs its headers in the wrong directory (see
[gjs-plan.md](gjs-plan.md)). The JIT-less cross itself is also in gjs-plan.md.

The rest of this file is the de-risk record: what the A10 allows, why no W^X patch was needed, and
the benchmark.

## Device W^X capability, DE-RISKED on-device (2026-07-01)

Probe: `ports/mozjs/tools/wxprobe.c` (compile on-device with the Procursus clang, sign with
`ldid -S ports/mozjs/tools/ent-jit.xml`). Forks each strategy so a codesigning `SIGKILL`/`SIGBUS`
is captured as the child's termination signal. Ran on **iPad7,12 / T8010 / A10 Fusion,
iOS 17.6.1, palera1n rootless**, as a root CLI process.

| strategy | result | meaning |
|---|---|---|
| `pthread_jit_write_protect_np` (dlsym) | **absent** | no APRR fast path on A10 (APRR arrived with A11) |
| `mmap RW` → write → `mprotect RX` → exec | **PASS** | the W^X-compliant flip works, this is our path |
| repeated RW↔RX flips × 1024, exec each | **PASS** | re-patching a live code region is correct |
| `mmap PROT_READ\|WRITE\|EXEC` (persistent RWX) | **SIGBUS** | kernel forbids simultaneously-writable-executable pages |
| `mmap ... MAP_JIT` | **EINVAL (22)** | MAP_JIT rejected on A10, Apple fast-WX alloc is dead here |

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

## W^X source patch: not needed for SpiderMonkey 115

The task assumed 115 hardcodes the Apple fast-WX path on Darwin/arm64 (`MAP_JIT` +
`pthread_jit_write_protect_np`) and would need a runtime-adaptive patch to fall back to mprotect
on the A10. **That is false for 115.** Grepping the extracted 115.12.0 tree
(`js/`, `mozglue/`, `memory/`) for `JS_USE_APPLE_FAST_WX`, `pthread_jit_write_protect_np`,
`MAP_JIT`, and `AutoMarkJitCodeWritableForThread` returns **zero hits**, the Apple fast-WX
machinery was added to SpiderMonkey *after* 115 (it lands around 128). In 115 the POSIX/Darwin
executable-memory path in `js/src/jit/ProcessExecutableMemory.cpp` is **already pure mprotect**:

- `ReserveProcessExecutableMemory`: `mmap(PROT_NONE, MAP_PRIVATE|MAP_ANON|MAP_NORESERVE)`
- `CommitPages(Executable)`: `mmap(PROT_READ|PROT_EXEC, MAP_FIXED|MAP_PRIVATE|MAP_ANON)`
- `ReprotectRegion(Writable/Executable)`: `mprotect(RW)` / `mprotect(RX)` + `FlushICache`

That is exactly the sequence the on-device probe validates (strategy `smpattern` PASSes: reserve
PROT_NONE → commit R+X via MAP_FIXED anon → mprotect RW → write → mprotect RX → execute). So
**the stock 115 JIT build needs no W^X source patch** on this device. Patch 0005 is dropped.

Future optimization (not built): on A11+ the mprotect flip is slower than an APRR toggle would be,
but 115 has no fast-WX path at all, so A11+ also uses mprotect here, correct, just not maximal.
Backporting the fast-WX path from newer SpiderMonkey would be a perf-only change gated on a future
A11+ target; it is not needed for correctness and not needed for our A10.

## The real patch 0005: wasm Mach exception ports (EXC_GUARD), not W^X

The first JIT dylib built and installed fine, but the benchmark harness was **SIGKILL**ed at engine
startup. The crash report showed `EXC_GUARD` / `SET_EXCEPTION_BEHAVIOR` in
`js::wasm::EnsureFullSignalHandlers` → `thread_set_exception_ports`. This is unrelated to W^X/codegen:

- On Darwin, SpiderMonkey's wasm trap handling is entirely **Mach-exception-port** based. At startup
  `wasm::HasPlatformSupport()` calls `EnsureFullSignalHandlers`, which calls
  `thread_set_exception_ports(EXC_MASK_BAD_ACCESS|BAD_INSTRUCTION, ...)`.
- **iOS 14+ guards `thread_set_exception_ports`** (a process can't redirect its own Mach exceptions)
  and kills with `EXC_GUARD`. There is no entitlement that ungates it for third-party binaries.

Fix, `patches/0005-wasm-signal-handlers-ios-no-mach-exc-ports.patch`: on iOS
(`XP_DARWIN && TARGET_OS_IPHONE`), make `EnsureFullSignalHandlers` return false **before** the Mach
call. `HasPlatformSupport()` then returns false (WebAssembly reports unsupported), pure-JS
Baseline/Ion JIT does not use these handlers, so JS JIT is unaffected, and gjs is pure JS. So on iOS:
**wasm is off, JS JIT is on.** (Making wasm work on iOS would mean routing to the POSIX `sigaction`
path instead of Mach ports, future work, not needed for gjs.)

## Benchmark: interpreter vs JIT on the A10 (2026-07-01)

`ports/mozjs/tools/jitbench.cpp` links the JIT dylib and runs each workload with the JIT fully OFF
(pure C++ interpreter) then fully ON (Baseline interp + Baseline JIT + Ion), toggled at runtime via
`JS_SetGlobalJitCompilerOption`, so the delta is purely the JIT. On the A10 (iPad7,12, iOS 17.6.1),
best-of-5, signed with `dynamic-codesigning`:

| workload | interpreter | JIT | speedup |
|---|---|---|---|
| arith-loop (tight integer) | 458.3 ms | 13.9 ms | **32.9×** |
| fib-recursive (calls) | 5133.4 ms | 159.5 ms | **32.2×** |
| obj-prop-string (gjs-like: alloc + property + string) | 994.4 ms | 102.4 ms | **9.7×** |

Checksums match between modes (correctness), and the engine confirms `ion=1 baseline=1
baseline-interp=1`. Honest read: the mprotect W^X flip (~1.1 µs/pair) does **not** eat the gains:
JIT is 10–33× faster. Pure compute hits ~32×; the object/string workload (closest to gjs UI glue,
with GC pressure) is ~10×, the realistic number to expect for GNOME Shell JS. The mprotect path is
fully adequate on the A10; no APRR/fast-WX needed.

Deploy: install `libmozjs-115-jit-0`; it replaces `libmozjs-115-0` and gjs's dependency stays
satisfied. Processes that JIT must carry the `dynamic-codesigning` entitlement for the sandboxed
case; a root CLI process on this jailbreak passes the mprotect gate without it.

## Build

A separate variant so the JIT-less debs are never overwritten: `build_info/mozjs115-jit.mozconfig`
is the JIT-less mozconfig with `--enable-jit` and its own `MOZ_OBJDIR`. Patches 0001-0005 are one
shared series (`x11/ports/mozjs/patches/series`). The build volume that held the mozjs tree has been
pruned, so any rebuild is a full extract and cross again.
