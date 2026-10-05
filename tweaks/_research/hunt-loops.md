# Periodic retry loops and error storms (unified-log hunt, iPad7,12, iOS 17.6.1)

Passive analysis of `dev2.logarchive` (2026-09-08 to 2026-10-05). No device access.
Goal: find loops that waste CPU, battery, wakes, or flash writes, beyond the three
items already known (calaccessd BFU alarm wakes, wifid scan-cache growth with
Settings open, fileproviderd/spotlightknowledged/Sep 22 SSH wake storm).

Sibling hunts committed on this branch cover some of the same ground. Where a
finding overlaps, I say so and only add what's new:
`hunt-dasd.md` (dasd/XPC activity churn) and `hunt-resources.md` (CPU, memory, writes).

## How I got here

- Streamed the whole archive as ndjson (193 time chunks, 22.9M log/state events,
  417k distinct templates) into a per-(process, subsystem, category, level,
  template) aggregate. Templates are the message with UUIDs, MACs, hex, IPs,
  paths, numbers, and dasd-style hex IDs replaced. For each template I kept every
  timestamp, then computed per-state counts, inter-arrival median and quartiles,
  a periodicity score, and the longest sustained periodic run.
- Flagged (a) median interval under 10 min with at least 35% of gaps within
  20% of the median and at least 2 h sustained, (b) Error/Fault templates over
  500/day in any state, (c) retry/failure wording over 150/day, (d) anything over
  300/day while BFU or idle. Then read raw windows around each candidate for the
  trigger chain.
- Wakes: paired every powerd `Selected RTC wake request` (logged at sleep entry)
  with the next `Wake [...] due to ...` line. An `rtc` wake is attributed to the
  last selected request. Awake time is wake to the next `Entering Sleep`.
- Process launches: distinct PIDs per process plus launchd `Successfully spawned
  ... because ...` lines (launchd detail exists only from Sep 30 20:23).

### Coverage caveat (important)

Persisted default-level logs for most daemons start on **Sep 30 20:23**. Before
that, only long-TTL subsystems survive: powerd, dasd, linkd, wifid (from Sep 25),
some UserEventAgent/SpringBoard/cloudd, and Error/Fault lines. So:

- BFU findings rest on powerd and dasd only.
- "IDLE-late" below (Sep 30 20:30 to Oct 1 17:45, ~21 h, screen off, battery,
  still sleeping between wakes, some SSH sessions) is the only idle stretch where
  most daemons are visible. Per-day idle rates for those daemons come from it.
- From Oct 1 20:09 to the end the AP never idle-slept (audiomxd held
  `PreventUserIdleSystemSleep` for xios-audiod/xios-mediad; being fixed
  separately). Rates in the AWAKE states are "always awake" rates, not normal ones.

## Device-state timeline

| State | Window (PDT) | Power | Notes |
|---|---|---|---|
| BFU | Sep 18 00:00 to Sep 21 14:16 | battery, 24% to 11% | Never unlocked since boot. First unlock at 14:16:18 (`SmartPowerNap: SB Lock State 0`), screen on for 10 s |
| AC1 | Sep 21 15:32 to Sep 22 17:35 | charger (`Power Source change. Source:AC`) | Includes the known Sep 22 Wi-Fi wake storm |
| IDLE | Sep 22 17:35 to Oct 1 17:45 | battery, 99% (Sep 23) to 55% (Oct 1): ~5.5%/day | AFU, screen off the whole time (no backlight events), smart cover closed |
| IDLE-late | Sep 30 20:30 to Oct 1 17:45 | battery | Sub-window of IDLE with full daemon coverage |
| DEV | Oct 1 17:45 to 20:09 | battery then AC at 18:30 | Userspace reboots at 17:51 and 19:57 (Hush installed), X11 stack started 19:18 |
| AWAKE-AC | Oct 1 20:09 to Oct 3 01:31 | AC (USB to the Mac) | Never sleeps |
| AWAKE-BATT | Oct 3 01:31 to Oct 5 13:00 | battery, 99% to 45%: ~28%/day | Never sleeps |

### Idle wake budget (for calibration)

| State | Wakes/day | Biggest sources (wakes/day, AP-awake seconds/day) |
|---|---|---|
| BFU | 1,073 | calaccessd alarm (known) 1,043 / 10,685 s; locationd FenceContTrack 22 / 882 s |
| IDLE | 360 | **wlan 263 / 2,527 s**; **locationd durianPersistentConnectionMaintenance 61 / 671 s**; FenceContTrack 12 / 128 s; voice_trigger 11 / 83 s; bluetooth 3; calaccessd travelEngine 3 |

The known calaccessd loop cost about 3 h of AP-awake time per day in BFU. Nothing
else I found comes close to that on battery; the biggest idle item below is about
11 min/day.

## Ranked candidates

Rates are per day in the named state, computed only over windows where the
process has coverage. "awake" means AWAKE-AC and AWAKE-BATT (always-awake AP).

| # | Process | Normalized template | Count/day by state | Interval | Trigger chain | Class | Impact | Conf. |
|---|---|---|---|---|---|---|---|---|
| 1 | locationd + bluetoothd + searchpartyd | `#durian #connectattempt new ... "reason":"Maintenance:Timer"` -> `#durian #maint done ... "reason":"nodiscovery"`; bluetoothd `Failed to create a new device ... as it already exists`; searchpartyd `Failed to publish to ACSN ...PublishError.finderDisabled.` | attempts: IDLE-late 480, awake 466; RTC wakes IDLE 61; bluetoothd errors IDLE-late 1,117, awake ~1,630; finderDisabled awake 324 to 1,054; dasd BeaconPayLoadPublish runs IDLE 255 | 930 s (p25/p75 930/930 awake, 885/915 idle) | locationd persistent-connection timer -> key fetch for ~8 owned Find My items (named left, right, Case, and others) last seen 3 to 77 days ago -> bluetoothd device-create errors -> 6 s BLE discovery -> `nodiscovery` (error 3) -> searchpartyd re-registers 4 publish activities with delay 0 -> publish fails `finderDisabled` -> repeat | Apple bug (no backoff for long-absent accessories; publishes while finder is disabled) | 61 wakes/day = 17% of idle wakes, ~11 min AP awake/day, ~93 BLE discovery passes/day | High (loop, wakes); medium (that it's pure waste) |
| 2 | CommCenter | `#I fired MsimBackoff timer for mode kUnknown, radio state Offline` + `MSIM update: backoff reason <baseband not online>: setting timer` | awake 17,266 (exactly 86,400/5); IDLE-late 649 | 5.0 s, 100% periodic for 59 h | Airplane mode on, no SIM (`kSimStateNoSim`), baseband offline; the "backoff" timer re-arms at a constant 5 s forever | Apple bug (backoff never grows; not gated on airplane mode) | 17k CommCenter wakeups and 52k log lines/day whenever the AP is awake; no wakes of its own | High |
| 3 | linkd | stateEvent `Audit Fault { changes = "New bundles:\n- com.apple.weather: <hash>" }` + Fault `Unexpected changes detected, possibly missed an install/uninstall event` | 20-28 audit bursts/day (39 `Unexpected changes` Faults/day, steady); Audit Fault events 19/day (Sep 21) growing to 1,622/day (Sep 30); reset by the Oct 1 reboot, then 169 -> 429 -> 785 | audit burst every ~46-60 min (gap median 2,753 s); burst size grows ~9/day | duetexpertd home-screen suggestion refresh asks for App Intents metadata -> linkd audits -> sees com.apple.weather as "new" every time, never commits it -> N parallel faults, N grows daily | Apple bug, unbounded growth until reboot (possibly provoked by jailbreak `uicache` registrations that skip install notifications: flag only) | Fault + stateEvent writes grow without bound; full metadata rescan of every bundle ~50/day when awake; runs during idle wakes | Medium (growth: high) |
| 4 | maild | `Starting maild version 3776.700.51` -> `Mail app is not installed, switching to EDNonAcceptingServer` -> Error `Connection Invalid for service com.apple.apsd` -> `bye bye!` | launches IDLE-late 305; 291 launches Sep 30 20:24 to Oct 2 05:54, then stops | median 151 s idle; relaunch 27 ms after exit; 12 s cycles at the end | launchd relaunches maild `because xpc event` (278) or `ipc (mach)` (13) right after it exits; it unregisters ~30 XPC activities, connects to apsd, quits | Apple bug (deleted app's daemon keeps its launch events) | ~300 process launches/day in idle; logd stats suggest it ran all month and harder in BFU (below) | Medium-high |
| 5 | wifid | `WIFICLOUDSYNC ...: 143 networks waiting for password sync` / `Password is still not available for network at idx N` / `max 'waiting for password' attempts reached (5 per 10.0s), next attempt scheduled for 12.0s` | awake 1,400; IDLE 626; `WiFiNetworkCopyPassword` (keychain query) awake 1,400 | 12 s | wifid cloud-sync waiting list of 143 iCloud-synced networks whose passwords never show up; polled 5 at a time; 142 waiting on Sep 25, 143 on Oct 5 | Apple bug (retry with no give-up) | ~1.4k keychain queries + ~5k log lines/day when awake | Medium |
| 6 | wifid | `__WiFiDeviceManagerKnownNetworkSuitabilityCheck: Priority Network with no RT traffic - ok to autojoin` + 2x `isNetworkTraitsCacheValid` per network + `AUTO-JOIN: Known network ... is not allowed (error=(1 'Known network profile unused for 72 weeks'))` | evaluations: awake 30-32k, IDLE-late 8.1k; "unused for N weeks" rejections awake ~10k | 432 s exactly (98-100%) | Joined to open "SF Public Wifi", a lower-priority network, so wifid re-evaluates all ~150 known networks every 7.2 min looking for a better one, including profiles unused for 72 weeks | Apple-by-design, heavy (O(known networks) per pass) | wifid is the top logger by count: 4.7M of 22.9M events (21%); 65-69 MB/day of log data awake, 17-25 MB/day idle (logd stats) | High (behavior); medium (cost) |
| 7 | PerfPowerServices | Fault `Screen On: Tried updating On Screen time, but couldn't retrieve apps on screen` | AC1 3,765; IDLE 735; 0 after the Oct 1 reboot (49/day at 600 s on Oct 4-5) | 8 s on AC, 14 s when awake on battery | PerfPowerServices relaunched at 14:17:29 on Sep 21, 69 s after the backlight went off during first unlock, and apparently thought the screen stayed on for 10 days | Apple bug (screen state not re-read at launch) | 10.8k Fault-level events in 10 days; faults are kept longer and cost more to log | Medium |
| 8 | securityd (CKKS) | Error `Keychain is locked; can't decrypt IQE <CKKSIncomingQueueEntry[](Passwords): modify <UUID> (new)>` + `ready to process an incoming queue entry` | IDLE-late ~16k; awake 5-10k | ~22 incoming-queue runs/day, each retrying ~450 class-A entries | Same entry UUIDs retried run after run while locked; each run also posts `com.apple.security.keychainchanged` (764 posts), waking keychain observers such as #5 | Apple-by-design retry, wasteful (it logs `Have pending classA items for view, but device is locked` and tries anyway) | ~10k failed decrypts + ~20k log lines/day while locked | Medium |
| 9 | ~10 daemons (battery tick) | kernel `Using IOSkywalkLegacyEthernet as no other controller was found for en0`; wifid `External power state is same as before 0, bailing out`; PerfPowerServices Error `unknown wRa format: (null)`; sharingd new XPC connection to `com.apple.iokit.powerdxpc` | 4,320 ticks/day awake: sharingd 12.7k connections, PerfPowerServices 4.2k errors, kernel 4.2k | 20 s | Each gas-gauge update fans out to UserEventAgent (PoSM threshold), kernel gPTP, wifid, sharingd (3 fresh connections), PerfPowerServices (parse error every time), dasd, symptomsd, locationd | Apple-by-design | Small per tick; only while awake | High (behavior); low (cost) |
| 10 | powerd | `Sending assertion check message to pid N` | BFU 28k; AC1 45.6k; IDLE 9.7k | per wake, ~26-27 messages | Every wake/sleep transition pings every async-assertion holder | Apple-by-design; multiplies the cost of every wake from #1 and the calaccessd loop | 9.7k IPC messages/day idle, 28k/day in BFU | Medium |

Covered by sibling hunts (my extra numbers only):

- **passd `ApplePayCloudStoreUnarchivedTask` no-op loop** (hunt-dasd #5). Charger only:
  1,601 dasd runs/day in AC1, 2,039/day in AWAKE-AC, 0 on battery. Each cycle is
  5-6 back-to-back runs of `Uploading 0 unarchived transactions`, then a +3 min
  resubmit (184 s cadence). 685 `Selected RTC wake request` lines name it on
  Sep 22; only 11 actual rtc wakes are attributable because the Wi-Fi storm woke
  the device first. Apple bug, high confidence.
- **dasd spawns com.apple.datamigrator every 30 min** (hunt-dasd #8): 48-55
  launches/day in every state since Sep 25.
- **Sandbox-denied `com.apple.imagent.embedded.auth` lookups** (hunt-resources #8):
  4,536/day in AWAKE-AC from mediaanalysisd(-service), plus siriactionsd.

## Evidence

### 1. Find My accessory maintenance retries forever (locationd, bluetoothd, searchpartyd)

The timer fires every 930 s in every AFU state. Each pass lists the owned
accessories, fetches keys, tries discovery for 6 s, fails, and gives up until the
next pass. `lastObservation` for the accessories is 286,788 s to 6,615,309 s
(3.3 to 76.6 days). In idle it's the top RTC wake source (551 of 745 rtc wakes,
mean 11.0 s awake each). hunt-dasd #6/#7 counted the wakes and the dasd publish
runs; the new parts here are the failure on every pass and the coupling of the
three daemons.

```
2026-10-04 03:02:15.412 Df locationd[64742:4223f1] [com.apple.locationd.Position:Proximity] {"msg":"#durian #connectattempt new", "item":<private>, "attemptId":<private>, "name":<private>, "condition":1, "reason":"Maintenance:Timer", "oldId":<private>}
2026-10-04 03:02:15.443 Df locationd[64742:4223f1] [com.apple.locationd.Position:Proximity] {"msg":"#durian #metric keyFetchEvent", "lastObservation":6615309, "numberMaterials":8, "isDrift":1, "deviceType":"hawkeye", "shouldSubmit":0}
2026-10-04 03:02:15.445 E  bluetoothd[64761:422753] [com.apple.bluetooth:Server.XPC] Failed to create a new device for address <private> with identifier 89EEB3D5-AA25-8791-EC0C-EDE8892E489B as it already exists
2026-10-04 03:02:16.396 E  searchpartyd[64844:4227a6] [com.apple.icloud.searchpartyd:beaconManagerService] Failed to publish to ACSN searchpartyd.BeaconPayloadPublisher.PublishError.finderDisabled.
2026-09-30 20:38:16.466 locationd[70] {"msg":"#durian #maint done", "item":<private>, "reason":"nodiscovery", "category":0, "left":4, "duration":6}
2026-09-21 14:26:46.977 powerd[47] Selected RTC wake request: { UserVisible = 0; appPID = 70; eventtype = wake; leeway = "92.99999737739563"; scheduledby = "com.apple.persistentconnection[locationd,70,0xeceb873c0,com.apple.locationd.durianPersistentConnectionMaintenance]"; time = "2026-09-21 21:30:34 +0000"; }
```

The loop starts at first unlock (first durian wake request 10 min after it) and
never appears in BFU. A tweak could stretch the maintenance interval for items
whose `lastObservation` is older than a few days, but the hook point needs RE
work in locationd first. Flagging, not proposing a fix.

### 2. CommCenter MSIM "backoff" every 5 s in airplane mode

```
2026-10-02 02:30:00.196 Df CommCenter[64763:3b9c2e] [com.apple.CommCenter:DATA.ServiceController] #I fired MsimBackoff timer for mode kUnknown, radio state Offline
2026-10-02 02:30:00.196 Df CommCenter[64763:3b9c2e] [com.apple.CommCenter:DATA.ServiceController] #I MSIM update: backoff reason <baseband not online>: setting timer (mode kUnknown)
2026-09-30 20:26:11.102 CommCenter[91] #I Airplane mode enabled, skipping cell refresh
```

66,121 fires from Sep 30 20:26 to Oct 5 12:58, every one 5.0 s after the last
while awake. The timer doesn't wake the AP, so on a normally sleeping iPad it only
costs a few fires per wake (649/day in IDLE-late). It matters whenever the screen
is on or something holds the AP awake, which on this device is most of the time
the X11 stack runs. logd stats: CommCenter wrote 4.5-6.7 MB/day of log data in
Oct, 12-15 MB/day idle in Sep, and 42-47 MB/day on Sep 8-12 and the BFU days
Sep 19-20 (content not persisted; see "Couldn't determine"). Candidate for a tiny tweak (stretch or skip
the timer when airplane mode is on), but I haven't looked at the code path.

### 3. linkd audit faults that grow every day until reboot

Burst size (Audit Fault events per audit) by day:

| Day | 09-21 | 09-22 | 09-23 | 09-24 | 09-25 | 09-26 | 09-27 | 09-28 | 09-29 | 09-30 | 10-01 (reboot) | 10-02 | 10-03 | 10-04 | 10-05 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| mean | 2.4 | 6.3 | 12.8 | 22.9 | 32.4 | 44.5 | 53.3 | 62.9 | 71.9 | 81.1 | 32.7 | 6.0 | 16.5 | 28.0 | 34.0 |

```
2026-09-29 10:04:08.317 F  linkd[233:36aeed] [com.apple.appintents:Registry] Unexpected changes detected, possibly missed an install/uninstall event
2026-09-29 10:04:08.318 Sd linkd[233:0] Audit Fault
{
    changes = "New bundles:\134n- com.apple.weather: 5105276926db4b2e90726a599ce6b955\134n";
    distnote = "<_NSLocalNotificationCenter:0xc7c914ec0>\134n";
}
2026-09-21 15:53:51.512 linkd[233] Unexpected changes detected, possibly missed an install/uninstall event
```

Same bundle, same hash, every audit for two weeks. The linear growth that resets
on reboot looks like accumulated observers or registrations, each running its own
audit. linkd also calls `-[NSNotificationCenter debugDescription]` to build the
state payload (3,568 Errors saying it "should not be used programmatically"), and
that description gets bigger as observers pile up. The audits line up with
duetexpertd's home-screen suggestion refresh (`----- HSLS REFRESH END -----` at
10:04:08.433). Worth checking whether a `uicache` run (which registers apps
without the normal install path) is what made linkd lose track of Weather. I can't
tell from logs.

### 4. maild relaunch loop with the Mail app deleted

```
2026-10-01 03:04:05.573 Df maild[58783:38802c] [com.apple.email:DaemonAppController] bye bye!
2026-10-01 03:04:05.576 Df launchd[1:388029] [user/501:] service inactive: com.apple.email.maild
2026-10-01 03:04:05.603 Df launchd[1:388029] [user/501/com.apple.email.maild [58785]:] Successfully spawned maild[58785] because xpc event
2026-10-01 03:04:05.683 Df maild[58785:3880db] [com.apple.email:DaemonAppController] Mail app is not installed, switching to EDNonAcceptingServer
2026-10-01 03:04:05.694 E  maild[58785:3880dd] [com.apple.apsd:xpc] Connection Invalid for service com.apple.apsd
```

Each instance unregisters ~30 Mail XPC activities, registers apsd topics, gets
"Connection Invalid", idles a few minutes, and exits; launchd starts the next one
within milliseconds. The last burst (Oct 2 05:53) cycled every 12 s on `ipc
(mach)`, so a client kept messaging maild's port, then everything stopped at
05:54:47. logd byte stats for maild: 5-7 MB/day on Sep 8-12 and Sep 19-20 (BFU),
18-22 MB/day Sep 21-22, 0.3-1.6 MB/day Sep 23-30. So the loop probably ran all
month and was busier in BFU. The xpc event name isn't logged.

### 5. wifid waits forever for 143 synced Wi-Fi passwords

```
2026-10-04 03:00:10.177 Df wifid[64721:421a5c] [com.apple.WiFiPolicy:] WIFICLOUDSYNC __WiFiCloudSyncEngineCheckWaitingForPasswordList: 143 networks waiting for password sync, currently at 2
2026-09-25 05:57:32.019 wifid[51] WIFICLOUDSYNC __WiFiCloudSyncEngineCheckWaitingForPasswordList: Password is still not available for network at idx 135
2026-09-25 05:57:32.041 wifid[51] WIFICLOUDSYNC __WiFiCloudSyncEngineCheckWaitingForPasswordList: max 'waiting for password' attempts reached (5 per 10.0s), next attempt scheduled for 12.0s from now
```

```
2026-10-05 10:36:10.799 Df wifid[64721:45bd0a] [com.apple.WiFiPolicy:] WIFICLOUDSYNC __WiFiCloudSyncEngineCheckWaitingForPasswordList: there are 143 networks waiting for password sync, and they're unavailable
```

Each check goes through `WiFiNetworkCopyPassword` and a keychain query. It's
throttled (5 per 10 s), but it has no end condition. The list held 142 networks
on Sep 25 and 143 on Oct 5, across two reboots and several unlocked stretches,
so it isn't just "the keychain is locked right now". This is the same wifid that
the Hush wifid hook already touches; a second hook here would be cheap, but I'm
only flagging it.

### 6. wifid re-evaluates ~150 known networks every 7.2 min

```
2026-09-25 06:20:19.646 wifid[51] __WiFiDeviceManagerKnownNetworkSuitabilityCheck: Priority Network with no RT traffic - ok to autojoin
2026-09-25 06:20:19.654 wifid[51] -[WiFiAnalyticsManager isNetworkTraitsCacheValid]: Cache needs update: No. Time difference 0.00
2026-09-30 21:03:09.582 wifid[51] [corewifi] AUTO-JOIN: Known network '<redacted>' is not allowed (error=(1 'Known network profile unused for 72 weeks'), network=(<redacted> - ssid=<redacted> (3654788106), security=wpa3-transition, assoc=(null) (user)))
```

In an 8-minute sample on Oct 4, one pass logged 152 suitability checks, 304
traits-cache checks, ~50 "unused for N weeks" rejections, and 35 "deferrable"
lines. Auto-join while sitting on a low-priority open network is by design. Doing
it across every known network, including ones unused for 72 weeks, every 432 s is
the expensive part. Pruning stale known networks (a user action) should shrink it.

### 7. PerfPowerServices thinks the screen is on (Sep 21 to Oct 1)

```
2026-09-21 14:16:20.310 Df powerd[47:27870e] [com.apple.powerd:smartPowerNap] Backlight turned off
2026-09-21 14:17:29.460 Df PerfPowerServices[46391:278dbb] [com.apple.ManagedConfiguration:MC] Got system group container path from MCM for systemgroup.com.apple.configurationprofiles: ...
2026-09-21 14:26:46.709 F  PerfPowerServices[46391:279874] [com.apple.powerlog:] Screen On: Tried updating On Screen time, but couldn't retrieve apps on screen
```

pid 46294 (the BFU instance) was replaced by 46391 right after first unlock, and
the new one faulted every 8-14 s whenever the AP was awake until the Oct 1 17:51
userspace reboot. powerd logged no backlight events in between, so the screen was
really off.

### 8. CKKS retries the same locked entries every run

```
2026-10-01 02:15:00.264 securityd[122] Keychain is locked; can't decrypt IQE <CKKSIncomingQueueEntry[](Passwords): modify 00AB6454-E43A-4388-9764-CA5008175071 (new)>
2026-10-01 03:41:22.139 securityd[122] Keychain is locked; can't decrypt IQE <CKKSIncomingQueueEntry[](Passwords): modify 00AB6454-E43A-4388-9764-CA5008175071 (new)>
```

96 incoming-queue runs from Oct 1 02:15 to Oct 5 10:24, each walking ~300 Passwords
plus Backstop, Applications, CreditCards and SecureObjectSync entries (45,640
Errors total). The state machine goes `iqo-errored` -> `become_ready` -> try
again. Each run ends with a `keychainchanged` notification that wakes every
keychain observer.

### 9. Battery tick fan-out (every 20 s while awake)

```
2026-10-04 06:00:04.653 Df kernel[0:39ea4c] (IOgPTPPlugin) Using IOSkywalkLegacyEthernet as no other controller was found for en0
2026-10-04 06:00:04.655 Df wifid[64721:427abf] [com.apple.WiFiPolicy:] External power state is same as before 0, bailing out
2026-10-04 06:00:04.663 Df sharingd[64740:427eec] [com.apple.xpc:connection] [0x5eac49c70] activating connection: mach=true listener=false peer=false name=com.apple.iokit.powerdxpc
2026-10-04 06:00:04.664 E  PerfPowerServices[64753:427e92] [com.apple.powerlog:] unknown wRa format: (null)
```

Normal on stock iOS too. Listed because it runs 4,320 times a day on an AP that
never sleeps, and sharingd opens three new powerd connections each time.

### 10. powerd assertion checks per wake

```
2026-09-08 03:57:32.719 powerd[47] Sending assertion check message to pid 70
2026-09-08 03:57:32.719 powerd[47] Sending assertion check message to pid 120
```

238,998 messages from Sep 8 to Oct 1 17:45, none after (no more sleeps). This is
why each wake costs more than its own handler; it scaled the calaccessd loop to
28k messages/day in BFU.

## Max's stack (separate)

| # | What loops | Rate | Class | Notes |
|---|---|---|---|---|
| M1 | Host polls lockdownd over USB every 10 s while the iPad charges from the Mac (Oct 1 18:30 to Oct 2 ~23:13) | ~7,950 service starts/day; lockdownd 30.9k `handle_get_value`/day; mobile_assertion_agent 64.5k lines/day; trustd ~15k cert lines/day; securityd 7.2k `Client has neither application-identifier nor keychain-access-groups`/day | Host tooling | Each poll: lockdown TLS session (2x `SecTrustEvaluateIfNecessary`), 4x get_value, `start_service` for `com.apple.mobile.assertion_agent`, which spawns, does its own 2 trust evaluations, and reads nothing. Likely feeds the lockdownd memory growth in hunt-resources #6. Host program unknown |
| M2 | fseventsd `disk logger: failed to open output file <private> (No such file or directory). mount point <private>` | 16.7k Errors/day, every 23 s since Oct 1 19:19:45 | Max's stack + jailbreak mount | Started 34 s after xios-sensord's first log (19:19:11). Fits hunt-resources M1 (xios-sensord rewrites 9 files at 10 Hz): events pile up for a mount whose fseventsd log dir couldn't be opened at the 17:51 reboot (`Could not open logging directory <2> ... dev[16777224]`), likely the Preboot volume that hosts /var/jb. Fixing M1 should stop it |
| M3 | Every Procursus CLI exec opens 2 cfprefsd connections, and cfprefsd logs `Couldn't open parent path due to [2: No such file or directory]` 3 times | 12.5k cfprefsd Errors/day AWAKE-AC; 88k/day during DEV | Jailbreak-induced, amplified by tooling | Probably the injected tweak loader reading prefs for root. On-device shell loops ran `sleep` 1,457 and `date` 1,347 times in the Oct 1 20:00 hour alone (about 1 Hz) |
| M4 | audiomxd RTAID reports silence on Speaker-Output and Input (`peak = "-240.000000"; rms = "-120.000000"`) every 10 s; audioclocksyncd PTP stats every 60 s | ~68k audiomxd lines/day; 2,880 audioclocksyncd/day | Max's stack (audio sessions) | Side effect of the audio sessions already being fixed (hunt-dasd #1, hunt-resources M2). Not a new finding |
| M5 | sshd `send failed: Invalid argument` (libinfo `si_destination_compare`) 3 times per session | 1,211 sessions Oct 1-2 | Jailbreak/tooling noise | Harmless, but each agent SSH session costs a launchd spawn plus these |

```
2026-10-02 03:00:09.148 Df lockdownd[64751:3bbac4] handle_start_service_with_socket: <private>
2026-10-02 03:00:09.220 Df mobile_assertion_agent[72467:3bba94] [com.apple.iokit:assertions] Setting gAssertionsOffloader timeout to 1
2026-10-02 03:00:09.222 Df mobile_assertion_agent[72467:3bba94] [com.apple.mobile.assertion_agent:main] Read -1 bytes but expected none.
2026-10-01 19:19:45.053 E  fseventsd[59076:391d37] [com.apple.fsevents:daemon] disk logger: failed to open output file <private> (No such file or directory). mount point <private>
2026-10-01 20:30:00.606 Df date[68536:3a495c] [com.apple.xpc:connection] [0x5ee90b2d0] activating connection: mach=true listener=false peer=false name=com.apple.cfprefsd.daemon.system
2026-10-01 20:30:00.607 E  cfprefsd[64765:3a45e5] [com.apple.defaults:cfprefsd] Couldn't open parent path due to [2: No such file or directory]
```

## Couldn't determine

- **What the Wi-Fi wakes are.** 263 wlan wakes/day in IDLE, 71% of all
  wake-driven awake time (2,527 s/day). wifid logs the wake frame, but only its
  first 16 bytes (the Ethernet header), so I can't tell SSH from APNs from mDNS.
  This is the biggest idle item and it's unexplained.
- **BFU-only log volume with no persisted content.** logd's per-process byte
  stats show big BFU-day numbers that drop after first unlock: CommCenter 42-47
  MB/day (12 MB idle), nfcd 12-13 MB/day then ~0 after Sep 22 (iPad7,12 has no
  NFC), identityservicesd 8-11 MB/day (~1 MB after), launchd 8-11 MB/day (1-2 MB
  after), maild 5-7 MB/day. These look like BFU retry loops, but the messages
  aren't in the archive. Sep 13-18 show far fewer rollovers, so those days are
  unreliable.
- The xpc event that kept relaunching maild, and why it stopped on Oct 2 05:54.
- Which mount fseventsd fails on (paths are `<private>`), and which host program
  polls lockdownd every 10 s.
- Energy in mWh. Logs give wakes, awake seconds, and event counts, not power.
- dasd `Error obtaining RBS process handle` (5.7k/day on AC) is left to hunt-dasd.

## Reproducing

All derived from the archive with `/usr/bin/log show --style ndjson --info
--debug`, streamed in 1-6 h chunks through a Python aggregator. The scratch
scripts (`agg.py`, `merge.py`, `analyze.py`, `report.py`, `show.py`,
`wakeattr.py`, `rates.py`) live in the session scratchpad under `hunt-loops/` and
aren't committed. To spot-check any row, run `log show` on the archive with a
`process == "<name>" AND eventMessage CONTAINS "<template text>"` predicate over
the window in the table.
