# Background-task churn hunt (dasd / XPC activities / launchd)

Passive log analysis only. Source: `scratchpad/dev2.logarchive`, the device's persisted
unified log (iPad7,12, iPadOS 17.6.1, Dopamine). No SSH, no device probing. Times are
device-local (PDT, UTC-7) as `log show` prints them.

Convention: **FACT** = read straight from the log. **INFERENCE** = my reading of it.

## Coverage and device-state timeline

The archive is uneven. Default-level `powerd` and `dasd` lines start **Sep 18 06:00**
(only fragments of Sep 8; nothing for Sep 15-17). Info/Debug-level lines (xpc.activity
client side, launchd spawns, apsd per-topic pushes, passd/chronod internals) exist only
from **Sep 30 ~20:00**. So per-topic push counts and launchd respawn rates can only be
measured for Sep 30-Oct 5.

State segments used below (from `dasd` `classCLocked == 1`, wifid `unlockedSinceBoot` /
`externalPower` / `chargeLevel`, powerd `Battery capacity change posted`, launchd/powerd PID
changes and the SpringBoard/backboardd backlight lines):

| Tag | Window | Hours | State |
|---|---|---|---|
| BFU | Sep 18 06:00 -> Sep 21 14:16 | 80.3 | battery, never unlocked; `classCLocked == 1` stops at Sep 21 14:xx |
| AC1 | Sep 21 14:16 -> Sep 22 17:35 | 27.3 | on charger (11% at 15:32 -> 100%), first unlock, heavy SSH; awake 75% of the time |
| IDLE1 | Sep 22 17:35 -> Oct 1 17:51 | 216.3 | battery, screen off, normal sleep. Awake 4.1% of the time, 3250 wakes, mean 9.8 s awake per wake. 100% -> 39% = **0.28 %/h** |
| DEV | Oct 1 17:51 -> Oct 3 01:31 | 31.7 | userspace reboots at 17:51 and 19:57 (powerd/dasd PIDs jump), charger from 18:30, screen on ~5.4 h on Oct 1 |
| IDLE2 | Oct 3 01:31 -> Oct 5 12:59 | 59.4 | battery, screen off (one 6 s screen-on), **never sleeps** (see #1). 100% -> 32% = **1.14 %/h** |

Per-day figures below are normalized to these segment lengths.

Two global FACTs that change how the dasd numbers read:

- **dasd never arms an RTC wake on battery.** `Setting timer (isWaking=1 ...)` appears only in
  AC1/DEV. On battery every timer is `isWaking=0`, and across all 216 h of IDLE1 there are
  zero `Selected RTC wake request` entries with `scheduledby = com.apple.duetactivityscheduler.*`.
  On battery, dasd activities piggyback on wakes that something else caused. They cost
  CPU, not wakes.
- In BFU, dasd runs almost nothing (8 `memory-maintenance.compress` runs in 80 h). The BFU
  drain was calaccessd, which Hush already fixes.

Wake sources on battery (IDLE1, actual `Wake [CDNVA] : due to ...`): wlan 2369 (11.0/h),
rtc 748 (3.5/h), voice_trigger 104, bluetooth 31. RTC wakes attributed to the selected
request at wake time: locationd `durianPersistentConnectionMaintenance` 552, locationd
`FenceContTrack` 104, calaccessd 18, calaccessd `travelEngine.periodicRefreshTimer` 24, and
**0 from dasd**.

## Ranked findings

"Runs/day" columns are dasd STARTING counts per day in each state. "Wakes" means actual
RTC wakes attributed, unless marked as requests.

| # | Activity / daemon | Pattern | Runs/day AC1 / IDLE1 / DEV / IDLE2 | Interval, duration | Outcomes | Wakes caused | Class | Impact | Conf. |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **audiomxd `PreventUserIdleSystemSleep`** held for `xios-audiod` + `xios-mediad` MediaExperience sessions | System never idle-sleeps after Oct 1 | sleeps/day: ~340 in IDLE1, **0** from Oct 1 17:45 through Oct 5 | assertion age 88 h 45 m at end of archive | 1700 `Sleep revert state: 1` after 20:09 | n/a (AP never sleeps) | **Max's stack** | **4x idle drain** (1.14 vs 0.28 %/h). It also ~2.6x-es every periodic task below, because each one now fires on schedule | High |
| 2 | `com.apple.UsageTracking.Production.Private.sync` (UsageTrackingAgent, Screen Time cross-device) | Push-driven CloudKit sync; pushes arrive in triplets, then 1-2 syncs | 105 / 103 / 140 / 116 | push bursts ~44/day; run p50 2 s, max 527 s, 3264 s total | ~93% complete, ~6% cancel | No RTC wakes. Each push burst is a wlan wake on a sleeping device (~44/day of ~264 wlan wakes/day) | Apple-by-design (driven by Max's other devices) | Medium: largest named push topic (134 pushes/day, 1 of every 3.4 pushes); ~200 s/day of sync | High |
| 3 | `com.apple.fileproviderd.stream-reset` + `com.apple.fileprovider.indexing` (iCloud Drive, already known) | Re-index after (userspace) reboot/first unlock; chunked work that resubmits right away; AC-gated | stream-reset 697 / 0 / 211 / 0; indexing 0 / 0 / 117 / 0 | stream-reset every ~40 s, p50 23 s, p90 152 s | 2 episodes, **both converged** (last run COMPLETED, no resubmit) | 0 (AC only) | Apple-by-design; userspace reboots retrigger it | **Perf**: 12.2 h + 5.8 h of cumulative run time; ~335k `Significantly too slow SQL` errors in episode 2; ran 2.8 h of the 5.4 h screen-on on Oct 1 | High |
| 4 | `com.apple.chronod.nextScheduledTimelineRefresh` | No-op 300 s heartbeat: `Wake event fired` -> `Scheduling task for ... in 300.000000s`, no reload. Handler sets DEFER then DONE, so dasd files misuse | 266 / 106 / 256 / 277 | 300 s when awake; p50 315 s; ~5 ms | ~half CANCELED in IDLE1 (58/day); **817** dasd `deferred without being asked` reports | 514 RTC *requests* on Sep 22 (AC), **5 actual**; 0 on battery | Apple bug | Low: CPU only. ~275 empty wakeups/day of chronod + UEA + dasd when awake | High (loop), Low (which widget) |
| 5 | `ApplePayCloudStoreContainerClientIdentifier.ApplePayCloudStoreUnarchivedTask` (passd) | Tight loop: `Uploading 0 unarchived transactions` -> immediately reschedules with "run now"; 5 back-to-back runs, then dasd's loop detector pushes the next one +3 min | **1531** / 1 / **1954** / 0 | 5 runs in <1 s, then 180 s; ~4 ms each | 97% complete; **863** dasd `running in a loop` reports | 685 RTC *requests* on Sep 22, **11 actual**; 0 on battery (it never runs on battery) | Apple bug | Low on battery (doesn't run). On charger: ~2000 runs/day of passd + UEA + dasd XPC churn, plus a 3-min wake cadence when the charger is in and the screen is off | High |
| 6 | locationd `persistentconnection[... durianPersistentConnectionMaintenance]` (not dasd) | Find My / AirTag ("Durian") persistent-connection maintenance timer | RTC wakes/day IDLE1: 59-69, steady | ~23 min; leeway 93 s | n/a | **~62 RTC wakes/day**: the top RTC waker on battery now that calaccessd is fixed (552 of 748 IDLE1 rtc wakes) | Apple-by-design (INFERENCE) | Low-medium: ~62 wakes x ~10 s awake | Medium |
| 7 | `searchpartyd.activity.BeaconPayLoadPublish-{onBattery,onPower}{OnWiFi,OnCell}` | 4 variants scheduled in lockstep. Both `onBattery*` variants run on AC too; the `*OnCell` ones run with no cellular | per variant: 127 / 127 / 288 / 162 (onPower*: AC only) | 900 s, plus 1-5 s double-fires; 0 s each | all complete; ~150 loop reports | 0 | Apple-by-design | Low: ~255 runs/day on battery, ~1150/day on AC, near-zero work each | High |
| 8 | `com.apple.datamigrator` spawned by **dasd** every 30 min | dasd opens `com.apple.datamigrator`, asks, gets `Migration Needed? NO`, the process lingers ~12 s and exits | 48 launches/day (Sep 30-Oct 5, both before and after the Oct 1 reboots) | exactly 30 min; 11.7 s resident | exit(0) | 0 | Apple (design vs bug unknown) | Low: 48 process spawns/day | High (pattern), Low (why) |
| 9 | `gpsd` respawn + hourly GNSS ping | gpsd lives exactly 3600 s, `exit(255)`, launchd relaunches (`semaphore`). Each cycle, locationd `@ClxProvider, start, gps, desiredAccuracy, 1.0` powers GNSS for ~1.2 s | 24 spawns/day (Oct 1-5 only; launchd logs) | 3600 s | exit(255) every time | 0 | Apple-by-design (INFERENCE) | Low-medium: GNSS power-up hourly | Low (trigger unknown) |
| 10 | `financed` (FinanceKit orders/bankconnect) | Bursts of `Received remote change notification for local persistent store` -> restart pending-tasks activity -> Spotlight index -> another change notification | bursts/day: 11 / 5.5 / 19 / 6 | median 3 cycles per burst; worst **389 cycles in 48 s** (Sep 22 08:25) | n/a | 0 | Apple bug (INFERENCE: self-triggered feedback) | Low on average; bursty | Medium |
| 11 | `com.apple.duetexpertd.heuristicactionproducer-refresh` | Perpetual postpone: duetexpertd cancels and resubmits the activity +10 min right as its window opens, so it starves | cancels/day: 101 / **2** / 328 / 179; runs 43 / 29 / 11 / 6 | 600 s | the activity no longer runs | 0 | Apple bug, exposed by the no-sleep state (#1) | Low | Medium |
| 12 | `com.apple.webbookmarksd.passwordIconsRepeatingCleanupActivityIdentifier` | Only while the screen is on: starts, defers itself, re-runs ~90 s later, never completes | 0 / 0 / 62 / 0 (Oct 1 18:48-23:40 only, matching screen-on spans) | ~90 s, 0 s | 82 starts, **0 complete**, 81 misuse reports | 0 | Apple bug | Perf only, trivial | High |
| 13 | dasd full rescoring | `Rescoring all ~660 activities` | per hour: BFU 5.4, AC1 43.8, IDLE1 8.2, DEV 47.9, IDLE2 30.0 | n/a | n/a | 0 | Apple-by-design, amplified by #1 | Low-medium dasd CPU; ~3.7x in IDLE2 | Medium |
| 14 | Maintenance tasks running while the screen was on (Oct 1) | `bird.db-integrity-check` 3626 s, `FileProvider.maintenance.fpck-repair` 1840 s, `bird.app-telemetry` 1373 s, `corespotlight.knowledge.inference` 1309 s, plus #3, inside the 5.4 h screen-on | one-off | n/a | completed | 0 | Apple-by-design (AC + post-reboot catch-up) | **Perf** on the 2-core A10 during use | Medium |

Not flagged, by design and cheap: `com.apple.bluetooth.CBMetrics` (exactly 96/day, 900 s, 0 s
each), the hourly group (`siri.inference.HourlySignalRefresh`, `appstored.ODPSync`,
`keybagd.data-analytics`, `biomesyncd.periodic-sync`, ...: ~24/day each),
`FileProvider.fpfs.telemetry` (daily. Takes 6-7 h wall clock on battery because it spans
sleeps, but wake rates between 02:00 and 09:00 show no rise, so it isn't keeping the
device up), `mis.profile-garbage-collection` / `Proximity.LogPowerStatistics` /
`homecontrolsuggestion` (1800 s, 0 s).

---

## Evidence per finding

### 1. xios audio sessions keep the system awake (Max's stack)

FACT. The last idle sleep is `2026-10-01 17:45:46.342 Entering Sleep state due to 'Idle Sleep'`
and the last wake is 17:50:54. From the 17:51 userspace reboot to the end of the archive
there are zero sleep or wake events. That window includes 59 h on battery with the screen
off. The holder:

```
2026-10-01 19:18:45.795 Process runningboardd.59081 Created SystemIsActive "anon<xios-audiod>59081-59160-975:audiomxd(59160)...MediaExperience.60519."xios-audiod"..."MediaPlayback".isPlayingProcessAssertion"
2026-10-01 19:18:47.159 Process runningboardd.59081 Created SystemIsActive "anon<xios-mediad>...MediaExperience.60526."xios-mediad"..."PlayAndRecord_WithBluetooth_DefaultToSpeaker".isPlayingProcessAssertion"
2026-10-01 19:30:00.497 Process audiomxd.59160 Summary PreventUserIdleSystemSleep "com.apple.audio.VAD [vdef] AggDev 7.context.preventuseridlesleep" age:00:05:35 ... [Qualifiers: AudioOut AllowsDeviceRestart]
2026-10-05 12:55:40.515 Process audiomxd.64792 Summary PreventUserIdleSystemSleep "com.apple.audio.VAD [vdef] AggDev 7.context.preventuseridlesleep" age:88:45:48  id:4295000368
2026-10-03 10:02:21.690 Sleep revert state: 1
```

After the 19:57 userspace reboot, the same pair came back at 20:09:50-51. The assertion
(id 4295000368) was then held continuously. `xios-mediad` holds a PlayAndRecord session
(mic + speaker) and `xios-audiod` holds MediaPlayback, both marked `isPlaying`, so audiomxd
keeps the aggregate device running. Battery fell 100% -> 32% from Oct 3 01:31 to Oct 5 12:56.
That is 1.14 %/h, against 0.28 %/h for the Sep 22-Oct 1 idle stretch.

INFERENCE: the RemoteIO daemon keeps its IO unit started (or its session active) while
nothing is playing. Flag only; I changed nothing. It also explains the IDLE2 rates of every
periodic task below. Example: chronod at 277/day instead of 106/day.

### 2. Screen Time cross-device sync (UsageTracking)

```
2026-10-04 03:44:02.522 apsd [com.apple.apsd:pushHistory] <private> receivedPushWithTopic com.apple.icloud-container.com.apple.UsageTrackingAgent token <private> payload <private> timestamp 1791110642485096788
2026-10-04 03:44:02.535 UsageTrackingAgent [com.apple.cloudkit:NotificationListener] Running handler for notification <private>: { aps = { "content-available" = 1; }; ...
2026-10-04 03:44:02.604 dasd Submitted Activity: com.apple.UsageTracking.Production.Private.sync:E2511D at priority 30 (Sun Oct  4 03:44:02 2026 - Sun Oct  4 03:45:02 2026)
2026-10-04 03:44:02.675 dasd STARTING activity com.apple.UsageTracking.Production.Private.sync:E2511D <private>!
2026-10-04 03:44:04.964 dasd COMPLETED com.apple.UsageTracking.Production.Private.sync:E2511D at priority 30 <private>!
2026-10-04 03:44:05.611 dasd STARTING activity com.apple.UsageTracking.Production.Private.sync:2C6757 <private>!
2026-10-04 03:44:07.217 dasd COMPLETED com.apple.UsageTracking.Production.Private.sync:2C6757 at priority 30 <private>!
```

Push topics over 58 h of IDLE2: UsageTrackingAgent 134/day (44 bursts/day), `<private>`
125/day, `alloy.bulletinboard` 41, `alloy.fmd` 36, `passd` 31, `assistantd` 28, `securityd`
24, Maps 17. About 450 pushes/day in total. The UsageTracking sync rate barely moves
between IDLE1 (103/day, sleeping) and IDLE2 (116/day, awake). That fits a push-driven sync
that wakes the device rather than one that waits for a wake. It's by design, and the
iPad-side fix is user-level (turn off Screen Time "Share Across Devices" on the iPad).
Flagging, not recommending.

### 3. fileproviderd iCloud Drive re-index (known: quantified)

| Episode | Window | Runs | Done / cancelled | Cumulative running | Trigger |
|---|---|---|---|---|---|
| 1 | Sep 21 15:32 -> Sep 22 10:49 (19.3 h) | 793 stream-reset | 667 / 126 | 43,979 s (12.2 h) | first unlock after reboot; started the minute the charger went in |
| 2 | Oct 1 17:54 -> Oct 2 03:29 (9.6 h) | 279 stream-reset + 154 indexing (17:51-23:46) | 178 / 100 (+115 / 39) | 20,811 s (5.8 h) | 3 min after the 17:51 userspace reboot |

```
2026-10-02 03:23:42 dasd COMPLETED com.apple.fileproviderd.stream-reset:8B0DBE at priority 30
2026-10-02 03:23:42 dasd Submitted Activity: com.apple.fileproviderd.stream-reset:3D3BF8 at priority 30 (Fri Oct  2 03:26:42 2026 - Fri Oct  2 04:26:42 2026)
2026-10-02 03:29:18 dasd COMPLETED com.apple.fileproviderd.stream-reset:5B0A3C at priority 30   <- last one; no resubmit
2026-10-01 21:00:00.007 E fileproviderd[64939] [com.apple.FileProvider:com.apple.CloudDocs.iCloudDriveFileProvider/A{34}2] 🐌 Significantly too slow SQL statement: SELECT id, scheduling_priority, scheduling_timestamp, pending_reason, ...
```

Slow-SQL errors per hour in episode 2: 3.6k at 18:00, then 24k-51k/h until 03:00 (~335k in
total). After 03:29 it's ~10/day, all inside the daily `fpfs.telemetry` run. Verdict:
**not a true loop.** Each run completes a chunk and resubmits immediately, which is why
dasd's loop detector fired 121 times, and the work ends with a final COMPLETED and no
resubmit both times. It never ran on battery, so it costs no battery wakes. The cost is
CPU/IO on the charger, and on Oct 1 that overlapped 2.8 h of screen-on use. Each Dopamine
userspace reboot appears to restart it, which INFERENCE ties to the reboot itself.

### 4. chronod 5-minute no-op heartbeat

```
2026-10-02 11:01:11.841 chronod [com.apple.chrono:wake] Wake event fired for date: 2026-10-02T11:01:05-07:00
2026-10-02 11:01:11.841 chronod [com.apple.chrono:wake] Scheduling task for: 2026-10-02T11:06:11-07:00 in 300.000000s
2026-10-02 12:03:22.886 chronod [com.apple.xpc.activity:Client] _xpc_activity_set_state: com.apple.chronod.nextScheduledTimelineRefresh (0xa9e8bb100), 4
2026-10-02 12:03:22.886 chronod [com.apple.xpc.activity:Client] _xpc_activity_set_state: com.apple.chronod.nextScheduledTimelineRefresh (0xa9e8bb100), 5
2026-09-26 03:03:05.257 dasd CANCELED: com.apple.chronod.nextScheduledTimelineRefresh:70D9B0 at priority 30 <private>!
2026-09-26 03:03:05.257 dasd Please file a bug for com.apple.chronod.nextScheduledTimelineRefresh – the activity deferred without being asked to defer
```

Over 24 h of IDLE2, chronod logged 275 `Wake event fired` and 290 `Scheduling task ... in N s`
against a few dozen real reload tasks (PhotosReliveWidget, TVWidgetExtension, Google Calendar,
PassbookAppleCardWidget). The 300 s figure is constant. INFERENCE: some timeline's next
date is already in the past (or within the minimum), and chronod clamps it to 300 s. The
widget isn't named in the logs (`<private>`). The handler sets state 4 (DEFER) and then 5
(DONE) in the same callback. That makes about half the runs on battery land as CANCELED,
and dasd files a misuse report 53-77 times a day in every unlocked state. On Sep 22 (charger)
it was the #2 RTC wake *requester* (514), but only 5 actual RTC wakes are attributable to
it, and none on battery.

### 5. passd ApplePay cloud-store loop

```
2026-10-02 10:00:14.724 passd [com.apple.passkit:CloudStore] PDApplePayCloudStoreContainer starting activity: ApplePayCloudStoreUnarchivedTask
2026-10-02 10:00:14.731 passd [com.apple.passkit:CloudStore] Uploading 0 unarchived transactions
2026-10-02 10:00:14.731 passd [com.apple.passkit:CloudStore] Did upload local data following container setup for transactions:0
2026-10-02 10:00:14.731 passd [com.apple.passkit:CloudStore] Scheduled cloud store fetch activity ApplePayCloudStoreUnarchivedTask
2026-10-02 10:00:14.800 passd [com.apple.passkit:General] Beginning Scheduled Activity: ApplePayCloudStoreUnarchivedTask for Client: ApplePayCloudStoreContainerClientIdentifier
2026-09-22 05:12:41.977 dasd NO LONGER RUNNING ApplePayCloudStoreContainerClientIdentifier.ApplePayCloudStoreUnarchivedTask:E88A0F ...
2026-09-22 05:12:42.006 dasd Please file a bug for <private> – the activity is running in a loop.
2026-09-22 05:12:42.006 dasd Submitted Activity: ApplePayCloudStoreContainerClientIdentifier.ApplePayCloudStoreUnarchivedTask:E4446E at priority 30 (Tue Sep 22 05:15:41 2026 - Tue Sep 22 05:15:42 2026)
2026-09-22 05:12:42.011 dasd Setting timer (isWaking=1, activityRequiresWaking=0) between <private> and <private> for <private>
```

Interval histogram over 4328 runs: 2956 under 1 s and 710 at 120-200 s. That's bursts of
five, then the 3-minute penalty from dasd's loop detector. Runs per day: 310 on Sep 21 and
1432 on Sep 22 (charger), then 5 in the minutes after unplugging, then **none** for 9 days
on battery, then 154 / 2277 / 150 on Oct 1-3 (charger). So the activity carries an AC
requirement. The task's own logic resubmits unconditionally even when there were 0
transactions. That is an Apple bug, and dasd says so itself. **Answer to the Sep 22
question:** it's a real loop, but it lives only on the charger. The 685 wake *requests*
came out of its 3-minute re-arm, and they turned into 11 actual RTC wakes, because the
device was awake 75% of Sep 22 from SSH (wlan wakes 69/h). It doesn't touch battery life.

### 6. locationd Durian persistent-connection wakes (context, not dasd)

```
2026-09-25 03:05:26.549 powerd Selected RTC wake request: { UserVisible = 0; appPID = 70; eventtype = wake; leeway = "92.99999821186066"; scheduledby = "com.apple.persistentconnection[locationd,70,0xecf0d42b0,com.apple.locationd.durianPersistentConnectionMaintenance]"; ...
```

RTC wakes per day attributed to it: Sep 23 65, 24 63, 25 60, 26 62, 27 59, 28 69, 29 60,
30 60. `FenceContTrack` adds 8-15/day. Hunt-loops may also cover this one. I'm listing it
because once calaccessd is fixed, it's the biggest *scheduled* waker on battery.

### 7. searchpartyd beacon-payload publish, four variants

```
2026-09-25 03:10:20.873 dasd STARTING activity com.apple.icloud.searchpartyd.activity.BeaconPayLoadPublish-onBatteryOnWiFi:C99B28 <private>!
2026-09-25 03:10:20.897 dasd STARTING activity com.apple.icloud.searchpartyd.activity.BeaconPayLoadPublish-onBatteryOnCell:E8CE46 <private>!
2026-09-25 03:10:21.897 dasd STARTING activity com.apple.icloud.searchpartyd.activity.BeaconPayLoadPublish-onBatteryOnWiFi:AEC08F <private>!
2026-09-25 03:10:21.902 dasd STARTING activity com.apple.icloud.searchpartyd.activity.BeaconPayLoadPublish-onBatteryOnCell:BF065C <private>!
```

Each fire often runs twice within a second, and the WiFi and Cell variants always run as a
pair. On AC the `onBattery*` pair keeps running alongside the `onPower*` pair (4 x 288/day
in DEV). Every run takes 0 s (102 s total across 2074 runs). That's wasted scheduling, not
work.

### 8. dasd polls DataMigrator every 30 minutes

```
2026-10-04 03:58:57.300 dasd [com.apple.migration:core] DMXPCConnection created connection 0xc20a90630
2026-10-04 03:58:57.343 launchd [user/501/com.apple.datamigrator [75189]:] Successfully spawned datamigrator[75189] because ipc (mach)
2026-10-04 03:58:57.519 com.apple.datamigrator [com.apple.migration:core] DMMigratorProxy did send response for event 0x64291df90 msgID 5 to client pid 64747. Migration Needed? NO
2026-10-04 03:59:09.014 launchd [user/501/com.apple.datamigrator [75189]:] exited due to exit(0), ran for 11709ms
```

It spawns at :28:5x and :58:5x every hour, 121 times in 59 h, and it already ran at 2/h
on Sep 30, before the Oct 1 reboots. I can't tell from logs alone whether stock iOS caches
this answer.

### 9. gpsd hourly lifecycle

```
2026-10-04 03:57:29.885 locationd [com.apple.locationd.Position:GeneralCLX] @ClxProvider, start, gps, desiredAccuracy, 1.0
2026-10-04 03:57:30.957 gpsd [com.apple.gpsd:general] #gdm,start,initiated
2026-10-04 03:57:31.074 gpsd [com.apple.gpsd:general] #gdm,stop,initiated
2026-10-04 03:57:37.311 gpsd #gdm,destroyDevice,Immediate exit
2026-10-04 03:57:37.315 launchd user/501/com.apple.gpsd [75181] exited due to exit(255), ran for 3600042ms
2026-10-04 03:57:37.316 launchd user/501/com.apple.gpsd launching: semaphore
```

That's 24 spawns/day, each followed an hour later by a ~1.2 s GNSS session. I didn't dig
further: radio subsystem, and passive-only.

### 10. financed remote-change bursts

```
2026-09-22 08:25:03.289 powerd Process financed.48492 Created NetworkClientActive "Wallet Refreshing Orders" ...
2026-09-22 08:25:03.300 powerd Process financed.48492 Created NetworkClientActive "Wallet Refreshing Orders" ...   (389 cycles by 08:25:51)
2026-10-04 21:14:30.792 financed [com.apple.FinanceKit:Orders] Received remote change notification for local persistent store
2026-10-04 21:14:30.803 financed [com.apple.FinanceKit:Orders] Cancelling any previous pending tasks activity request
2026-10-04 21:14:30.817 financed [com.apple.FinanceKit:Orders] Starting pending tasks activity
2026-10-04 21:14:30.840 financed (CoreSpotlight) index-items
```

There were 102 bursts and 1117 cycles in total. On battery that's ~5-6 bursts/day and 27-66
cycles/day.

### 11. duetexpertd heuristicactionproducer-refresh never gets to run

```
2026-10-04 03:09:45 dasd CANCELED: com.apple.duetexpertd.heuristicactionproducer-refresh:F19442 at priority 5
2026-10-04 03:09:45 dasd Submitted Activity: com.apple.duetexpertd.heuristicactionproducer-refresh:451220 at priority 5 (Sun Oct  4 03:19:43 2026 - Sun Oct  4 03:24:43 2026)
2026-10-04 03:19:45 dasd CANCELED: com.apple.duetexpertd.heuristicactionproducer-refresh:451220 at priority 5
```

In IDLE1 it ran 29/day with 2 cancels/day. Once the device stopped sleeping it switched to
~180-330 cancel+resubmit pairs a day and ~6 runs. `context-heuristic-refresh` (283 cancels)
and `IntelligencePlatformCore.ViewEvery21Minutes` (182 cancels) follow the same pattern
on a smaller scale.

### 12. webbookmarksd password-icons cleanup defers forever while in use

```
2026-10-01 18:48:16.386 dasd Please file a bug for com.apple.webbookmarksd.passwordIconsRepeatingCleanupActivityIdentifier – the activity deferred without being asked to defer
```

Runs come in clusters: 18:48-19:15, 20:48-21:16, 21:28-21:55, 22:06-22:13, 22:35-23:00 and
23:10-23:40. Each cluster sits inside an Oct 1 screen-on span, and the clusters stop when
the screen goes off at 23:39.

---

## Answers to the specific questions

- **ApplePayCloudStoreUnarchivedTask (685 on Sep 22):** a loop (completes, then reschedules
  immediately; dasd flags it 863 times). It runs only on AC, so the battery cost is ~0. The
  685 were wake *requests*; 11 became RTC wakes.
- **chronod.nextScheduledTimelineRefresh (514 on Sep 22):** a loop too, a 300 s no-op
  heartbeat that dasd flags as misbehaving, but on battery it never arms a wake. It costs
  ~100-275 empty process wakeups a day, not RTC wakes.
- **fileprovider indexing/stream-reset:** two episodes, both converged. One-time work that
  each (userspace) reboot retriggers. Expensive while it runs (18 h of cumulative runtime in
  total, ~335k slow-SQL errors in the second episode), but not a true loop.
- **dasd vs battery in general:** on battery, dasd adds no wakes. The wakes come from
  wlan (push/network, ~264/day), locationd (~70/day) and, in BFU, calaccessd. From Oct 1 on,
  the dominant cost is #1.

## What I couldn't determine

- Sep 15-17 isn't in the archive, so the BFU numbers come from Sep 18-21.
- Per-run CPU time isn't logged. "Impact" uses run counts x wall duration plus wake counts.
- Which widget drives chronod's fixed 300 s (identifiers are `<private>`).
- Why passd resubmits with no delay (no reverse engineering done), and whether that
  depends on Wallet having no Apple Pay cards.
- Whether stock iOS also polls DataMigrator every 30 min, and why gpsd exits 255 hourly.
- Screen state for Sep 21-22 (backlight lines only survive for Oct 1 and Oct 3).
- Most of the wlan wakes in IDLE1 (~264/day). The per-topic push breakdown only exists for
  Sep 30 onward, and from Oct 1 the device never slept.

## Method (reproducible)

Scripts and extracts are in `scratchpad/hunt-dasd/` (not committed): `dasd.ndjson`,
`powerd.ndjson` and `xpcact.ndjson` turned into TSV, then `acts.py` (lifecycle parser:
STARTING / COMPLETED / CANCELED / NO LONGER RUNNING / Submitted / waking timers / misuse,
with each `running in a loop` line attributed to the `Submitted Activity` that follows it in
the same millisecond), `wakes.py` (each `Wake ... rtc` attributed to the last selected RTC
request when that request's `time` is within -120..+600 s of the wake), `one.py` and
`episodes.py` (per-activity timelines), `runtime.py` (run time per state and overlap with
screen-on spans), plus targeted `log show` queries for launchd spawns, apsd pushes, gpsd
and passd/chronod internals.
