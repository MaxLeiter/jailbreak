# Calendar-alarm BFU wake storm — RE + hook design

Reverse-engineering notes for the iPadOS 17.6.1 (21G93) battery bug where a calendar
alarm wakes the device roughly every 60 s while it is **Before First Unlock (BFU)**.
Research + hook design only; nothing was installed, and no device state was changed
(reads/copies over SSH only).

Device: iPad7,12 (A10, arm64), iPadOS 17.6.1, Dopamine rootless `/var/jb`, ElleKit.

**Convention below:** "FACT" = directly observed in logs/disassembly/plists. "INFERENCE"
= reasoned from those. Addresses are unslid dyld-shared-cache vaddrs unless noted;
`com.apple.alarm` plugin addresses are file offsets in the bundle Mach-O (its preferred
base is 0, so file offset == vaddr there).

Materials gathered (gitignored, under `cal-bfu/`):
- `bin/` — device binaries: `/usr/libexec/UserEventAgent`, the
  `com.apple.alarm.plugin/com.apple.alarm` plugin, `calaccessd`
  (`…/CalendarDaemon.framework/Support/calaccessd`), `MobileKeyBagLockState`,
  `com.apple.cfnotification`.
- `dylibs/` — `CalendarNotification` and `CalendarDaemon` extracted from the device's
  own dyld shared cache (`tweaks/_research/dsc-17.6.1-iPad7,12/`, copied by the wifi-re
  agent; file-size-verified identical to the device's
  `/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/`).
- `dis/` — `ipsw`/`otool` disassembly of the functions cited here.
- `plists/` — `com.apple.calaccessd.plist`, `com.apple.alarm.plugin/Info.plist`, the
  merged `/System/Library/xpc/launchd.plist`, `CalendarDaemon` Info/sandbox.
- Log evidence is from the persisted logarchive at
  `…/scratchpad/probe/dev.logarchive` (covers ~Sep 8 – Oct 1 2026).

---

## 1. Who re-arms the alarm for now+60 s

**Answer: (b) — the UserEventAgent `com.apple.alarm` XPC-alarm plugin re-arms it, by its
own built-in throttle, because the client that owns the alarm (`calaccessd`) is not
running in BFU and therefore never advances the alarm's fire date.** It is *not* (a):
`calaccessd` plays no part during the BFU storm.

### 1.1 The observed per-cycle sequence (FACT)

One BFU cycle, Sep 16 10:03 (archive; all processes, `calaccessd`/xpcproxy/launchd
included — none appear except UserEventAgent and powerd):

```
10:03:27.383 UserEventAgent[31] [com.apple.xpc.alarm:All] Firing event "com.apple.calaccessd.alarmEngine.alarm.name" which was due 0 sec ago.
10:03:27.383 UserEventAgent[31] … power_create_temporary_fire_assertion: name <private>, ret: 0, id: -2140995584
10:03:27.384 UserEventAgent[31] … Alarm event "com.apple.calaccessd.alarmEngine.alarm.name" is fired and active.
10:03:27.386 UserEventAgent[31] … Removing alarm "com.apple.calaccessd.alarmEngine.alarm.name"
10:03:27.386 UserEventAgent[31] … Adding  alarm "com.apple.calaccessd.alarmEngine.alarm.name"
10:03:27.386 UserEventAgent[31] … Resetting <private> job "com.apple.calaccessd.alarmEngine.alarm.name", now due in 60 seconds.
10:03:27.387 UserEventAgent[31] … Setting timer for "com.apple.calaccessd.alarmEngine.alarm.name" in 59 seconds.
10:03:27.387 UserEventAgent[31] … Reply received for alarm '<private>' 1749/2 with power assertion -2140995584.
10:03:30.484 powerd[47] [com.apple.powerd:wakeRequests] Selected RTC wake request:
    { UserVisible = 0; appPID = 31; eventtype = wake;
      scheduledby = "com.apple.alarm.user-invisible-com.apple.calaccessd.alarmEngine.alarm.name";
      time = "2026-09-16 17:04:27 +0000"; }   # = now + 60 s
```

Then the device idle-sleeps and ~60 s later wakes `due to AOP.OutboxNotEmpty rtc`, and
the cycle repeats. All of these lines come from `UserEventAgent[31]` (the System
instance, `/usr/libexec/UserEventAgent`) — confirmed by `processImagePath` and by the
plugin's own strings. `appPID = 31` on the powerd wake request is UserEventAgent, not
calaccessd.

### 1.2 calaccessd is NOT running during BFU (FACT)

- `com.apple.calaccessd.plist` (`plists/`) has **no** `com.apple.xpc.alarm` entry under
  `LaunchEvents` — its launch events are only `com.apple.notifyd.matching` (a set of
  Darwin notifications, incl. `com.apple.mobile.keybagd.first_unlock`) and
  `com.apple.xpc.activity` (six daily maintenance activities). So the firing of
  `com.apple.calaccessd.alarmEngine.alarm.name` does **not** launch-on-demand
  calaccessd. `EnablePressuredExit = true`, so it exits under memory pressure.
- Across the whole archive, `calaccessd`'s **first** log line of *any* level is
  `2026-09-21 14:16:35`, which is the same minute the device first unlocks
  (see §2). During the Sep 8–21 BFU window it logs nothing and no `xpcproxy`/
  `runningboardd` spawn for it appears. INFERENCE: calaccessd is simply not alive in
  BFU; it is a running-only (not alarm-launch-on-demand) consumer of the alarm stream.
- The alarm registration therefore predates and outlives calaccessd: it lives in
  UserEventAgent's address space (pid 31 ran continuously from before the archive start
  until the Oct 1 userspace reboot — same pid throughout), as token `1749`.

### 1.3 Where the 60 s is computed (FACT — disassembly of the plugin)

The plugin is `…/UserEventPlugins/com.apple.alarm.plugin/com.apple.alarm`
(`CFBundleIdentifier = com.apple.alarm`, `XPCEventModuleInitializer = init_alarm_module`,
`LimitLoadToSessionType = System, Aqua`). It is a stripped C bundle; the interesting
routines are **non-exported local functions** (only `init_alarm_module`,
`power_set_handler`, `power_is_ac`, `clock_set_handler`, `clock_mach_time_dilation` and
data `_alarm_tree_ops` are in the symbol table — `nm -m`). Function names below are my
labels for `sub_XXXX`.

- The plugin keeps three red-black trees of alarm records (`init_alarm_module` inits
  three `_alarm_tree_ops` trees of stride 0x40, one per clock domain). Each record:
  `+0x10` = event-name C string, `+0x18` = UserVisible byte, `+0x19` = Walltime flag,
  `+0x1c` = clock type (0 wall / 1 uptime / 2 monotonic), `+0x20` = due time,
  `+0x28` = "fired & active" flag.
- **Reply/throttle handler** `sub_25f4` (reached from the fire path's reply block
  `sub_28e4`/`sub_2934`) is where the 60 s is produced:

```
0x26a0  ldr   x8, [x21, #0x20]      ; alarm.dueTime
0x26a4  cmp   x8, x0                ; x0 = now (sub_2390 → clock_gettime_nsec_np)
0x26a8  b.hi  loc_26e0              ; if dueTime > now: leave as-is
0x26ac  mov   x8, #0x5800 ; movk 0xf847<<16 ; movk 0xd<<32   ; = 0x0000000d_f847_5800
0x26b8  adds  x8, x22, x8           ; x22 = now  →  newDue = now + 59_999_997_952 ns ≈ 60 s
0x26bc  str   x8, [x21, #0x20]
…       "Resetting %s job \"%{public}s\", now due in %lld seconds."   (0x276c)
```

  i.e. when the fired alarm's stored due-time is still ≤ now (because nobody advanced
  it), the plugin **adds a hard-coded ~60 s** and re-arms. `0x0d_f847_5800` =
  59,999,997,952 ns ≈ 60 s (FACT, decoded from the immediate).
- **Wake scheduler** `sub_1840` / its tail (the `sub` ending at the IOPMRequestSysWake
  call, 0x2990 region) builds a `CFMutableDictionary` whose values include the alarm's
  event-name string and the wall-clock date, and calls
  **`IOPMRequestSysWake(CFDictionaryRef)`** (0x2c14) to arm the RTC wake, logging
  `Scheduled wake for %.1fs on behalf of "%{public}s"` (0x3f18) or, on failure,
  `Unable to schedule wake … IOPMRequestSysWake() returned %d` (0x3eb9). This is the
  call that produces the powerd `Selected RTC wake request … now+60 s`.

### 1.4 Why it stops after first unlock (FACT + INFERENCE)

After first unlock calaccessd finally launches (§2) and registers the alarm-stream
handler and re-arms the alarm with the *real* next fire date. Chain, confirmed by
disassembly of `CalendarNotification` (the `_EKAlarmEngine`) and `CalendarDaemon`
(`CADServer`) plus AFU logs:

- `-[CADServer activate]` → block `0x1b7937d8c` calls `_registerForAlarmEvents`
  (0x1b793806c). `-[CADServer _registerForAlarmEvents]` (0x1b7939454) calls
  `xpc_set_event_stream_handler` for the alarm stream (0x1b7939518) and sends
  `didRegisterForAlarms` to each module. Its handler block `0x1b79395e4` forwards each
  fire via `receivedAlarmNamed:` (logs `Alarm triggered with name: … Triggered date:`
  and `Forwarded alarm named: … to module:` — both persisted AFU).
- `-[_EKAlarmEngine receivedAlarmNamed:]` (0x200fbd2c8) → `_timerFired` (0x200fbf420) →
  `_rescheduleTimer` (0x200fbeb08) → `_installTimerWithFireDate:` (0x200fbefc8), which
  calls **`xpc_set_event("com.apple.calaccessd.alarmEngine.alarm.name", dict)`** with
  `kAlarmStreamDateKey` / `com.apple.calaccessd.alarmEngine.alarm.context.date` set to
  the next real fire date (0x200fbf0d8). That `xpc_set_event` is what drives the
  plugin's registration handler `sub_143c` to re-register the alarm with a **future**
  Date, so the plugin no longer throttles and the RTC wake jumps far ahead.
- `-[_EKAlarmEngine _rescheduleTimer]` reads the next fire time from the **side table**
  (`+[EKSideTableContext sideTableContext]` → `-[EKSideTableContext nextAlarmFireTime]`,
  Core Data fetch `fireTime > now`). The side table is `Extras.db` (see §2).
- INFERENCE: the stale registration that fires in BFU was written by `xpc_set_event`
  during a prior *unlocked* session; once its Date passed with calaccessd not running,
  the plugin's self-throttle (§1.3) took over and looped. Nothing re-advances it until
  a live client calls `xpc_set_event` again — which only happens after unlock.

### 1.5 Why the body is empty / counts (FACT)

Per-day count of `Firing event "com.apple.calaccessd.alarmEngine.alarm.name"`:

```
BFU: Sep15 137  Sep16 338  Sep17 329  Sep18 284  Sep19 1387  Sep20 1412  Sep21 818
AFU: Sep22 3  Sep23 3  Sep24 2  Sep25 2  Sep27 1  Sep28 2  Sep29 3  Sep30 3  Oct01 2
```

(Matches the premise of 186–1418/day in BFU, 0–6/day AFU.) The variation 284–1412 in
BFU tracks whether the device also had other sleep/wake activity; the floor is ~1/min.

---

## 2. Device-specific or universal?

**INFERENCE: this is a generic iOS 17 mechanism that will reproduce on any iOS 17
device that (a) has at least one future calendar alarm registered and (b) stays in BFU
long enough, but it is *amplified* here by a stale/past-due registration. It is not
caused by the jailbreak.** Evidence:

- **Not the jailbreak.** Every actor in the loop (UserEventAgent `com.apple.alarm`
  plugin, powerd RTC wakes, calaccessd launch gating on first unlock) is stock Apple
  code. No `/var/jb`, Dopamine, or ElleKit process appears anywhere in the BFU cycle;
  the only jailbreak activity in the archive is the Dopamine app + sshd + the
  `jbctl`-initiated **userspace reboot at Oct 1 17:51** (the one re-jailbreak), well
  after all the BFU storms. (FACT)
- **The mechanism is structural.** calaccessd is the only consumer of
  `com.apple.calaccessd.alarmEngine.alarm.name`, it is *not* alarm-launch-on-demand
  (plist, §1.2), and it cannot open the class-C-protected `Calendar.sqlitedb` in BFU.
  So on any iOS 17 device, a calendar alarm that comes due while in BFU has no client to
  consume/advance it, and the plugin's generic ≤60 s re-fire throttle (§1.3) applies.
  The `com.apple.alarm` plugin version string is `UserEventAgent-328.100.1`; the plugin
  binary is Apple's unmodified `17.6 (21G65)` build. (FACT for this device; INFERENCE
  for "any iOS 17".)
- **What makes this device fire so often** is that it sat in BFU for ~6 days with a
  registered alarm whose Date was already in the past. First-unlock timeline (FACT, from
  wifid `__WiFiManagerSetEnableState … unlockedSinceBoot`): FALSE from `2026-09-15
  14:12:32`, flips TRUE at `2026-09-21 14:16:20`; calaccessd's first log is
  `2026-09-21 14:16:35`. The storm runs exactly across the FALSE span.
- **Side-table contents (FACT)** — `Extras.db` `ZALARM`/`ZSETTING` (copied read-only):
  `CacheEndDate = 2026-10-06 20:14:19`, 30 future alarm rows (`2026-09-22 … 10-06`),
  all with `ZACKNOWLEDGEDDATE` set and `ZREFIRING` null. These rows are the *populated*
  (AFU) state; the store file's mtime jumps only after unlock. The alarm times are
  recurring daily entries (e.g. 06:30, 09:56, 11:50, 12:50, 13:50), i.e. ordinary
  repeating calendar events — nothing corrupt. INFERENCE: no "broken" event is required;
  any pending recurring alarm suffices.
- **A broken/stale account would worsen it but is not required.** INFERENCE: if the
  stale registration's Date is far in the past, the throttle fires every minute from
  the moment the device enters BFU; with a fresh future Date it would only start firing
  every minute once that Date passed while still in BFU.

Not fully separable from this archive alone: whether a *clean* iOS 17 device with a
single future alarm reproduces the full 1/min storm, vs. only after the alarm's Date
passes in BFU. That needs a second device or a controlled repro (out of scope / not
done).

---

## 3. Minimal, safe fix as tweak hook(s)

Goal: in BFU, stop the per-minute system wake for this alarm, while leaving AFU delivery
completely intact (alarms still fire on time once unlocked; nothing dropped).

### Key constraint that rules out the task's option (a)

**Hooking `calaccessd` cannot fix the BFU storm**, because calaccessd is not running in
BFU (§1.2) — the retry is driven entirely by UserEventAgent. A `calaccessd` hook (e.g.
"when `MKBDeviceUnlockedSinceBoot()==0` don't reschedule") would be dead code during the
exact window we care about. The fix must live in **UserEventAgent** (the `com.apple.alarm`
plugin's host process). FLAG: this contradicts the primary option in the brief; calling
it out rather than acting on it.

### Recommended hook (primary) — suppress the BFU RTC wake in UserEventAgent

- **Process / filter:** inject into `/usr/libexec/UserEventAgent`. ElleKit filter plist:
  `Filter = { Executables = ( "UserEventAgent" ); }` (match by executable, since the
  bundle has no CFBundleIdentifier of its own). The `com.apple.alarm` plugin is loaded
  into this process (System and Aqua UEA instances); pid 31 is the System instance that
  schedules the wakes.
- **Symbol / kind:** hook **`IOPMRequestSysWake`** — an exported C function in
  `IOKit.framework` (it is in the plugin's import list, `otool -L` / `nm -m`:
  `_IOPMRequestSysWake (from IOKit)`). Hook with `MSHookFunction` /
  `EKHook(IOPMRequestSysWake, …)` after resolving it normally (public dlsym/link), **no**
  `MSFindSymbol` needed. Because the tweak is filtered to UserEventAgent only, the hook
  affects nothing else.
- **Inferred signature (FACT from call site, §1.3):** single argument, a CFDictionary:
  `IOReturn IOPMRequestSysWake(CFDictionaryRef description);`
  The dictionary carries the requestor/event-name string (built from
  `com.apple.alarm.user-invisible-com.apple.calaccessd.alarmEngine.alarm.name`) and the
  target CFDate. The powerd `scheduledby` string is exactly this requestor.
- **Behaviour change:** in the hook, read the requestor string out of the dict; if it
  contains `calaccessd.alarmEngine` **and** `MKBDeviceUnlockedSinceBoot() == 0`, return
  `kIOReturnSuccess` **without** calling the original (skip arming the RTC wake).
  Otherwise call the original unchanged. This leaves the plugin's in-memory dispatch
  timer and the alarm registration untouched — so the moment the device unlocks and
  calaccessd re-arms with the real date, normal RTC scheduling resumes. Nothing is lost:
  in BFU the alarm cannot be delivered or shown anyway (screen locked, calaccessd can't
  read the Calendar DB, no notification is posted until AFU), and the event will be
  recomputed/re-fired at/after unlock.
  - BFU check: link `MobileKeyBag` and declare `extern int MKBDeviceUnlockedSinceBoot(void);`
    (symbol `_MKBDeviceUnlockedSinceBoot` present in the cache's MobileKeyBag at
    `0x1b51da71c`; the framework has no on-disk Mach-O, so dlopen
    `/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag` resolved from
    the cache, or link `-framework MobileKeyBag`). Cache its result to 1 once it returns
    1 to avoid repeated calls.

### Alternative hook (if you prefer to kill the retry at the source, not the wake)

- Same process/filter. Target the plugin's **throttle** `sub_25f4` (the
  `Resetting … now due in 60 seconds` path, §1.3) or the wake scheduler `sub_1840`.
  **Kind: non-exported local C functions — their symbols are stripped**, so `MSFindSymbol`
  will *not* find them. You would hook by computing the address from an exported anchor:
  e.g. `MSFindSymbol(plugin_header, "_init_alarm_module")` (exported, at bundle offset
  `0x1298`) then add a fixed delta to reach `sub_25f4` (`0x25f4`) / `sub_1840`
  (`0x1840`) — brittle across iOS updates; pin to this build. In BFU, make the throttle
  a no-op for the `calaccessd.alarmEngine` record (leave `[rec+0x20]` unchanged / mark it
  not-fired) so no new timer/wake is set. More invasive than the `IOPMRequestSysWake`
  hook and relies on offset math, so it is the fallback, not the first choice.

### Fallback (coalesce, not suppress)

- Same `IOPMRequestSysWake` hook, but instead of dropping the BFU wake, rewrite the
  CFDate in the dict to `now + 30 min` (clone the dict, replace the date key, call
  original). Reduces the 1/min storm by ~30x while still guaranteeing periodic wakes.
  Lower risk of "what if a wake really is needed in BFU", higher residual drain. Only
  needed if suppression proves too aggressive in testing.

### Injectability note (FLAG — verify on device)

UserEventAgent is a platform daemon; the device-copied binary shows CS flags
`0x3202 (adhoc,kill,enforcement,library-validation)` and a large entitlement set. Under
Dopamine rootless + ElleKit, injecting a tweak dylib into a library-validation'd system
daemon is the same requirement as existing system-daemon tweaks in this repo (SpringBoard,
ioscd, etc.) and relies on the jailbreak's AMFI/library-validation bypass + proper
signing of the dylib by the install pipeline. It should work but has not been verified
for this specific process — verify that the dylib actually loads into pid 31 before
trusting a behaviour test (e.g. a one-line os_log from the ctor, watched with
`bin/logs.sh`). calaccessd carries the same flags; it is not the injection target for the
primary fix anyway.

---

## How to verify on device (NOT performed — needs BFU, i.e. a userspace reboot)

A real test requires the device in BFU, which means a userspace reboot (`sbreload`/
`jbctl`-style) and then **not unlocking**. Per the session guardrails a sampler, a Doom
test, and the dyld-cache copy are using the device right now, so this must be scheduled
when you own the device; do not reboot it now. Exact plan:

1. Build + stage + install the tweak the normal way (`bin/build.sh`, `bin/install.sh`
   tweaks/<Name>) while the device is unlocked. Confirm the dylib is injected into
   UserEventAgent (pid of `/usr/libexec/UserEventAgent`) via a ctor `os_log` watched
   with `bin/logs.sh UserEventAgent` — do this before relying on any behaviour result.
2. Capture a **baseline without the tweak first** (or disable it): userspace-reboot,
   leave locked (BFU) ~15 min, then over SSH (key auth survives BFU; sshd runs — FACT,
   it is in the archive) pull persisted logs and count
   `Firing event "…alarmEngine.alarm.name"` and powerd `Selected RTC wake request …
   user-invisible-com.apple.calaccessd.alarmEngine` per minute. Expect ≈1/min.
   - Query the live persisted store the same way as the archive, e.g.
     `log show --predicate 'subsystem == "com.apple.xpc.alarm"' --info --start <t>`,
     run **on the device** or against a freshly pulled logarchive. Do **not** attach
     `idevicesyslog` (guardrail).
   - Precondition: confirm at least one future (or stale past-due) calendar alarm exists
     — check `/var/mobile/Library/Calendar/Extras.db` `ZALARM` (read-only copy) before
     the reboot.
3. Enable the tweak, userspace-reboot, leave locked ~15 min, pull logs again. Pass =
   essentially **zero** `IOPMRequestSysWake`-driven user-invisible RTC wakes for the
   calaccessd alarm during BFU, and no new per-minute `AOP.OutboxNotEmpty` wake train.
   The `Firing event …` / `Resetting … 60 seconds` lines may still appear (we only
   suppressed the hardware wake) — the battery-relevant metric is the powerd RTC wake +
   the subsequent Wi-Fi re-init, so also grep for wifid `unlockedSinceBoot FALSE`
   re-init bursts and confirm they stop.
4. **Unlock and verify AFU is intact:** unlock once, then set/confirm a near-future
   calendar alarm (e.g. 2 min out) and confirm it fires on time with a visible
   notification, and that `calaccessd` logs the normal
   `receivedAlarmNamed:` → `_installTimerWithFireDate:` → `Scheduled XPC alarm event`
   chain. Also confirm a second lock→(stay AFU) still delivers alarms.
5. Regression: reboot once more, unlock immediately, confirm no missed/duplicated
   alarms and that the next-fire RTC wake is scheduled far in the future (not +60 s).

---

## Risks

- **Suppressing a wake that was actually wanted in BFU.** Mitigated by the narrow filter
  (only `calaccessd.alarmEngine` requestor) + BFU gate; other subsystems' wakes
  (`remindd`, `seserviced`, `sleepd`, `acmd`, etc. — all seen sharing this plugin) are
  untouched. The fallback (coalesce to 30 min) exists if full suppression is too
  aggressive.
- **`IOPMRequestSysWake` signature assumption.** Confirmed single `CFDictionaryRef` arg
  from the call site; if a future iOS build changes it the hook must be re-derived.
  Reading the requestor from the dict defensively (type-check, NULL-check) avoids
  crashing UserEventAgent (which is `KeepAlive`, `EnablePressuredExit=false` — a crash
  loop here is disruptive).
- **Injecting into a library-validation'd system daemon** (see §3 FLAG) — verify load
  before trusting results; a mis-signed dylib simply won't load (safe) but a crash in
  the ctor would respawn UEA repeatedly.
- **Offset-based fallback hook** (`sub_25f4`/`sub_1840`) is build-pinned and brittle;
  avoid unless the `IOPMRequestSysWake` approach proves insufficient.
- Testing requires a userspace reboot + staying locked, contending with the device's
  current owners — schedule it, don't force it.

## What could not be determined

- The exact provenance/age of the stale alarm registration (token 1749): it was created
  by `xpc_set_event` in a session before the archive window, so its original Date isn't
  in the logs. (Does not affect the fix.)
- Whether a *clean* iOS 17 device with a single future alarm reproduces the full 1/min
  storm immediately, vs. only after that alarm's Date passes in BFU — needs a controlled
  second-device repro (not done; device-access guardrails).
- The precise source of the synthetic `Reply received for alarm 1749/2` in BFU (the XPC
  event machinery replies even with no live consumer). It does not change the mechanism
  or the fix — the throttle+wake re-arm is what matters.
- Live confirmation that the ElleKit dylib loads into UserEventAgent on this device
  (static entitlement/flag review only).
