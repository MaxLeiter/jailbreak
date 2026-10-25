# iOS platform features: what the device offers, and what we use

Three tracks came out of a 2026-07-29 survey of iOS platform APIs the port was not
using: process confinement, display-paced presentation, and jetsam/thermal reaction.
Everything below was measured on the target hardware (iPad7,12, A10 / T8010, iPadOS
17.6.1, Dopamine rootless) with throwaway fakesigned probes, not read off headers.

Section numbers are stable: code comments cite them (`iosc_status.h`, `ioscd.c`,
`xios-status`, `XScreen.swift`, `XiosUpscale.swift`, `iosc.c`), so add new material
under a new number instead of renumbering.

| track | status (2026-10-25) |
| --- | --- |
| §0 visibility contract | **landed.** `iosc_status` + `xios-status` + ioscd `STATUS`. The panel indicator is not built. |
| §1 process confinement | **closed: impossible for Ladybird.** Both usable profiles break its helpers. See `ladybird-sandbox-confinement.md`. |
| §2 display pacing + MetalFX | **landed and device-tested** (closes perf P0.4). MetalFX ships opt-in, default off. |
| §3 jetsam and thermals | **open.** The seams exist, but nothing reads `thermalState` or memory pressure yet. |

---

## 0. The visibility contract

All three tracks change behaviour at runtime in ways a user would otherwise
experience as unexplained slowness or an app mysteriously failing to write a file.
Every one of them must announce itself, through one mechanism.

**Producer side** (`x11/apps/shared/iosc_status.{h,c}`, linked into both iosc and
Xios.app):

```c
void iosc_status_set(const char *key, const char *fmt, ...);   /* latched state */
void iosc_status_event(const char *key, const char *fmt, ...); /* transient, log only */
```

- `key` is a stable slug: `sandbox`, `thermal`, `memory`, `pacing`, `upscale`.
- Both always write one `[status] key=value` line to stderr, so a headless SSH
  session tailing `iosc.log` sees every change with no extra tooling.
- Latched state goes to one sidecar file per producer,
  `$XIOS_STATUS_DIR/<producer>.status` (default `<runtime tmp>/xios-status.d`),
  rewritten whole via temp+rename. There is one file per producer because the
  producers are separate processes running as different users (iosc as root,
  Xios.app as mobile), and a shared file would need cross-user locking.

**Consumer side, in order of how much work they are:**

1. **stderr.** Free and always on.
2. **`xios-status`** (`x11/apps/iosc-desktop/xios-status`), which asks ioscd's
   `STATUS` verb over `/var/jb/tmp/ioscd.sock` and falls back to reading the
   sidecars directly. `xios-status pacing` filters by key prefix. This is distinct
   from `xios-session status`, which reports which desktop is up, not how it is
   behaving.
3. **An iosc-shell panel indicator. Not built.** Thermal and memory are the two a
   user needs to see live once §3 exists; `sandbox` would be a startup line, not a
   glyph.

Rule: no track may ship a behaviour change with only #1. #2 is the minimum bar,
because "did the compositor drop to 30fps or is it actually stuttering?" has to be
answerable without a rebuild.

A healthy session today:

```
Xios       pacing=vblank fps=30-60/60 interval=16.66ms
Xios       upscale=off
iosc       pacing=vblank fps=60 range=30-60 interval=16.66ms
```

Both producers publish `pacing` under their own names, so "the app is offering a
display clock" and "the compositor accepted one" can be told apart.

---

## 1. Process confinement: what the platform offers

The Ladybird follow-up (`ladybird-sandbox-confinement.md`, measured 2026-08-02)
closed this track: neither usable profile can host a Ladybird helper. The platform
facts below still hold and are why.

### Not available: custom profiles

SBPL profile compilation is **refused on iOS**, although `libsandbox` exports the
symbols:

```
sandbox_compile_string        = 0x1f44a11c0   (symbol present)
compile(trivial deny-default) = FAILED err=profile compilation not supported on this platform
```

So there are no custom profiles, no `.sb` files, and no `sandbox-exec` equivalent.
`sandbox_compile_string`, `sandbox_apply` and `sandbox_free_profile` are present but
dead on this platform. (The compiler's real ABI is three arguments; calling it with
two segfaults, which is a red herring on the way to this answer.)

### Available: precompiled named profiles

`sandbox_init_with_parameters(name, SANDBOX_NAMED /* 0x1 */, NULL, &err)` against a
profile **precompiled into the kernel collection** works, including on an
unconfined root jailbreak process. Of the names probed, two applied and were
genuinely restrictive:

| profile name | `SANDBOX_NAMED` | `NAMED_BUILTIN` (0x3) |
| --- | --- | --- |
| `com.apple.WebKit.WebContent` | **applied, restrictive** | refused |
| `container` | **applied, restrictive** | refused |
| `nosandbox`, `no-internet`, `no-network`, `no-write`, `pure-computation`, `kSBXProfile*`, `WebContent`, `application`, `mobile_application`, `MobileSafari` | refused: "profile not found" | refused |

`NAMED_BUILTIN` (0x3) fails where `SANDBOX_NAMED` (0x1) succeeds, so use 0x1.

### First-pass matrix under `com.apple.WebKit.WebContent`

Baseline vs confined, same binary, same paths, so a DENIED is down to the profile
and not a missing file:

| capability | unconfined | confined |
| --- | --- | --- |
| read `/var/jb/usr/lib/*.dylib` | OK | **OK** |
| read `/var/jb/usr/share/fonts` | OK | **OK** |
| read `/var/jb/etc` | OK | **OK** |
| read `/System/Library/Frameworks` | OK | **OK** |
| read `/dev/urandom` | OK | **OK** |
| late `dlopen` from `/var/jb` | OK | **OK** |
| `sysctlbyname("hw.ncpu")` | OK | **OK** |
| `mprotect` RW→RX | OK | **OK** (the profile is NOT a W^X guarantee) |
| `socket(AF_UNIX)` | OK | **DENIED** (EPERM) |
| `socket(AF_INET)` | OK | **DENIED** (EPERM) |
| write `/var/jb/tmp` | OK | **DENIED** (EPERM) |
| `kill(1, 0)` / cross-process poking | OK | **DENIED** (EPERM) |

This matrix looked close to ideal for a browser content process, but it did not
test the wait primitives. The follow-up did. WebContent also denies `poll()`,
`select()` and `kevent()`, so a process built on an fd event loop cannot wait for
events at all. `container` allows those, but WebContent cannot allocate its paint
backing store under it, and ImageDecoder cannot pass Mach port descriptors. Both
failures are architectural. The full matrix for both profiles is in
`ladybird-sandbox-confinement.md`, along with the synthetic probe that briefly said
`container` worked and why it was wrong.

Two facts outlive the Ladybird verdict and apply to anything else that tries this:

- Confinement has to be applied **after** IPC descriptors are inherited, as the
  first thing in the child's `main()`. Inherited fds keep working; new sockets do not.
- `mprotect` RW→RX survives, so do not describe either profile as preventing code
  injection.

### What to do instead

The fallback is uid separation, `setrlimit`, and entitlement minimisation. The
entitlement part is done: `task_for_pid-allow` and `com.apple.system-task-ports`
were removed from the Ladybird helper entitlements on 2026-07-29. Running the
root-run `ladybird-wayland` helpers as `mobile` is the cheapest real mitigation
left. `ladybird-sandbox-confinement.md` has the detail.

---

## 2. Graphics: display pacing, and MetalFX spatial upscaling

### Display pacing (closes perf P0.4)

Landed 2026-07-29 and device-tested. Repaint used to be coalesced per event-loop
turn but never pinned to display refresh. Now:

- `CADisplayLink.targetTimestamp` is sent back over the dirty/present channel, so
  iosc's coalesced repaint is vblank-paced (`pacing=vblank`). Until an app offers a
  clock, iosc reports `pacing=event-loop (no display clock from the app)`. That is
  the normal start of the state machine, not a warning.
- The `presentedTime` ack comes from `MTLDrawable.addPresentedHandler`, so the
  Wayland presentation-time feedback reports when the frame actually reached the
  panel instead of the post-repaint moment. There is deliberately no second ack
  path: iosc's 100ms present-ack valve covers a drawable whose handler never runs.
  `refresh_ns` comes from the real display interval, so a throttled 30 Hz session
  is no longer reported to clients as 60.
- `preferredFramesPerSecond` is gone. The frame rate is a `CAFrameRateRange`
  (`liveFrameRate` 30-60/60, `holdingFrameRate` 10-20/20) applied through **one**
  `setPacingRange()` seam in `XScreen.swift`. That seam is the lever §3 clamps, so
  do not turn it back into a fixed number (`Xios/INVARIANTS.md` #4).
- The native flavor's host (`iosc-host/HostScreenView.swift`) asks for the same
  30-60 range but has no shared output surface, so it has no `targetTimestamp`
  feedback. Pacing it properly means per-window pacing state on the native-frame
  records, which is a separate change.

**Clock trap, measured.** `CACurrentMediaTime`, `mach_absolute_time` and
`CLOCK_UPTIME_RAW` agree to within a microsecond, but Darwin's `CLOCK_MONOTONIC` was
204.6 s ahead of them (and `CLOCK_MONOTONIC_RAW` 267.5 s ahead), because it also
counts time the device spent asleep. The gap grows with every sleep, so it cannot
be calibrated once. `wp_presentation` advertises `CLOCK_MONOTONIC`, so the app
reports its present as an *age* at ack time and iosc subtracts it on its own clock
(`presentation_timestamp()` in `iosc.c`). Anything new that carries a CoreAnimation
timestamp across processes must do the same, or it will be off by minutes.

### MetalFX: the spatial scaler works on the A10

This inverts the assumption that MetalFX needs recent silicon:

```
device   = Apple A10 GPU
families = Apple1 Apple2 Apple3 Common1 Common2
MTLFXSpatialScalerDescriptor   supportsDevice = YES
MTLFXTemporalScalerDescriptor  supportsDevice = NO
```

Other measured numbers: `hasUnifiedMemory = 1`,
`recommendedMaxWorkingSetSize = 2048 MiB`. Probe Metal with the GPU entitlements
(`x11/wayland/iosc-gl-ent.xml`): a plain fakesigned probe gets
`MTLCreateSystemDefaultDevice() == nil` and looks like a false negative.

It shipped as present-side upscaling in `XiosUpscale.swift`, weak-linked and gated
on the runtime `supportsDevice` call, never on a GPU-family check. It is **off by
default, and that is the right default at the shipping geometry.** iosc ships
logical 1440x1080 at scale 2, a 2880x2160 surface the app fits onto the 2160x1620
panel. That 0.75 downscale is supersampling, so routing it through a smaller
intermediate throws away detail and then reconstructs it, and only saves work in
the app's present pass (the compositor still draws all 6.2M pixels). `auto`
correctly declines here. The win that pays needs the compositor to draw fewer
pixels (a lower `IOSC_LOGICAL`, or scale 1), which changes `wl_output` scale. HiDPI
clients see that, so it is a session-geometry decision, not a present-side toggle.
Sequence it after §3, which will produce frame-time numbers.

Switches, most specific first: the in-app **Xios → Render Scale** chips
(UserDefaults, applies on the next frame), then `XIOS_UPSCALE` in the app's
environment, then `IOSC_UPSCALE=auto|<factor>` on the compositor, forwarded via
`xios.json`. That last one is the production path, since FrontBoard gives the app no
environment. The live state is `upscale=` in `xios-status`, including when `auto`
declined and when the GPU has no spatial scaler.

---

## 3. Jetsam and thermals: still open

Nothing in the tree reads `ProcessInfo.thermalState`, `isLowPowerModeEnabled`,
`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` or `os_proc_available_memory()`. All of them
are public and exported. The measured state, on an idle device with no desktop
session running:

```
os_proc_available_memory = 1848 MiB
physicalMemory           = 2996 MiB
thermalState             = serious      <-- idle!
lowPowerMode             = 0
activeProcessorCount     = 2 / 2
```

Two follow-up measurements change how this should be wired:

- **`serious` is this device's floor, not a warning.** Sampled every 5 s for 60 s
  across a live KDE session (load average peaking around 5.6 on 2 cores), it never
  moved. A clamp keyed on `serious` runs permanently, and one keyed on `critical` is
  probably inert here. Pick the threshold deliberately, from measurement.
- **`os_proc_available_memory()` is a per-process budget, not a pressure signal.**
  It works in a plain daemon, not only in apps, but a fresh process reports the same
  ~1848 MiB whatever else is running. Use it for "can this allocation fit at all"
  and `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` (system-wide) for "is the system under
  pressure".

What to wire, now that §2 has provided the seams:

- `thermalState` + `NSProcessInfoThermalStateDidChangeNotification`, and
  `isLowPowerModeEnabled`, clamp the range passed to `setPacingRange()` in
  `XScreen.swift` (and the matching range in `HostScreenView.swift`). Lower the
  ceiling; never fall back to a fixed fps.
- `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` drops the per-surface GL texture caches from
  perf P0.2 and marks occluded windows' IOSurfaces `kIOSurfacePurgeableVolatile` via
  `IOSurfaceSetPurgeable`, instead of letting jetsam kill the whole session.
- `os_proc_available_memory()` checks headroom before allocating another output
  IOSurface. A desktop that refuses a new window beats one that dies.

Visibility requirement: this is the track where a silent behaviour change is worst.
A user whose desktop just dropped to 30fps and threw away its texture caches must be
able to see `thermal=...` and `memory=pressure-warn caches-dropped` in `xios-status`
rather than conclude the compositor is broken. Free tooling worth using while
measuring: `MTL_HUD_ENABLED=1` (system frame-time/FPS/memory overlay, iOS 16+, no
code) and `os_signpost` intervals for Instruments.
