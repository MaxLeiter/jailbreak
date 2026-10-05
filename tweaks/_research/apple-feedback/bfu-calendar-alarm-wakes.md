# Feedback draft: wakes about once a minute before first unlock when a Calendar alert comes due

**Title:** Device wakes from sleep every ~60 s before first unlock: UserEventAgent `com.apple.alarm` re-fires a past-due Calendar alarm and re-arms it with a fixed 60 s

**Area:** iOS > Battery Life (secondary: iOS > Calendar)

**Type:** Incorrect/Unexpected Behavior

## Description

After a restart, before the first unlock, a Calendar alert that comes due makes the device wake from sleep about once a minute until someone unlocks it.

The owner of the alarm is calaccessd. It can't run before first unlock: its launchd job has no `com.apple.xpc.alarm` launch event, and it is only started after `com.apple.mobile.keybagd.first_unlock`. Its alarm registration (`com.apple.calaccessd.alarmEngine.alarm.name`) is still held by UserEventAgent's `com.apple.alarm` plugin. When the registration's date passes, the plugin:

1. logs `Firing event "com.apple.calaccessd.alarmEngine.alarm.name" which was due N sec ago.`,
2. finds the stored due time still at or before now, because no client advanced it,
3. sets the due time to now + 60 s and logs `Resetting <private> job "com.apple.calaccessd.alarmEngine.alarm.name", now due in 60 seconds.`,
4. calls `IOPMRequestSysWake()` for that time. powerd then logs `Selected RTC wake request: { UserVisible = 0; ... scheduledby = "com.apple.alarm.user-invisible-com.apple.calaccessd.alarmEngine.alarm.name"; time = <now + 60 s> }`.

The device sleeps, wakes for the RTC about 60 s later, and the cycle repeats. Nothing can consume the alarm until first unlock, so the loop has no end and no backoff. The alarm is user-invisible, and no alert can be shown before first unlock anyway, so the wakes do nothing for the user.

## Measured impact

Per-day count of `Firing event "com.apple.calaccessd.alarmEngine.alarm.name"` on one device that sat before first unlock for about six days, then was unlocked:

| | Days | Fires per day |
|---|---|---|
| Before first unlock | 7 | 137, 338, 329, 284, 1,387, 1,412, 818 |
| After first unlock | 9 | 1 to 3 |

Each fire was followed by a matching powerd RTC wake request for now + 60 s. The floor is about one wake a minute. Each wake also brings up Wi-Fi and the rest of the wake path. Measured cost on that device (a 10.2" iPad) was about 0.5% of battery a day. On a phone-sized battery it should be roughly three times that in percentage terms.

Who hits this: anyone whose device restarts (update, crash, battery death and recharge) and isn't unlocked soon after, with at least one pending Calendar alert. Recurring events with alerts are enough. The device that showed it had ordinary daily recurring alerts and no corrupt data.

## Steps to reproduce

1. On an unlocked device, open Calendar and create an event that starts 8 minutes from now, with an alert 5 minutes before (so the alert fires about 3 minutes from now).
2. Unplug the charger. Restart the device right away (power off, power on). Note the time.
3. Don't unlock. Don't enter the passcode, and don't use Face ID or Touch ID, which need the passcode after a restart anyway. Leave the device locked, screen off, for 20 minutes after the alert time.
4. Unlock. Note the time.
5. Capture a sysdiagnose right away (press and release both volume buttons and the side/top button together), then attach it.

## Expected

At most one wake at the alert time. Better: no system wake for a user-invisible alarm whose only consumer can't run before first unlock, with the alarm delivered after unlock.

## Actual

From the alert time until first unlock, UserEventAgent fires the event, re-arms it 60 s out, and requests an RTC wake, about once a minute.

## Log lines that show it (sysdiagnose `system_logs.logarchive`)

Between the restart and the unlock:

```
UserEventAgent [com.apple.xpc.alarm] Firing event "com.apple.calaccessd.alarmEngine.alarm.name" which was due 0 sec ago.
UserEventAgent [com.apple.xpc.alarm] Alarm event "com.apple.calaccessd.alarmEngine.alarm.name" is fired and active.
UserEventAgent [com.apple.xpc.alarm] Resetting <private> job "com.apple.calaccessd.alarmEngine.alarm.name", now due in 60 seconds.
UserEventAgent [com.apple.xpc.alarm] Setting timer for "com.apple.calaccessd.alarmEngine.alarm.name" in 59 seconds.
powerd [com.apple.powerd:wakeRequests] Selected RTC wake request: { UserVisible = 0; appPID = <UserEventAgent pid>; eventtype = wake;
    scheduledby = "com.apple.alarm.user-invisible-com.apple.calaccessd.alarmEngine.alarm.name"; time = "<now + 60 s>"; }
powerd ... Wake ... due to ... rtc
```

- calaccessd logs nothing in that window. Its first line comes within a minute of first unlock.
- After unlock the fires stop. The next RTC request for this alarm jumps to the next real alert time.

Queries (run from the extracted sysdiagnose folder; set the times to the restart and unlock):

```
log show system_logs.logarchive --info --start '<restart>' --end '<unlock>' \
  --predicate 'process == "UserEventAgent" AND eventMessage CONTAINS "alarmEngine"'
log show system_logs.logarchive --info --start '<restart>' --end '<unlock>' \
  --predicate 'process == "powerd" AND eventMessage CONTAINS "calaccessd.alarmEngine"'
log show system_logs.logarchive --info --start '<restart>' --end '<unlock>' \
  --predicate 'process == "calaccessd"'
```

## Static analysis (iPadOS 17.6.1, 21G93)

`/System/Library/UserEventPlugins/com.apple.alarm.plugin/com.apple.alarm`, `PROJECT:UserEventAgent-328.100.1`. The plugin is stripped. The addresses below are file offsets, with the image based at 0.

- The reply/throttle routine at 0x25f4 reads the record's due time (`[rec+0x20]`) and compares it with now. When due time <= now, it adds the immediate `0x0000000d_f847_5800` (59,999,997,952 ns, so about 60 s) and stores it back:
  ```
  0x26a0  ldr  x8, [x21, #0x20]     ; due time
  0x26a4  cmp  x8, x0               ; now
  0x26a8  b.hi 0x26e0               ; still in the future: leave it
  0x26ac  mov  x8, #0x5800 ; movk x8, #0xf847, lsl #16 ; movk x8, #0xd, lsl #32
  0x26b8  adds x8, x22, x8          ; now + ~60 s
  0x26bc  str  x8, [x21, #0x20]
  ```
  Log format at 0x276c: `Resetting %s job "%{public}s", now due in %lld seconds.` The delay is constant. There is no backoff and no retry cap.
- The wake routine builds a CFDictionary with the requester `com.apple.alarm.user-invisible-<event>` and the date, and calls `IOPMRequestSysWake` (call at 0x2c14). Log `Scheduled wake for %.1fs on behalf of "%{public}s".` The user-invisible flag goes into the requester name but doesn't stop the system wake.
- `com.apple.calaccessd.plist` `LaunchEvents` has only `com.apple.notifyd.matching` (including `com.apple.mobile.keybagd.first_unlock`) and `com.apple.xpc.activity`. There is no `com.apple.xpc.alarm` entry, so the alarm firing can't launch calaccessd, and nothing advances the registration before first unlock.
- After unlock, calaccessd's `-[_EKAlarmEngine _installTimerWithFireDate:]` calls `xpc_set_event("com.apple.calaccessd.alarmEngine.alarm.name", ...)` with the next real fire date. That is the only thing that ends the loop.

## Suggested direction (for the engineer)

Any one of these would stop it:

- don't request a system wake for a user-invisible alarm whose owning job can't be launched by the alarm;
- back off (or stop re-arming) when a fired alarm stays unconsumed;
- have calaccessd clear or push out its registration before it can't run.

---

## Internal (not for the report body)

- **Original discovery:** jailbroken iPad7,12 (A10), iPadOS 17.6.1 (21G93). Everything in the loop is stock Apple code (UserEventAgent, the alarm plugin, powerd, calaccessd), and no jailbreak process appears in the cycle. Full notes: `tweaks/_research/calaccessd-bfu-wakes.md`. Evidence: the device's persisted logarchive, Sep 8 to Oct 1 2026.
- **Odd detail:** that BFU stretch (Sep 15 to 21) happened with no kernel reboot, and the cause of the drop back to BFU is unknown (see the Hush memory note). On a stock device a normal restart creates the BFU state, so the repro above uses that.
- **Not yet confirmed on stock hardware:**
  - whether a single fresh alert set just before a restart reproduces the storm. The 17.6.1 device had a registration whose date had already passed. The 17.6.1 notes infer that a fresh one starts the loop once its date passes before unlock, but that hasn't been watched end to end;
  - whether the registration survives a normal restart on current iOS. The 17.6.1 device's did;
  - whether the log wording, event name and 60 s value are unchanged in the current release.
- **Current-release static check: not done.** Current public release is iOS/iPadOS 27.0.1 (24A446, released 2026-09-28). The models picked were iPhone17,3 (iPhone 16) and iPad15,7 (iPad A16). See `REPRO.md` § "Static check of current firmware" for why it wasn't done and how to do it. **Verdict for 27.0.1: can't tell from static analysis yet.** The on-device repro is the confirmation path.
- To check a current plugin once you have it, look for the same immediate (`movk ... #0xf847, lsl #16` / `movk ... #0xd, lsl #32`) near the `Resetting %s job` string xref, the `IOPMRequestSysWake` import, and the `com.apple.alarm.user-invisible` string. Check whether `com.apple.calaccessd.plist` (or the merged `/System/Library/xpc/launchd.plist`) has gained a `com.apple.xpc.alarm` launch event.
- A sysdiagnose holds personal data (network names, device identifiers, app and account details). Attaching one is Max's call.
