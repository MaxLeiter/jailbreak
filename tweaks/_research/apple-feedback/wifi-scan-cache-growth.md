# Feedback draft: wifid CPU climbs while Settings > Wi-Fi is open

**Title:** With Settings > Wi-Fi open, wifid's scan-results list grows by one scan's worth every ~10 s (duplicates, no BSSID de-dupe), and its CPU climbs with it

**Area:** iOS > Wi-Fi (secondary: iOS > Battery Life)

**Type:** Performance

## Description

While Settings > Wi-Fi stays open, Settings scans about every 7 to 10 s. After every scan, configd's CaptiveNetworkSupport plugin asks wifid for cached scan results with `SCAN_MAXAGE = -1` (the `Async scan requested by "configd" ... maxage=-1` line follows each `received scan results`). wifid answers from its scan cache by concatenating the retained scans' record lists, and duplicate BSSIDs are carried forward. The served list (`__WiFiDeviceCopyPreparedScanResults: network records count: N`) grows by about one scan's worth per cycle and never drops back while the page is open. Every record in it then goes through `-[WiFiScanObserver ingestScanResults:ofType:clientName:directed:]`, which wraps each one in a `WiFiScanObserverNetwork` and adds it to an `NSMutableSet`. `WiFiScanObserverNetwork` doesn't override `-isEqual:`/`-hash`, so the set removes no duplicates, and downstream consumers process every copy.

## Measured impact (one device, one session)

- `network records count` went from 152 to 7,723 in 45 minutes, against about 250 unique BSSIDs in range.
- wifid spent about 6 s of CPU per ~10 s scan cycle. Its CPU went from 11% to 20% of a core over 11 minutes, and its memory roughly doubled.
- wifid logged 253 MB that day, against about 20 MB on a normal day.
- Collapsing the ingest input to one record per BSSID dropped 2,887 duplicate records in a 4-minute window. wifid then stayed at 2 to 10% CPU with no upward trend, and the network list in Settings didn't change.

The cost scales with how many networks are in range (apartment buildings, offices) and how long the Wi-Fi page stays open.

## Steps to reproduce

1. Go somewhere with many visible networks (dozens of BSSIDs is enough; more makes it clearer).
2. Optional baseline: capture a sysdiagnose before starting.
3. Set Settings > Display & Brightness > Auto-Lock to Never, so the screen stays on.
4. Open Settings > Wi-Fi and leave it on screen for 15 to 20 minutes. Don't navigate away.
5. Capture a sysdiagnose while still on the Wi-Fi page. Restore Auto-Lock afterwards.

## Expected

The record count stays near the number of unique networks in range, and wifid's CPU stays flat while the page is open.

## Actual

The record count rises steadily, by about one scan's worth every 10 s, into the thousands. wifid's CPU per cycle rises with it.

## Log lines that show it (sysdiagnose `system_logs.logarchive`)

```
configd  [CaptiveNetworkSupport] received scan results
wifid    Async scan requested by "configd" for <n> iterations with maxage=-1 ...
wifid    <function>: using scan cache (N) to serve scan request
wifid    ScanCache: Successfully Retrieved Scan Results from Scan Cache.
wifid    __WiFiDeviceCopyPreparedScanResults: network records count: N     <- N grows over the session
```

Queries (from the extracted sysdiagnose folder):

```
log show system_logs.logarchive --info --debug --last 30m \
  --predicate 'process == "wifid" AND eventMessage CONTAINS "network records count"'
log show system_logs.logarchive --info --debug --last 30m \
  --predicate '(process == "wifid" AND eventMessage CONTAINS "maxage=-1") OR (process == "configd" AND eventMessage CONTAINS "received scan results")'
```

For CPU: compare wifid's cumulative CPU time in `ps.txt` between the baseline sysdiagnose and the one taken after 20 minutes.

## Static analysis (iPadOS 17.6.1, 21G93)

- **CaptiveNetworkSupport** (configd plugin, in the shared cache), `_handle_scan_results` at 0x205276db4 (cache vaddr). It's registered through `WiFiDeviceClientRegisterScanUpdateCallback`. Its only guards are "fresh results non-empty" and "a client callback is registered". It then builds `{ "SCAN_MAXAGE": (SInt32)0xFFFFFFFF }` and calls `WiFiDeviceClientScanAsync(device, params, _handle_cached_scan_results, NULL)` on every callback, with no rate limit. The one rate limit in CNS (`_CNPluginStateListShouldSendFilterCommand`) sits downstream and throttles the filter command, not this pull.
- **wifid** (`/usr/sbin/wifid`, standalone, stripped). The serve path (sub_10006f128) builds the reply by `CFArrayAppendArray`-ing each retained cache entry's results array into one array. There's no BSSID uniqueness pass over the output. The cache insert path (sub_1000164ec) appends a new entry per scan and runs an age trim (14 s, or 30 s with `CoreWiFi/UnifiedAutoJoin`), but in practice the served count keeps growing. The mechanism that defeats the trim wasn't determined statically. wifid clamps `maxage=-1` to that same window itself.
- **wifid ObjC:** `-[WiFiScanObserver ingestScanResults:ofType:clientName:directed:]` (0x10001c6ec) wraps each element via `-[WiFiScanObserverNetwork initWithWiFiNetworkRef:]` and adds it to an `NSMutableSet`. `WiFiScanObserverNetwork` implements neither `-isEqual:` nor `-hash`, so the set keeps every duplicate.

## Suggested direction (for the engineer)

Any of these would bound it:

- de-duplicate by BSSID, keeping the newest, when serving cached results;
- give `WiFiScanObserverNetwork` BSSID-based `-isEqual:`/`-hash` (or de-dupe on ingest);
- rate-limit CNS's cached pull after scan callbacks.

---

## Internal (not for the report body)

- **Original discovery:** jailbroken iPad7,12 (A10), iPadOS 17.6.1, through on-device profiling and the persisted unified log. Notes: `tweaks/_research/wifid-scancache.md`. The fix measurement is from the Hush `HushWiFiScan` module (`tweaks/Hush/README.md`), which de-dupes the ingest array by BSSID. It's described in neutral terms above. Don't mention the tweak to Apple.
- **Correction carried from the Hush work:** clamping `SCAN_MAXAGE` in configd changed nothing, because wifid already clamps -1 to the 14/30 s window. So the configd pull sets how often the cost is paid, and the size comes from wifid's cache/serve and ingest. The report says this.
- **Number check:** the research doc's running figure was 152 to 7,423 and the Hush README says 7,723 at 45 minutes. The report uses 7,723 at 45 minutes (README). Recheck against the raw log if it matters.
- **Not yet confirmed on stock hardware:**
  - whether the `network records count` / `maxage=-1` lines are persisted at default log level on a stock device. They may be info/debug only. If they're missing from the sysdiagnose, Apple's Wi-Fi logging profile (developer.apple.com/bug-reporting/profiles-and-logs/) raises wifid's log level. Installing a profile is Max's call;
  - whether the growth happens on current iOS at all;
  - how bad it gets on an iPhone with a modern SoC. CPU per cycle will be lower than on an A10, but the record count is the clearer signal.
- **Current-release static check: not done** (see `REPRO.md` § "Static check of current firmware"). **Verdict for 27.0.1: can't tell from static analysis yet.** To check once you have the binaries:
  - is wifid still a standalone `/usr/sbin/wifid` or folded into a framework?
  - `ipsw class-dump <wifid> --class WiFiScanObserverNetwork`: does it now have `isEqual:`/`hash`?
  - is the `network records count` string still there?
  - CNS `_handle_scan_results`: is it still a `mov w8, #-1` / `"SCAN_MAXAGE"` dictionary followed by `WiFiDeviceClientScanAsync`?
