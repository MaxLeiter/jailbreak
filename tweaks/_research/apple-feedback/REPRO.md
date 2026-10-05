# Confirming the bugs on a stock iPhone

These steps check whether the four bugs found on the jailbroken 17.6.1 iPad also happen on a stock iPhone running whatever iOS it has. The drafts to file afterwards are next to this file:

| Bug | Draft | Your time | Waiting |
|---|---|---|---|
| Wakes every minute before first unlock | `bfu-calendar-alarm-wakes.md` | ~5 min | ~25 min locked, unused |
| wifid list growth on Settings > Wi-Fi | `wifi-scan-cache-growth.md` | ~5 min | ~20 min, screen on |
| chronod 300 s heartbeat | `chronod-timeline-refresh-loop.md` | 0 (piggybacks) | |
| passd cloud-store loop on charger | `passd-applepay-cloudstore-loop.md` | ~3 min | overnight on charger |

Current public release as of 2026-10-05: **iOS / iPadOS 27.0.1 (24A446)**, released 2026-09-28. It's the same build for iPhone 16 (iPhone17,3), iPhone 16 Pro, iPhone 17 Pro, iPad (A16) (iPad15,7) and iPad Pro M4. Note which iOS version your iPhone is on (Settings > General > About) and put it in each report.

## Capturing a sysdiagnose and getting it to the Mac

1. Trigger it: press and release **Volume Up + Volume Down + the side button** together, holding about 1 to 1.5 s. You'll feel a short vibration. If you get a screenshot or the power-off slider instead, try again with a shorter press.
2. Wait about 10 minutes while it's generated.
3. On the iPhone: **Settings > Privacy & Security > Analytics & Improvements > Analytics Data**. Find `sysdiagnose_<date>_iPhone-OS_iPhone_<build>.tar.gz` (newest at the bottom, or search "sysdiagnose").
4. Tap it, tap Share, AirDrop it to the Mac. It lands in `~/Downloads`.
5. On the Mac:
   ```
   cd ~/Downloads
   tar xzf sysdiagnose_<...>.tar.gz
   cd sysdiagnose_<...>
   ls system_logs.logarchive
   ```
   Every `log show` command below runs from that folder. Or just tell me the path and I'll run the analysis.

A sysdiagnose contains personal data (network names, identifiers, account and app details). Look before attaching one to Feedback Assistant.

## 1. Wakes before first unlock (Calendar alarm)

1. Unlock the iPhone. In Calendar, create an event **8 minutes from now** with **Alert: 5 minutes before**, so the alert is due about 3 minutes from now.
2. Unplug the charger. **Restart** the phone straight away (Side + Volume, slide to power off, then power on). Write down the time: `RESTART=__:__`.
3. **Don't unlock it.** No passcode. Leave it face down for **25 minutes**, which takes you past the alert time plus about 20 minutes. Incoming calls are fine; just don't unlock.
4. Unlock. Write down the time: `UNLOCK=__:__`.
5. Take a sysdiagnose right away (see above) and AirDrop it.

Check (put today's date and the RESTART and UNLOCK times in --start and --end):

```
log show system_logs.logarchive --info --start 'YYYY-MM-DD HH:MM:00' --end 'YYYY-MM-DD HH:MM:00' \
  --predicate 'process == "UserEventAgent" AND eventMessage CONTAINS "alarmEngine"'
log show system_logs.logarchive --info --start 'YYYY-MM-DD HH:MM:00' --end 'YYYY-MM-DD HH:MM:00' \
  --predicate 'process == "powerd" AND eventMessage CONTAINS "calaccessd.alarmEngine"'
```

- **Confirmed:** about one `Firing event "com.apple.calaccessd.alarmEngine.alarm.name"` plus `Resetting ... now due in 60 seconds.` a minute after the alert time, and matching powerd `Selected RTC wake request ... scheduledby = "com.apple.alarm.user-invisible-com.apple.calaccessd.alarmEngine.alarm.name"` lines about 60 s apart.
- **Not confirmed:** no repeated firing. Then also run the first query with `CONTAINS "Resetting"` instead of `"alarmEngine"`, in case the event was renamed. If only one fire shows up, that is "fixed or changed" and worth knowing too.

## 2. Wi-Fi scan list growth (Settings > Wi-Fi)

Best somewhere with lots of networks in range (an apartment building or office).

1. Optional baseline: take a sysdiagnose first, so wifid's CPU before and after can be compared.
2. Settings > Display & Brightness > **Auto-Lock: Never**.
3. Open **Settings > Wi-Fi** and leave it on screen for **20 minutes**. Don't touch it. Charging is fine.
4. Still on that page, take a sysdiagnose and AirDrop it. Set Auto-Lock back.

Check:

```
log show system_logs.logarchive --info --debug --last 30m \
  --predicate 'process == "wifid" AND eventMessage CONTAINS "network records count"'
log show system_logs.logarchive --info --debug --last 30m \
  --predicate 'process == "wifid" AND eventMessage CONTAINS "maxage=-1"'
grep -i wifid ps.txt
```

- **Confirmed:** `network records count: N` rises steadily over the 20 minutes into the thousands, far above the number of networks shown, and `maxage=-1` requests from "configd" come every ~10 s.
- **Not confirmed:** N stays flat (roughly the number of nearby networks).
- **Can't tell:** neither line is there. They may not be logged at the default level on a stock phone. Apple's Wi-Fi logging profile (developer.apple.com/bug-reporting/profiles-and-logs/, "Wi-Fi" for iOS) turns them on. Installing it is your call; it expires on its own after a few days. Without it, compare wifid's TIME column in `ps.txt` between the baseline and the 20-minute sysdiagnose.

## 3. passd loop and chronod heartbeat (no extra effort)

Leave the iPhone on the charger overnight, screen off. In the morning, take one sysdiagnose.

```
log show system_logs.logarchive --info --last 8h \
  --predicate 'process == "passd" AND eventMessage CONTAINS "unarchived transactions"' | tail -20
log show system_logs.logarchive --last 8h \
  --predicate 'process == "dasd" AND eventMessage CONTAINS "Please file a bug"'
log show system_logs.logarchive --info --last 8h \
  --predicate 'process == "chronod" AND eventMessage CONTAINS "Scheduling task for"' | tail -20
```

- passd is confirmed by bursts of `Uploading 0 unarchived transactions` every ~3 minutes, plus dasd `running in a loop`.
- chronod is confirmed by `Scheduling task for ... in 300.000000s` repeating, and/or dasd `com.apple.chronod.nextScheduledTimelineRefresh – the activity deferred without being asked to defer`.

The dasd "Please file a bug" query also lists any other activity dasd thinks is misbehaving on the iPhone. Worth a glance.

## Static check of current firmware (not done; your call)

The goal was to diff the 17.6.1 binaries against 27.0.1 without downloading whole IPSWs. That turned out not to be possible with the sanctioned tools:

- `ipsw` 3.1.700 refuses remote extraction for current OTAs: "This OTA is AEA encrypted and is NOT supported for remote extraction (yet)". All 27.0.1 OTAs are `.aea` (iPad15,7: 7.8 GB, iPhone17,3: 9.1 GB).
- The IPSW route needs whole zip members. For iPad15,7 27.0.1, the files we need (UserEventAgent, the alarm plugin, wifid, calaccessd/launchd plists, chronod) are in the root-filesystem member `043-70267-669.dmg.aea` (7.72 GB). CaptiveNetworkSupport and PassKitCore are in the dyld shared cache, probably in `043-69795-713.dmg.aea` (2.35 GB; that's inferred from its size). Full IPSWs: iPad15,7 10.8 GB, iPhone17,3 12.3 GB.
- Free disk during this session was 9.7 to 14 GB, with other agents building. Extracting even the root-filesystem DMG risked filling it, so I didn't.
- I briefly tried a hand-rolled streaming approach outside ipsw's supported paths. A safety check stopped it, and I didn't continue. Nothing from it was kept.

Options:

- **A.** Free about 30 GB, then:
  ```
  ipsw download ipsw --device iPad15,7 --latest -o ~/fw        # 10.8 GB (check `--help` for flags)
  ipsw extract --files -o tweaks/_research/current-ios/iPad15,7_24A446 \
    --pattern '(usr/libexec/UserEventAgent$|UserEventPlugins/com\.apple\.alarm\.plugin/|usr/sbin/wifid$|com\.apple\.calaccessd\.plist$|xpc/launchd\.plist$|ChronoServices\.framework/Support/chronod$)' \
    ~/fw/iPad15,7_27.0.1_24A446_Restore.ipsw
  ipsw extract --dyld -a arm64e -o tweaks/_research/current-ios/iPad15,7_24A446 ~/fw/iPad15,7_27.0.1_24A446_Restore.ipsw   # only for CNS/PassKitCore
  ```
  Then work through the checklists in each draft's "Internal" section. `tweaks/_research/current-ios/` is gitignored.
- **B.** Skip static analysis and file on the strength of the on-device repro. For Apple, a sysdiagnose from a current stock device is the stronger evidence anyway.
