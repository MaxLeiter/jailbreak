# A10 JIT-memory probes (Bun / JavaScriptCore)

What the iPad will and will not let a bare-fakesigned process do with
executable memory, measured before turning `ENABLE_JIT` back on for the iOS Bun
build. Device: iPad7,12 (A10), iPadOS 17.6.1, Dopamine rootless, no
entitlements beyond `ldid -S`.

Build and run any of them:

```sh
xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=16.0 -O1 -o wx-probe wx-probe.c
ldid -S wx-probe
scp wx-probe root@MaxsiPad.local:/var/jb/tmp/ && ssh root@MaxsiPad.local /var/jb/tmp/wx-probe
```

They print unbuffered on purpose — several of these end in SIGBUS, and a
buffered log dies with the process.

## Results (2026-08-06)

`wx-probe.c` — the basics.

| | |
|---|---|
| 128 MB `PROT_NONE` reservation | works |
| `mmap` RWX | **maps** (does not fault, see below) |
| `mmap` `MAP_JIT` | `EINVAL` |
| `mprotect` RW→RX cycles, executing fresh code each round | 5/5 correct |
| `mach_vm_remap` RW alias of an RX page, write via alias | executed by the RX view |
| `mprotect` RW+RX round trip | 2.87 µs |

`rwx-exec.c` — an RWX mapping is a trap: `mmap` succeeds and the first
instruction fetch takes **SIGBUS**. Both plain execute and
execute-then-repatch-in-place die. JSC's stock "write straight through the RWX
pool" path is therefore unavailable, which is what forces the separated W^X
heap.

`jsc-pool-sim.c` — replays `initializeJITPageReservation()` +
`initializeSeparatedWXHeaps()` at the real 128 MB pool size. Steps 1-4 (reserve
RWX, remap the alias, `vm_protect` the exec view to RX, `vm_protect` the alias
to RW) all pass. Step 5, writing through the alias and executing, **SIGBUSes** —
which contradicted the single-page result above and is what `alias-order.c` was
written to explain.

`alias-order.c` — the explanation, and the rule the port is built on:

| variant | result |
|---|---|
| v1 lock protections, then alias-write, then execute | SIGBUS |
| v2 fault the page in through the exec mapping (RW, touch, RX) first | works |
| v3 also execute it through its own mapping first | works |
| v4 v2 plus `vm_protect` `set_maximum` on the alias | works |
| v5 no alias at all, `mprotect` flip per write at pool scale | works |

**iOS will not fault a dirty anonymous page into a fresh executable mapping,
but it will re-protect a page that already has an entry in that mapping.** So
each page of the JIT pool has to pass through the executable mapping as RW
once and be flipped to RX; from then on writes through the RW alias are
executed by the RX view, with no further `mprotect`.

That is why `patches/bun-webkit/0002-ios-separated-wx-jit.patch` does the flip
in `OSAllocator::commit()` (the pool is committed page by page anyway) and why
it leaves the exec view's *maximum* protection at RWX — with the maximum
lowered to RX the way upstream does it, that flip fails.

v5 is the fallback if the alias path ever misbehaves: `ENABLE(MPROTECT_RX_TO_RWX)`
already implements it upstream. It costs a 2.87 µs `mprotect` pair per write
and briefly makes live code writable, which is unsafe with concurrent JIT
threads, so it is not the path we took.

## Acceptance tests

`jsbench.js` and `jitstress.js` are the two that decide whether a build is
good. Run both against the bun under test:

```sh
GIGACAGE_ENABLED=0 TMPDIR=/var/jb/tmp ./bun-jit jsbench.js
GIGACAGE_ENABLED=0 TMPDIR=/var/jb/tmp ./bun-jit jitstress.js
```

`jsbench.js` is the speed check. Compare against the same binary with the JIT
off — `BUN_JSC_useJIT=0` — rather than against an older package, so the only
variable is the JIT. Measured 2026-08-06 on +ios0.5: 435 ms vs 4230 ms, ~9.7x.
The JIT-off number matches the +ios0.4 package (4063 ms), which is the control
that says the win is the JIT and not some other build change.

`jitstress.js` is the correctness check, and it is the one that matters: it
runs each workload hot enough to reach DFG and then verifies answers, covering
tier-up stability, OSR exit on type change, megamorphic inline caches (the
heaviest user of the W^X alias write path), GC under live JIT code, exception
unwinding out of optimised frames, generators, regex and typed arrays.

**Neither of these is sufficient on its own.** Both passed while opencode hung
on the build whose `commit()` hook zeroed pages — the race needed a workload
large enough to have the DFG thread compiling while another thread commits.
Always finish with a real one:

```sh
TMPDIR=/var/jb/tmp opencode --version     # ~1.6s; hangs outright if the JIT is broken
```

When a big workload misbehaves and the small ones don't, bisect with the JSC
options rather than guessing: `BUN_JSC_useJIT=0`, then `BUN_JSC_useDFGJIT=0`
(baseline only), then `BUN_JSC_useConcurrentJIT=0` (DFG, main thread). Which
knobs hide the failure tells you which interaction is at fault.
