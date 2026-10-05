# Resource-waste hunt: CPU, memory, flash writes (iPad7,12, iOS 17.6.1)

Passive pass over the device's resource reports, jetsam reports, logd volume
stats, launchd's own log, and the per-process rusage samplers. Nothing on the
device was changed; everything below comes from read-only copies.

## Sources

| Source | Window | Notes |
|---|---|---|
| `CrashReporter/*.ips` (362 files) | Jul 26 to Oct 5 | 20 cpu_resource, 8 diskwrites_resource, 25 JetsamEvent |
| Sampler `samp.log` / `samp2.log` | Oct 1 18:43-19:57, 20:00-20:29 | 60 s / 30 s cadence. A userspace reboot happened at 19:57 between them |
| Sampler `samp_long.log` | Oct 5 12:58 onward (28 samples when read) | Still running, not touched |
| samp2 last sample vs samp_long | **Oct 1 20:29 to Oct 5 13:12 (88.7 h)** | Same pid+start on both ends, so the counter deltas are exact 88.7 h averages. Most numbers below use this window |
| `dev2.logarchive` | statistics since 2024-09; message bodies Sep 21 to Oct 5 | Read-only, queried with `log show` |
| `/private/var/log/com.apple.xpc.launchd/launchd.log*` | Oct 1 17:51 to now | Copied read-only |

Symbolication: DSC frames went through `ipsw dyld a2s` with each report's slide.
Main-executable frames went through LC_FUNCTION_STARTS plus the ObjC method table
from binaries copied off the device (UUIDs match the reports). Unnamed blocks
show as `func_X (after -[Class sel])`. Tools and intermediate data are in the
session scratchpad under `hunt-res/`.

Two caveats for every CPU number:

- From Oct 1 ~20:09 the AP never idle-slept, because audiomxd held an AudioOut
  assertion for Max's audio daemons. That is being fixed separately. So
  "screen off" in samp_long means awake AP with a dark screen, not real idle.
- With the screen off, work moves to the slow cores and CPU-time percentages
  roughly triple for the same work. You can see it directly: xios-sensord and
  audiomxd were 7-8% / 6% with the screen on (Oct 1) and 22-24% each with it
  off (Oct 5), and their per-minute curves track each other within a point.
  Compare those percentages as cost, not as work done.

Totals over the 88.7 h window, counting processes alive at both ends:
**216 GB physical writes (58.5 GB/day)** and **62.4 CPU-hours (70% of one core
on average)**. Two of Max's processes and launchd account for most of both:

| Process | Physical writes | Share | CPU | Share |
|---|---|---|---|---|
| xios-sensord | 29.1 GB/day | 49.8% | 21.9% of a core | 31.1% |
| launchd | 14.8 GB/day | 25.3% | 0.1% | |
| kernel_task | 5.7 GB/day | 9.8% | 3.5% | 5.0% |
| fileproviderd | 4.6 GB/day | 7.9% | 7.0% | 9.9% |
| audiomxd | 0 | | 22.7% of a core | 32.3% |
| fseventsd | 0 | | 2.6% | 3.7% |

---

## Ranked findings, Apple and jailbreak side

### 1. launchd is billed for 14.8 GB/day of physical writes, and the cause isn't clear

- **Class:** unknown. Probably jailbreak-induced or a side effect of Max's stack; needs a trace to settle it.
- **Impact:** 14.8 GB/day of flash writes. The 88.7 h total is 54.6 GB. Between Oct 1 18:43 and Oct 5 12:58, pid 1's `ri_diskio_byteswritten` went from 32.7 GB to 96.3 GB (+63.6 GB).
- **Confidence:** high that the number is real. Low on the cause.

Evidence:
- With the screen off on Oct 5, launchd writes at a **steady 113-118 KB/s floor
  (about 9.7 GB/day) in minutes with zero launchd.log lines** (13:03-13:11 in
  samp_long). Busy minutes add about 16 KB per launchd.log line on top of that,
  which looks like one page written synchronously per line. During desktop
  sessions it bursts to 0.8-3.3 MB/s (Oct 1 19:33-19:50).
- launchd.log itself is only about 7 MB/day of text: 41k lines in 2 h on
  Oct 1 (625 `dash` spawns, roughly 5 a minute), 60k lines in the next 19 h,
  then 24k lines in 70 h.
- Across 147 sampler intervals, launchd's writes correlate best with ioscbg CPU
  (r=0.69), audiomxd CPU (0.53), xios-sensord writes (0.52) and fseventsd CPU
  (0.50). Before xios-sensord started on Oct 1 (18:44-19:18), launchd's floor
  went as low as 18 KB/s.
- Open question: what is pid 1 writing? A 10-30 s `fs_usage -w -f diskio` on
  pid 1 would answer it. That is an active trace, so I left it to the main
  session. Hypotheses: Dopamine's launchd hook writing something, or IO being
  billed to launchd through voucher attribution.

### 2. spotlightknowledged rebuilds its knowledge graph from zero every run and never finishes

- **Class:** Apple bug, state-dependent. A jailbreak trigger can't be ruled out.
- **Impact:** each inference run burns 90 s+ of CPU at 52-93% of a core (7 cpu_resource reports between Jul 30 and Oct 2). It drives the 1.5-2.5 GB highwater kills that were already known, and the Sep 22 kill took cloudd and knowledgeconstructiond down with it. When the indexing loop runs, it uses 18 CPU-minutes in 22 wall-minutes. Rough cost on active days: 30-60 CPU-minutes of single-core time plus one big memory spike.
- **Confidence:** high that it loops. Medium on the root cause.

This answers the open question about the known highwater issue: **it is a
never-completing loop.**
- **Every run starts by deleting its own index and reports `graph size 0`.**
  On Oct 1 at 18:53, 22:15 and 22:18, and on Oct 2 at 06:00 and 10:15-10:40,
  each run logs `SKG: deleting index com.apple.spotlightknowledged` and then
  `SKG: graph size 0`. The graph built by the previous run never persists.
- **Indexing retries in a loop.** On Oct 2 from 10:18 to 10:40 there are 17
  back-to-back `event (2) indexing` runs. Each re-extracts the same 500
  archive items ("100 ... 500 archive items extracted", about 70 s), then logs
  `E SKG: unable to index items`. The journal stays at exactly
  `journal size 6668291 / journal count 5`, and the next run starts within 1-60 s.
- dasd flags it directly: `Please file a bug for com.apple.corespotlight.knowledge
  – the activity deferred without being asked to defer`, then
  `Canceled ... ran for 1.1 mins, total runtime 16.8 mins`. The activity is
  resubmitted right away, and the loop ends at `total runtime 18.0 mins`.
- The CPU reports show whole-graph O(nodes x edges) passes, which are the same
  phases over and over:
  ```
  -[SpotlightKnowledge processGraphWithGroup:cancelBlock:] + 628
   -[SpotlightKnowledge analyzeGraphWithCancelBlock:]
    -[SpotlightGraph locked_peopleAnalyzeWithCancelBlock:] + 572
     -[SKGNames enumerateNamesInGraph:usingBlock:]
      KnowledgeGraphKit`-[KGNodeCollection enumerateElementsWithBatchSize:usingBlock:]
       func_100047858 (block in locked_peopleAnalyze) + 1272
        CoreFoundation`-[__NSSetM addObject:] -> -[SKGEdge isEqual:]
  ```
  That analyzePeople pass appears in 4 of the 7 reports (Jul 30, Sep 22 04:09,
  Sep 22 16:11, Oct 2 06:00). scorePeople (`locked_peopleUpdateNetwork` ->
  `degas::NeighborQuery`) appears on Sep 21 16:14 and Oct 1 19:11, and
  `-[SKGGraph addNodes:addEdges:]` -> `degas::...sqlite3_step` on Sep 21 16:48.
  Every report has a different pid.
- Memory: on Oct 1, pid 60082 went from 15 MB to **996 MB in 4 minutes** once the
  iPad locked (19:15-19:19, samp.log). It then logged `should defer` and
  `clearing spotlight knowledge` and exited with nothing saved. On Sep 22 at
  16:26, 15 minutes after the 16:11 CPU report, the same process hit 2,490 MB
  and was jetsammed.
- Possible side effect (low confidence): every run does `delete-all-items` and
  then re-indexes, which churns the CoreSpotlight index that searchd then has to
  merge (finding 3).

### 3. searchd's index merge rewrites the store at up to 11 MB/s after reboots

- **Class:** Apple by design (index compaction), with pathological write amplification. Reboots trigger it, and Dopamine's re-jailbreak reboots make that more frequent.
- **Impact:** **5.4 GB in 62 minutes** on Sep 21 (1,073 MB at 318 KB/s, then 4,295 MB in 392 s at 10.95 MB/s). Oct 1 after the reboot: 688 MB in 74 minutes, with a 10 MB/s minute at 18:50. On the order of 1-5 GB of flash per reboot.
- **Confidence:** medium-high.

Symbolicated heaviest stack, 417 of 418 samples, Kernel mode:
```
MobileSpotlightIndex`_compaction_runLoop -> _si_mergeIndex -> _MergeIndexes -> _OuterMerge
 -> _InnerMerge + 3944 -> _si_remapForIndex -> _db2_get_obj_callback
  -> _page_find_oid_with_flags -> __page_fetch_with_fd -> _db_cache_flush_entry
   -> __flush_cache_entry -> _fd_pwrite -> pwrite   <on behalf of pid 31>
```
During the remap step, every page fetch evicts and writes back a dirty cache
page, so the page cache is thrashing. The first report also shows
`_shadow_datastore -> _fd_copyfile` copying the whole datastore (26 of 89 samples).

### 4. photoanalysisd's graph build gets jetsammed at the per-process limit and starts over

- **Class:** Apple by design (nightly work on AC), made worse by the jetsam limit.
- **Impact:** low on battery because it runs on AC at night. Each kill throws away 90 s+ of CPU and restarts a full-library pass.
- **Confidence:** medium.

- CPU reports on Sep 21 21:29 and Sep 22 04:31 show `-[PGManager(Analysis_Internal)
  performFullLibraryAnalysisInGraph:...]` and `PGGraphBuilder performBatchUpdates`.
  Jetsam `per-process-limit` killed photoanalysisd 28 minutes and 11 minutes later
  (rss 36 / 44 MB, lifemax 59 / 69 MB).
- On Oct 1-2, `PHAGraphRebuildTask` (`PHAGraphForceGraphRebuildTask was never
  run previously, due now`) `failed in 8m: Cancelled` at 23:10, ran again at
  02:27, and `completed in 5m 53s`. Later runs were incremental (42 s to 8 min).
  So it does complete eventually. This is waste, not an infinite loop.

### 5. audioanalyticsd footprint grew 19x in 3.7 days

- **Class:** possible Apple leak, triggered by the always-running audio session from Max's stack.
- **Impact:** +56 MB in 88.7 h (3.1 to 59.2 MB, about +15 MB/day).
- **Confidence:** low-medium. Only two far-apart points plus short series.

During samp2 it grew 2.3 to 3.0 MB in 25 minutes. During the first 27 minutes of
samp_long it was flat at 59.0-59.2 MB, so the growth is bursty. Its log shows 52
`Created session` and 50 `destroySession()`, plus `Worker not started, cannot
send message to PowerLog`. **Re-check at 12 h in samp_long.**

### 6. Smaller memory growers and kill-relaunch churn

- **Class:** Apple. **Confidence:** low.
- Over the 88.7 h window: assetsd 10.1 to 30.7 MB (+20.6), lockdownd 3.2 to 13.0 MB
  (+9.8), searchd +7.6, IntelligencePlatformComputeService +6.9, appstored +5.4,
  assistant_cdmd +5.3, siriknowledged +5.0. Every other long-lived process
  changed by less than 5 MB.
- Jetsam per-process-limit kills: assetsd 4 times (Sep 21 20:17, 20:58, 23:07, Sep 22 09:11,
  rss 20-30 MB, lifemax up to 64 MB); contactsdonationagent 5 times (6-18 MB).
  assetsd is now at 30.7 MB and still climbing (+3 MB/h in samp_long), back in
  the range where it was killed before.
- Also: passd wrote 2.1 GB in 88.7 h (0.6 GB/day) and assetsd 3.9 GB
  (1.1 GB/day). Not explained. Worth a look if flash writes matter.

### 7. diagnosticd uses 10-45% of a core whenever something streams logs

- **Class:** tooling-induced (log streaming from a host or session), not a bug.
- **Impact:** 9.8% average from Oct 1 18:43 to 19:57, 20-45% in 19:19-19:43, and 23.7% while the screen was blank. Zero when nothing is attached (not running in samp_long).
- **Confidence:** high.

Worth knowing when several sessions share the iPad: a long-lived `log stream`
or OSLogStore reader costs about as much as a busy daemon.

### 8. Sandbox-denied XPC lookups retried thousands of times a day

- **Class:** Apple bug (benign retry loop).
- **Impact:** small CPU. It inflates launchd.log, and finding 1 suggests each line costs about 16 KB of synchronous write.
- **Confidence:** high on the counts.

`denied lookup: name = com.apple.imagent.embedded.auth, requestor = mediaanalysisd`
appears 3,608 times (plus 3,665 matching `Sandbox violation` lines) in 19 h of
launchd.log.1, and 1,868 more times since Oct 2 15:00. siriactionsd hits the
same endpoint (188), and searchpartyd's `findmylocate.locationservice` lookup
is denied 235 times. The XPC_EXIT_REASON_FAULT user-fault reports (apsd 27,
icloudsubscriptionoptimizerd 25, siriactionsd 13, imagent 10) are the same
family of denials and aren't a resource problem by themselves.

### 9. knowledgeconstructiond builds a new NSDataDetector for every item

- **Class:** Apple inefficiency. **Impact:** minor (one report). **Confidence:** medium.

Sep 22 04:00, 90 s of CPU in 108 s. Inside a GRDB write transaction, 5 of 22
samples are in `-[NSDataDetector initWithTypes:error:] -> _DDScannerCreate` and 6
are in `enumerateMatchesInString`. It builds a new scanner per item instead of
reusing one.

---

## Max's stack (separate section)

### M1. xios-sensord rewrites 9 files 10 times a second: 29 GB/day of flash writes and a fifth of a core

- **Impact:** this is the biggest single item in the whole hunt.
  - **Physical writes:** 353 KB/s, which is **29.1 GB/day**, measured over 88.7 h. It's half of all physical writes on the device.
  - **Logical dirtied pages:** 1.44 MB/s, about 125 GB/day. The kernel filed `diskwrites_resource` reports at every tier: 1 GB, 4 GB, and **17.18 GB in 3.3 h** (Oct 1 21:06 to Oct 2 00:25). Earlier reports came on Jul 29, Aug 3, and twice on Aug 6, so it happens every time the desktop session runs.
  - **CPU:** **21.9% of a core** (19.4 CPU-hours in 88.7 h), or 7-10% with the screen on.
  - **Knock-on cost:** fseventsd went from 0.01% CPU and 1.6 wakeups/s before the session to 1.0% and 29/s after it, and is 2.6% and 47/s now. kernel_task's APFS work adds more.
  - **Gyroscope:** CoreMotion keeps accel, gyro and magnetometer running at 10 Hz, and the gyro is a real power draw on its own.
- **Confidence:** high.

Evidence:
```
1611/1611 samples, Kernel mode (diskwrites_resource-2026-10-02-002508):
xios-sensord`_main + 1212
 libglib-2.0.0.dylib`g_main_loop_run + 128          (UUID C450365B = /var/jb/usr/lib/libglib-2.0.0.dylib, verified)
  xios-sensord`_poll_motion + {756,796,836,876,920,964,1004,1044,1088}   <- the 9 writef() calls
   xios-sensord`_writef + 88
    libglib`g_file_set_contents_full + 324 -> libsystem_kernel`write
    (also g_file_set_contents_full -> open / rename)
```
- The math lines up exactly. 9 files x 10 Hz x one 16 KB page is 1,440 KB/s,
  and the report says 1,444.98 KB/s. 9 x 10 x 4 KB APFS blocks is 360 KB/s,
  and the sampler measured 353 KB/s. That means every replacement file reaches
  flash: `g_file_set_contents` writes a temp file, syncs it, and renames it over
  the old one.
- Live on the device: `iio:device0/` files have a 13:19 mtime, and a temp file
  `in_accel_x_raw.13GOD4` was caught mid-replace. There are also 7 orphaned temp
  files from older crashes dating back to Jul 2.
- In `x11/packages/xios-fhs/src/xios-sensord.m`, `g_timeout_add(POLL_MS=100,
  poll_motion)` runs unconditionally. `update_iio_values()` rewrites all 9 files
  every tick even when nothing changed, and `accel_claims` is counted but never
  used to gate polling. The only consumers of the IIO mirror in the repo are docs
  and postinst; the D-Bus `AccelerometerOrientation` signal is what clients use.
- Footprint 2.1 to 6.0 MB over 88.7 h (about +1 MB/day). Could be a slow leak.
  Low priority.

Suggested fix (not applied, for Max to decide): gate polling and the CoreMotion
updates on `accel_claims > 0`. Write the IIO files only when a value changes, or
drop the mirror until something reads it. If it has to stay, use plain
`pwrite` on fds kept open instead of `g_file_set_contents`. Any one of these
removes about 29 GB/day.

### M2. The audio daemons keep audiomxd busy around the clock

- **Impact:** audiomxd uses **22.7% of a core** (20.1 CPU-hours in 88.7 h, 74 wakeups/s), the largest CPU consumer on the device. That's on top of preventing idle sleep, which is already being fixed.
- **Confidence:** high.

Per-process numbers over the 88.7 h window, as requested:

| Process | pid | CPU | Footprint | Wakeups/s | Writes |
|---|---|---|---|---|---|
| audiomxd | 64792 | 22.7% | 22.4 to 22.6 MB | 74 | 0 |
| xios-audiod | 66108 | 0.58% | 2.2 MB flat | ~0 | 0 |
| xios-mediad | 66115 | 0.63% | 2.2 MB flat | 5.8 | 0 |
| pulseaudio | 65328 | 0.00% | 2.2 MB | 0 | 0 (idle the whole window) |
| audioanalyticsd | 64798 | ~0.3% | **3.1 to 59.2 MB** | | see finding 5 |

audiomxd's per-minute CPU tracks xios-sensord's almost exactly. Both have a fixed
work rate, so they scale together with core and clock changes. Expect audiomxd
to drop to near 0 once the audio units stop when idle.

### M3. ioscbg redraws desktop stat widgets every 2.5 s, even with the screen off

- **Impact:** ioscbg 1.6% plus iosc 1.9% of a core with the screen off (1.4 + 1.7 CPU-hours in 88.7 h).
- **Confidence:** medium.

In the `x11/apps/iosc-shell/ioscbg.c` main loop, the poll timeout is 1000 ms,
`pins_reload_if_due` runs every 1 s, and `widgets_update_stats()` /
`render_desktop_widgets()` run every 2.5 s. Load average and memory change every
tick, so it re-renders and iosc composites, whether or not anything is on screen.
Gating these on the display or occluded state would save most of it.

### M4. ipadctld crash-looped against its jetsam limit (resolved)

On Oct 1 from 23:04 to 23:17 there were 25 spawn-and-kill cycles at launchd's
10 s throttle: `JETSAM_REASON_MEMORY_PERPROCESSLIMIT, ran for 482ms`, 20 MB limit
(6 JetsamEvent reports). The memory notes say it was fixed by raising the limit,
and nothing has happened since Oct 1 23:17. Listed only so nobody chases those
reports again.

### M5. plasmashell dirtied 1 GB in 2 h (Jul 29, old)

One `diskwrites_resource` report: 1,073 MB of file-backed memory dirtied over
7,423 s (145 KB/s) during a KDE session. The frames are in unsymbolicated Qt/KF6
dylibs. It hasn't recurred, and KDE isn't running in any sampler window. Revisit
only if a Plasma session becomes a daily driver.

---

## Already known: extra evidence only

- **fileproviderd re-index (known):** it reruns after each userspace reboot as
  well as full boots. The Oct 1 19:38 and 20:06 CPU reports have different pids
  on either side of the 19:57 userspace reboot, and have the same stack.
  In-memory logs ran 6.5 GB from Oct 1 18:00 to Oct 2 04:00. FPCKService
  (`-[FSChecker enumerateItemsOnDiskAtURL:...]` on behalf of fileproviderd) adds
  90 s+ of CPU. The persisted-log history shows the same storm takes
  filecoordinationd (2.9 GB) and containermanagerd (2.2 GB) with it on Jun 10,
  Jun 28 to Jul 1, Oct 7 2025 and Sep 2024. fileproviderd accounts for 4.6 GB/day
  of physical writes in the 88.7 h window.
- **wifid (fixed):** Oct 1 persisted 531 MB of logs, and samp.log shows 9.7% CPU
  before the fix. It is back to about 1% in samp_long.
- **spotlightknowledged highwater (known):** explained by finding 2.

## Memory: samp_long status at hand-off

samp_long had only 28 samples (27 min) when I read it, so slopes from it are
noise (for example, mediaanalysisd "+1240 MB/h" was just a process starting
up). The 88.7 h endpoint comparison above is the real evidence. At the 12 h
mark, check slopes for audioanalyticsd, assetsd, lockdownd, xios-sensord,
IntelligencePlatformComputeService and siriknowledged, and check whether assetsd
crosses about 35 MB and gets jetsammed again. Also, IntelligencePlatformComputeService
wrote 274 MB and used 10% CPU in the last 10 minutes of that window. It looks
like maintenance, but confirm it stops.

## Open questions

1. What does launchd (pid 1) write at a steady 115 KB/s? It needs an `fs_usage`
   trace on pid 1, which only the main session should approve.
2. Why does spotlightknowledged delete its index at the start of every run, and
   why does `unable to index items` fail? The error is `<private>`, so a
   private-data log profile would show it. Is a jailbreak-side condition (for
   example a container or sandbox denial) behind it?
3. UserEventAgent holds about 29-35 wakeups/s even before Max's session started.
   I don't have a stock baseline to compare against.
4. Something spawned about 5 `dash` processes a minute on Oct 1 between 17:51 and
   19:57 (625 in launchd.log.2), before the desktop session. The source is
   unknown, and each spawn adds launchd.log lines.
