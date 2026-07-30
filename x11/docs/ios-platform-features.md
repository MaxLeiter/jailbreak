# iOS platform features we should be using (probed on device 2026-07-29)

Three tracks came out of a survey of iOS platform APIs the port does not yet
touch: process confinement, display-paced presentation, and jetsam/thermal
reaction. Everything below was measured on the target hardware (iPad7,12, A10 /
T8010, iPadOS 17.6.1, Dopamine rootless) with throwaway fakesigned probes, not
read off headers. Probe sources are in the session scratchpad; the numbers are
what matters and they are recorded here.

Each track has its own implementation chip. This file is the shared contract so
the three do not invent three different mechanisms for the same thing.

---

## 0. The visibility contract (read this before implementing any track)

All three tracks change behaviour at runtime in ways a user would otherwise
experience as unexplained slowness or an app mysteriously failing to write a
file. Every one of them MUST announce itself. One mechanism, three producers:

**Producer side.** A single call in iosc:

```c
/* iosc_status.h */
void iosc_status_set(const char *key, const char *fmt, ...);  /* latched state */
void iosc_status_event(const char *key, const char *fmt, ...); /* transient */
```

- `key` is a stable slug: `sandbox`, `thermal`, `memory`, `pacing`, `upscale`.
- Latched state is what a status reader shows now; events go to the log only.
- Both always write one line to stderr tagged `[status]` regardless of consumers,
  so a headless SSH session sees it with no extra tooling.

**Consumer side, in order of how much work they are:**

1. **stderr**, free, always on. `[status] thermal=serious fps=60->30`.
2. **`ioscd status`** over the existing control socket
   (`/var/jb/tmp/ioscd.sock`, see `apps/iosc-desktop/src/ioscd.c`) — dumps the
   latched key/value table. This is the one to build first; it is a few lines
   next to the existing verbs and makes the state scriptable from SSH.
3. **iosc-shell panel indicator** (`x11/apps/iosc-shell`) — a small glyph per
   non-nominal key. Thermal and memory are the two a user actually needs to see
   live; `sandbox` is better as a startup line than a permanent glyph.

Rule: no track may ship a behaviour change with only #1. #2 is the minimum bar,
because "did the compositor drop to 30fps or is it actually stuttering?" has to
be answerable without a rebuild.

---

## 1. Process confinement: usable, with one hard constraint

### What is NOT available

SBPL profile compilation is **refused on iOS**, despite the symbols being
exported from `libsandbox`:

```
sandbox_compile_string        = 0x1f44a11c0   (symbol present)
compile(trivial deny-default) = FAILED err=profile compilation not supported on this platform
```

So: no custom profiles, no `.sb` files, no `sandbox-exec` equivalent. Do not
spend time here. `sandbox_compile_string`/`sandbox_apply`/`sandbox_free_profile`
are present-but-dead on this platform.

### What IS available

`sandbox_init_with_parameters(name, SANDBOX_NAMED /* 0x1 */, NULL, &err)` against
a profile **precompiled into the kernel collection** works, and works on an
unconfined root jailbreak process. Of the names probed, two applied and were
genuinely restrictive:

| profile name | `SANDBOX_NAMED` | `NAMED_BUILTIN` (0x3) |
| --- | --- | --- |
| `com.apple.WebKit.WebContent` | **applied + restrictive** | refused |
| `container` | **applied + restrictive** | refused |
| `nosandbox`, `no-internet`, `no-network`, `no-write`, `pure-computation`, `kSBXProfile*`, `WebContent`, `application`, `mobile_application`, `MobileSafari` | refused: "profile not found" | refused |

Note `NAMED_BUILTIN` (0x3) fails where `SANDBOX_NAMED` (0x1) succeeds — use 0x1.

### Capability matrix under `com.apple.WebKit.WebContent`

Baseline vs confined, same binary, same paths (so DENIED is attributable to the
profile and not to a missing file):

| capability | unconfined | confined |
| --- | --- | --- |
| read `/var/jb/usr/lib/*.dylib` | OK | **OK** |
| read `/var/jb/usr/share/fonts` | OK | **OK** |
| read `/var/jb/etc` | OK | **OK** |
| read `/System/Library/Frameworks` | OK | **OK** |
| read `/dev/urandom` | OK | **OK** |
| late `dlopen` from `/var/jb` | OK | **OK** |
| `sysctlbyname("hw.ncpu")` | OK | **OK** |
| `mprotect` RW→RX | OK | **OK** (profile is NOT a W^X guarantee) |
| `socket(AF_UNIX)` | OK | **DENIED** (EPERM) |
| `socket(AF_INET)` | OK | **DENIED** (EPERM) |
| write `/var/jb/tmp` | OK | **DENIED** (EPERM) |
| `kill(1, 0)` / cross-process poking | OK | **DENIED** (EPERM) |

This shape is close to ideal for a browser content process: it keeps every read
the renderer needs, and takes away network, new sockets, filesystem writes, and
process inspection.

### The hard constraint

`socket()` is denied outright, so **confinement must be applied after the IPC
file descriptor is inherited, not before.** Inherited fds keep working; creating
new ones does not. That means:

- parent creates the `socketpair()`, `posix_spawn`s the child with the fd,
- child applies the profile as the *first* thing in `main()`, before it parses
  any untrusted bytes,
- anything the child needs to *write* must be an inherited fd or come from the
  parent (this is why the write denial is survivable — but it has to be
  designed for, and a naive "confine everything" patch will break caches).

`mprotect` RW→RX still being allowed is worth knowing: the profile does not buy
W^X. It does not matter for Ladybird because LibJS is JIT-less on this port, but
do not describe the profile as preventing code injection.

---

## 2. Graphics: display pacing, and MetalFX spatial upscaling is available

### Display pacing (P0.4's remaining half)

`perf-followup-backlog.md` P0.4 is PARTIAL: repaint is coalesced per event-loop
turn but never pinned to display refresh. The APIs for the missing half are
entirely unused in the tree (zero hits for `targetTimestamp`,
`addPresentedHandler`, `presentedTime`, `preferredFrameRateRange`):

- `CADisplayLink.targetTimestamp` is the deadline for the frame being built. Sent
  back over the existing dirty/present channel, iosc's coalesced repaint becomes
  vblank-paced instead of event-loop-paced.
- `MTLDrawable.addPresentedHandler` → real `presentedTime`, which is what the
  Wayland presentation-time protocol should report. Today iosc sends feedback
  post-repaint, not post-present.
- `XScreen.swift:323` uses `preferredFramesPerSecond`, which the SDK marks
  `API_DEPRECATED_WITH_REPLACEMENT("preferredFrameRateRange")`. The replacement
  takes a min/max/preferred `CAFrameRateRange`, so CoreAnimation can settle
  within a range instead of the current hard flip between 20 and 60 at
  `XScreen.swift:396` and `:451`.

### MetalFX: spatial scaler says YES on the A10

This was the surprise, and it inverts the guess that MetalFX needs recent
silicon:

```
device   = Apple A10 GPU
families = Apple1 Apple2 Apple3 Common1 Common2
MTLFXSpatialScalerDescriptor   supportsDevice = YES
MTLFXTemporalScalerDescriptor  supportsDevice = NO
```

Spatial upscaling is available on the actual target device. For a 2160x1620
panel driven by an A10, compositing the desktop at a fraction of native and
letting MetalFX scale to the panel is a large, cheap win — and it is a
present-side change in `XScreen.swift`, invisible to every Wayland client. The
temporal scaler is unavailable, so no motion-vector work is possible or needed.

Other measured numbers: `hasUnifiedMemory = 1`,
`recommendedMaxWorkingSetSize = 2048 MiB`.

Visibility requirement: upscaling changes what the user sees. `upscale=1440x1080->2160x1620`
must be in the status table, and it should be switchable at runtime, not
compile-time.

---

## 3. Jetsam and thermals: unexplored, and the device is already hot

Zero hits in the tree for `thermalState`, `MEMORYPRESSURE`, or
`os_proc_available_memory`. All three are public and exported. The measured
state, on an idle device with no desktop session running:

```
os_proc_available_memory = 1848 MiB
physicalMemory           = 2996 MiB
thermalState             = serious      <-- idle!
lowPowerMode             = 0
activeProcessorCount     = 2 / 2
```

`thermalState = serious` at idle is the headline. The A10 is thermally
constrained before the compositor does anything, so a fixed 60fps present target
is fighting the hardware. There is currently no signal feeding back from thermal
state to frame rate at all.

What to wire:

- `ProcessInfo.thermalState` + `NSProcessInfoThermalStateDidChangeNotification`
  → clamp the `preferredFrameRateRange` from track 2. `serious` should mean a
  lower ceiling, not a stutter the user cannot explain.
- `ProcessInfo.isLowPowerModeEnabled` → same lever.
- `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` → drop the per-surface GL texture caches
  from P0.2 and mark occluded windows' IOSurfaces
  `kIOSurfacePurgeableVolatile` via `IOSurfaceSetPurgeable`, instead of letting
  jetsam kill the entire session.
- `os_proc_available_memory()` → check headroom before allocating another output
  IOSurface; a desktop that refuses a new window beats one that dies.

Visibility requirement: this is the track where silent behaviour change is worst.
A user whose desktop just dropped to 30fps and threw away texture caches must be
able to see `thermal=serious` and `memory=pressure-warn caches-dropped` rather
than concluding the compositor is broken.

---

## Sequencing

Track 1 (confinement) is independent — it touches Ladybird packaging and nothing
in the compositor.

Tracks 2 and 3 both touch `XScreen.swift` and the present/dirty protocol, and
track 3's frame-rate clamp is meaningless until track 2 replaces the deprecated
fixed-fps call. **Track 2 lands first, then track 3.** Running them concurrently
would put two owners in the same files, which the agent-brief checklist
explicitly warns against.

The `ioscd status` verb from §0 is a prerequisite for both 2 and 3 and should be
the first commit of track 2.
