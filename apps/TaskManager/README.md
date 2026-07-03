# Task Manager

A native, Activity-Monitor-style **process monitor** for the jailbroken iPad. It
lists every running app and process with live memory and CPU usage — rolling
sparklines per row, a device-wide RAM ring and per-core CPU dashboard — and can
**Quit** (SIGTERM) or **Force Kill** (SIGKILL) app processes.

It reads process stats directly with `libproc`/`sysctl` and `kill(2)`; there is
**no root daemon, no XPC, no launchd job**. The app runs effectively unsandboxed
via the same entitlement shape `apps/KioskMode` already validated on-device
(`platform-application` + `no-container`), which is enough for cross-process
`proc_pidinfo` reads and signalling other `mobile`-owned processes. It's a live
**foreground** monitor: the 1 Hz sampling loop runs only while the app is
frontmost and pauses in the background — not a persistent background daemon.

## Status

| Phase | What | State |
|---|---|---|
| 1 | Scaffold + core engine (sampler / stats / killer / app index) | ✅ |
| 1 | On-device entitlement spike (cross-process reads + kill) | ✅ verified |
| 2 | Dashboard (RAM ring, per-core CPU, overall-CPU trend) | ✅ |
| 2 | Process list (icons, live memory/CPU, sparklines, sort, Apps/System) | ✅ |
| 2 | Detail sheet (CPU/memory charts, metadata, Quit / Force Kill) | ✅ |

The phase-1 spike confirmed the entitlement approach on the device (iPad 7,
iPadOS 17.6.1): running as `mobile` with these entitlements, the engine read 284
processes, pulled real memory/thread counts for processes it doesn't own
(SpringBoard 124 MB / 13 threads, backboardd 43 MB / 16 threads), reported the
correct 3 GB RAM and 2 cores, and `kill(…, 0)` returned **permitted** for
SpringBoard and backboardd. No root helper or stronger entitlement was needed.

## Build & install

Built **unsigned** and run on the jailbroken iPad via AppSync Unified after an
`ldid` pseudo-sign — the generic pipeline used by every app here:

```bash
# from repo root — builds, pseudo-signs, pushes over SSH, registers with uicache
bin/install-app.sh apps/TaskManager
```

Prereqs: `brew install xcodegen ldid`, Xcode, and **AppSync Unified** on the iPad.
`device.env` (repo root) provides `THEOS_DEVICE_IP` / `THEOS_DEVICE_PORT`.

## Develop in the Simulator (no device)

```bash
xcodegen generate
open TaskManager.xcodeproj      # pick an iPad simulator, run
```

The whole UI works in the Simulator — it runs on macOS, so the same `sysctl` /
`proc_pidinfo` calls return the Mac's processes, giving live data to develop
against. (App icon/name matching also works there via `LSApplicationWorkspace`.)

## Layout / architecture

```
Sources/
  App/
    TaskManagerApp.swift    @main App + RootView (starts/stops the engine on scenePhase)
  System/                   the engine — pure Foundation, no UIKit
    ProcessSampler.swift    sysctl(KERN_PROC_ALL) + proc_pidinfo(PROC_PIDTASKALLINFO) → one snapshot
    SystemStats.swift       host_statistics64 (RAM) + host_processor_info (per-core CPU)
    ProcessKiller.swift     kill(SIGTERM/SIGKILL); refuses its own pid and pid ≤ 1
    MonitorEngine.swift     1 Hz loop: diffs samples → CPU rates + history rings, publishes rows
  Model/
    ProcessRow.swift        presented row + the history ring buffer
    InstalledAppsIndex.swift  pid's exec path → installed-app identity (LSApplicationWorkspace)
    AppIcon.swift           real Home Screen icons via private UIKit call (cached)
  Design/
    Theme.swift             resource colors (CPU blue / memory aqua), spacing, formatting
    Card.swift              the raised-surface tile style
  Views/
    ProcessListView.swift   the one screen: dashboard + Apps/System + sort + table
    MemoryRing.swift        RAM gauge
    CpuTile.swift           overall CPU + trend sparkline + per-core meters
    ProcessRowView.swift    one process row (icon, name, memory, CPU, sparkline)
    ProcessDetailView.swift detail sheet: big CPU/memory charts, metadata, kill actions
    Sparkline.swift         the shared Swift Charts line+area primitive
  TMProcInfo.h              libproc/sysctl/mach ABI (no UIKit) — shared syscall surface
  TaskManager-Bridging-Header.h  imports TMProcInfo.h + UIKit + the private LS/UIImage decls
```

### Why the bridging header redeclares libproc

The iOS SDK ships neither `<libproc.h>` nor `<sys/proc_info.h>` (they're
macOS-only), but the symbols exist in `libSystem` at runtime. `TMProcInfo.h`
declares the exact `proc_taskallinfo` / `proc_bsdinfo` / `proc_taskinfo` ABI and
the `proc_pidinfo` / `proc_pidpath` prototypes so Swift can call them (struct
layout is identical across Darwin, copied from the macOS SDK). It's guarded with
`#if __has_include(<sys/proc_info.h>)` so that on a platform where the real
headers exist (a macOS indexing pass) it defers to them instead of colliding.

### Apps vs System

The list segments into **Apps** (a process whose executable matches an installed
bundle) and **System** (everything else). Kill actions are offered for **apps
only** — force-killing system daemons isn't the use case and is needlessly risky
on a live device, so System rows are read-only.

## CPU scale convention

Two CPU numbers, one convention (top-style):

- **Per-process %** is a share of *one* core — a fully single-threaded-busy
  process reads 100%, and a multithreaded one can exceed it (up to cores × 100).
- **The dashboard "avg"** is the mean across cores, 0…100.

They reconcile as `Σ(per-process %) ≈ cores × avg`. Both derive from
mach-absolute-time counters: `PROC_PIDTASKALLINFO`'s `pti_total_*` are in
mach units (verified on device — *not* nanoseconds), and `mach_absolute_time()`
reports the wall clock in the same units, so per-process % is a unitless ratio
of the two deltas with no timebase conversion.

The entitlement approach and this CPU-unit fact were validated on-device with a
throwaway CLI harness (built with `swiftc`, ldid-signed, run as `mobile`); the
harness isn't kept in the tree since the shipping app now exercises the same
paths live.
