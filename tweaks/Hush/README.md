# Hush

Two fixes for iOS 17 bugs that burn battery and CPU for nothing. Found on an
iPad7,12 (A10) on iPadOS 17.6.1 by profiling the device and reading its
persisted unified logs. Each module is a no-op unless its target looks exactly
as expected.

## HushBFUWake (UserEventAgent)

Before the first unlock after a boot, calaccessd can't run. UserEventAgent's
`com.apple.alarm` plugin still holds a past-due registration for
`com.apple.calaccessd.alarmEngine.alarm.name`, fires it, re-arms it 60 s out and
calls `IOPMRequestSysWake()` every time. The device wakes once a minute until
someone unlocks it.

Evidence from the device logs: 137 to 1,418 of these wakes a day on every
never-unlocked day from Sep 8 to 21, 0 to 6 a day once unlocked. powerd names
the requester (`scheduledby = "com.apple.alarm.user-invisible-com.apple.calaccessd.alarmEngine.alarm.name"`),
and calaccessd's first log line in the whole archive is the minute of first
unlock. Battery cost on this iPad was about 0.5% a day; on a phone-sized
battery it would be roughly three times that in percentage terms.

The hook drops only wake requests whose `scheduledby` names a user-invisible
calaccessd alarm, and only while `MKBDeviceUnlockedSinceBoot()` returns 0. Any
error from MobileKeyBag counts as unlocked.

Verified: loads into UserEventAgent and passes every request through while the
device has been unlocked. Not yet verified: catching it suppress a wake. A
`launchctl reboot userspace` kept the unlocked-since-boot state here, so I
couldn't recreate the bug on demand. The Sep 15 to 21 episode happened with no
kernel reboot, so some userspace restarts do drop back to the never-unlocked
state while the jailbreak stays active; that is the case this module covers.
After a full reboot on a semi-untethered jailbreak like Dopamine, no tweak is
loaded until you re-jailbreak, which needs an unlock anyway.

Research: `tweaks/_research/calaccessd-bfu-wakes.md`.

## HushWiFiScan (wifid)

While Settings > Wi-Fi is open, configd's CaptiveNetworkSupport pulls wifid's
whole scan cache after every scan. wifid serves it with duplicates carried
forward, so the list grows by one scan's worth every ~10 s (152 records to
7,723 in 45 minutes, about 250 unique BSSIDs). Every record then goes through
`-[WiFiScanObserver ingestScanResults:ofType:clientName:directed:]`, whose
analytics consumers spent about 6 s of CPU per cycle on it. wifid's CPU climbed
from 11% to 20% of a core over 11 minutes, its memory roughly doubled, and it
wrote 253 MB of logs that day against about 20 MB normally.

The hook collapses result arrays of 64 or more records to one record per BSSID
(the one with the smallest `AGE`) before the original runs. The elements are
wifid's private `WiFiNetwork` CF objects; the record dictionary is read at
+0x10, which is checked on 17.6.1 only, so the read is gated to iOS 17 and on
the CF type name, a malloc-zone check on the pointer, and the field being a
dictionary with a string BSSID. Anything else goes to the original unchanged.

Verified live: with Settings > Wi-Fi open for about four minutes it kept 2,887
duplicate records out of the ingest, wifid stayed at 2 to 10% CPU with no
upward trend, and nothing crashed. A longer run would show the flattening at
the 45-minute mark more clearly.

Research: `tweaks/_research/wifid-scancache.md`.

## Kill switches

Set `BFUWake` or `WiFiScan` to NO in
`/var/jb/var/mobile/Library/Preferences/com.max.hush.plist`. Read once when the
daemon starts.

## Counters

Each module publishes notify state you can read with `notify_get_state`:
`com.max.hush.bfuwake.loaded`, `com.max.hush.bfuwake.suppressed`,
`com.max.hush.wifiscan.loaded`, `com.max.hush.wifiscan.dropped`.
