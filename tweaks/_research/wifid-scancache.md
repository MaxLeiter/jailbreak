# wifid scan-cache growth bug — RE + hook design (research only)

Device: iPad7,12 (A10, arm64, **not** arm64e), iPadOS 17.6.1 (Darwin 23.6.0), Dopamine rootless, ElleKit.
Scope of this doc: reverse engineering + hook *design*. No tweak written, nothing installed, device touched read-only.

Binaries analyzed (copied read-only from device, sizes verified byte-for-byte against device):
`tweaks/_research/dsc-17.6.1-iPad7,12/` — full dyld shared cache (54 files incl. `.symbols`), `/usr/sbin/wifid`, `CaptiveNetworkSupport.bundle/` (resources only; the CNS Mach-O lives in the shared cache). The whole dir is gitignored except its own `.gitignore`.

Tooling: `ipsw` 3.1.700. Disassembly via `ipsw macho disass <bin> -x __TEXT.__text` (wifid) and `ipsw dyld disass <dsc> --symbol <sym> --symbol-image <img>` (CNS/MobileWiFi, which carry local symbols in the `.symbols` subcache). wifid addresses below are the on-disk link addresses (`__TEXT` @ `0x100000000`); shared-cache addresses are the unslid cache vaddrs.

> **Fact vs inference.** Lines marked **[FACT]** are read directly from disassembly or from the measured logs. Lines marked **[INFER]** are my reconstruction and are flagged where load-bearing. The one thing I could **not** fully determine statically is called out in "Open questions".

---

## 1. Root cause (summary, 3–5 sentences)

While Settings → Wi-Fi is open, Preferences drives an interactive fresh scan every ~7–10 s. **[FACT]** Each time *any* fresh scan lands, wifid fires its registered scan-update callbacks, and CaptiveNetworkSupport's callback `_handle_scan_results` (running inside `configd`) responds by unconditionally asking wifid for the **entire** scan cache with `SCAN_MAXAGE = -1` (no age limit) and no rate-limiting — this is the `Async scan requested by "configd" … maxage=-1` you see after every "received scan results". **[FACT]** wifid serves that from its per-scan cache by **concatenating every retained scan's record list** (`CFArrayAppendArray`, wifid `sub_10006f128`) with **no cross-BSSID de-duplication**, so the reply and the downstream `preparedScanResults` grow by one fresh scan's worth of records per cycle (152 → … → 7423) even though only ~250 BSSIDs are unique. **[FACT]** wifid then pays ~6 s of CPU per cycle flattening/ingesting that ever-larger duplicate-heavy list (per-record `WiFiUsageBssDetails` + `com.apple.wifi.manager` CFPreferences lookups). The trigger is specifically the CNS maxage=-1 re-request loop that only becomes continuous when a fast interactive scan client (Preferences on the Wi-Fi page) keeps feeding fresh scans — matching your observation that pre-Sep-21 logs show no maxage=-1 requests and record counts ≤ ~93. **[INFER, high confidence]**

---

## 2. The two sides of the loop

### 2a. CaptiveNetworkSupport (the trigger) — `configd`

CNS registers a scan-update callback once, then re-pulls the whole cache on every notification.

`_registerForScanResults` (cache vaddr `0x2052751a8`, local symbol) **[FACT]**:
```
bl  _getWiFiManagerClient
bl  _WiFiManagerClientGetDevice
adrp/add x8, _handle_scan_results            ; 0x205276db4
csel x1, xzr, x8, eq                         ; pass callback (or NULL to deregister)
mov  w2, #0x1                                ; enable = true
b    _WiFiDeviceClientRegisterScanUpdateCallback
```

`_handle_scan_results` (cache vaddr `0x205276db4`, local symbol) — the callback. Full body is short; the load-bearing part **[FACT]**:
```
cbz  x2, return                              ; x2 = fresh results array; bail if none
ldr  x8, _S_scan_results_callback ; cbz …    ; bail if no client cb registered
mov  x0, x2 ; bl _CFArrayGetCount ; cbz …    ; bail if fresh list empty
; build params dict { "SCAN_MAXAGE": (SInt32)0xFFFFFFFF }
add  x8, x8, #0x788 ; "SCAN_MAXAGE"
mov  w8, #0xffffffff ; str w8,[sp,#0xc]      ; value = -1
mov  w1, #0x9        ; kCFNumberSInt32Type
bl   _CFNumberCreate
bl   _CFDictionaryCreate                     ; {SCAN_MAXAGE: -1}
…  "received scan results"  (os_log)
adrp/add x2, _handle_cached_scan_results     ; completion = 0x205276ec0
mov  x0, x19                                 ; device ref (callback arg0)
mov  x1, x20                                 ; the {SCAN_MAXAGE:-1} dict
mov  x3, #0                                  ; context
bl   _WiFiDeviceClientScanAsync
```

Key facts from this:
- **`maxage = -1` is literally `(SInt32)0xFFFFFFFF`** written by CNS. **[FACT]** Semantically "return the whole cache, no age cutoff". **[INFER, high confidence — consistent with the served-count behavior]**
- **No rate-limiting here.** The only guards are "fresh list non-empty" and "a client callback is registered". **[FACT]** The CNS rate-limit that does exist (`_CNPluginStateListShouldSendFilterCommand`, `"NOT issuing filter command (elapsed %g < %g)"`) is *downstream* in `_CNScanListFilterHandleScanResults`, i.e. it throttles the FilterScanList command to plugins, **not** the `_WiFiDeviceClientScanAsync(maxage=-1)` cache pull. **[FACT]**
- The completion `_handle_cached_scan_results` (cache vaddr `0x205276ec0`) feeds the full list into the FilterScanList/aggregation path (`_CNScanListFilterHandleScanResults` @ `0x205269928`). **[FACT]**

So: **every** fresh scan ⇒ one full-cache pull ⇒ full-cache processing in configd, at the interactive-scan cadence (~7–10 s). The `configd` requester name you see is just because CNS runs in configd.

Does this happen without Settings open? **[INFER, high confidence]** The callback fires on *any* fresh scan (auto-join, locationd, periodic), so the maxage=-1 pull happens then too — but only at those scans' much slower cadence, and against a much smaller cache (so it was invisible/cheap before). The Wi-Fi settings page is what makes fresh scans continuous (every 7–10 s), which is what makes both the cache grow and the pulls expensive. This matches the Sep-15–21 logs (no maxage=-1, counts ≤ ~93).

### 2b. wifid (the amplifier) — `/usr/sbin/wifid`

**Cache data structure. [FACT]** The scan cache is a `CFMutableArray` of per-scan "cache entries" held on the device object at `*(device + 0x15f8)`. Each entry is a small mutable struct with:
- `+0x10` = request dict (`WiFiCacheEntrySetRequest`, wifid `sub_10014b8ac`: `entry[0x10] = CFRetain(req)`)
- `+0x18` = results array (`WiFiCacheEntrySetResults`, wifid `sub_10014b8dc`: `entry[0x18] = CFRetain(results)` — a **replace**, not a merge)
- a double timestamp (`SetTimestampNow` `sub_10014b90c`; `GetTimestamp` `sub_10014b948`)

**Insert path** (`__WiFiDeviceAddScanCacheEntry`, wifid `sub_1000164ec`) **[FACT]**:
1. Filters WAPI networks out of the fresh results.
2. Copies each record's `AGE` into `ORIG_AGE`.
3. Creates/sets a cache entry (request + `SetTimestampNow` + `SetResults`) and **`CFArrayAppendValue`s it onto `device[0x15f8]`** (`0x1000169bc`). No BSSID comparison against existing entries anywhere on this path — i.e. **no de-dupe on insert**. **[FACT]**
4. Runs an **age trim** on the cache: `ldr x0,[x20,#0x15f8]; fmov d0, d8; bl sub_100016e88` where `d8 = 30.0` if the `CoreWiFi/UnifiedAutoJoin` os_feature is enabled else `14.0` (`fcsel`). **[FACT]**
5. (Re)arms a `dispatch_source` purge timer on `device[0x1608]` for `now + d8` seconds (`0x100016a3c`–`0x100016a68`). **[FACT]** So the timer is pushed out on every insert.

The age-trim helper `sub_100016e88(array, maxAgeSeconds)` **[FACT]**: walks entries from index 0, `age = CFAbsoluteTimeGetCurrent() - GetTimestamp(entry)`; advances while `age > maxAge`; then `CFArrayReplaceValues(array, {0, n}, NULL, 0)` to drop that leading (oldest) run. Standard "evict entries older than maxAge".

**Retrieval / serve path** (the "using scan cache (%ld) to serve scan request" → `WiFiDeviceCopyScanCache`/`sub_10006f128` → `__WiFiDeviceCopyPreparedScanResults`) **[FACT]**:
- `sub_10006f128` builds the served record list by iterating the retained cache entries and `CFArrayAppendArray`-ing each entry's `+0x18` results array into one combined array (`0x10006f2b4`). There is **no cross-entry BSSID de-dupe** of the final record list (the `CFArrayGetFirstIndexOfValue` calls in here operate on channel/ESS grouping sets, not on a BSSID-uniqueness pass over the output). **[FACT]**
- The result is logged as `__WiFiDeviceCopyPreparedScanResults: network records count: %lu` — this is the N you measured. **[FACT]**
- `preparedScanResults` (ObjC property, set by `-[… ] setPreparedScanResults:` at wifid `0x100139e00` inside `sub_1001397c4`) is a **replace**: `sub_1001397c4` does `mutableCopy` of its *input* list, runs per-network recommendation/filtering, and stores the result. **[FACT]** So `preparedScanResults` doesn't itself accumulate — it inherits the already-concatenated size from the flatten step above. **[INFER, high confidence]**

**Why N grows unbounded. [FACT where cited, otherwise INFER]**
- `SetResults` replaces, so growth is **not** intra-entry; it is the **number of retained entries × their per-scan record counts, concatenated with duplicates**. **[FACT: SetResults replaces; flatten concatenates]**
- The only purge observed in your logs is the country-code purge (`scanCache: Purging scan cache`). The 14/30 s age-trim and its dispatch timer never show up as purging. **[FACT, from your log summary]**

**Open question (could not determine statically):** why the insert-time 14/30 s age-trim fails to hold the entry count near ~2 scans under a ~10 s cadence. Two candidate explanations, neither confirmed without dynamic inspection (which the guardrails forbid):
  - **(a)** the entries' stored timestamps are refreshed/clamped such that `age` never exceeds the window (e.g. `SetTimestampNow` on a re-matched entry, or `AGE`→`ORIG_AGE` rewriting feeding the age calc), so the trim keeps evicting ~0 entries; or
  - **(b)** the entries that accumulate live on a path where the trim/timer isn't the governing one (e.g. a separate per-client accumulation), with the country-code purge being the only effective reset.
  Either way the **served** behaviour is the same and the fixes below do not depend on resolving this.

---

## 3. Symbol / hookability map (critical for the tweak)

| Target | Process | Kind | Runtime resolvability |
|---|---|---|---|
| `_WiFiDeviceClientScanAsync` | configd (hook here) / also wifid-adjacent | **exported C** from `MobileWiFi` (`nm -gU` → `T _WiFiDeviceClientScanAsync`, cache vaddr `0x1ba4bd7a8`) | **Resolvable** — real dynamic export. `MSFindSymbol`/`dlsym`/fishhook all work. Easiest robust C hook. |
| `_WiFiDeviceClientRegisterScanUpdateCallback` | configd | **exported C** from `MobileWiFi` (`T`, `0x1ba4c0828`) | Resolvable (not needed for the fix, listed for completeness). |
| `_handle_scan_results`, `_handle_cached_scan_results`, `_registerForScanResults` | configd (CNS) | **static/local C** (CNS, `__TEXT.__text`, local-only symbols) | **NOT** `MSFindSymbol`-able at runtime — these names exist only in the unmapped `.symbols` subcache, not in the in-memory symtab. Would need slide+offset (`offset = 0x205276db4 − CNS __TEXT base`, add the runtime image slide of the CaptiveNetworkSupport image) or a byte-pattern scan. Avoid; hook the exported boundary instead. |
| `__WiFiDeviceAddScanCacheEntry` (`sub_1000164ec`), flatten (`sub_10006f128`), `__WiFiDeviceCopyPreparedScanResults`, `WiFiCacheEntrySetResults` (`sub_10014b8dc`) | wifid | **static C** in wifid | **NOT** symbol-resolvable. wifid is a **standalone, fully-stripped** Mach-O (`nm` shows exactly one defined symbol, `__mh_execute_header`; it is **not** in the dyld cache, so there is no `.symbols` entry for it). These "`__WiFiDevice…`" names appear **only as os_log string literals**, never as nlist symbols. Hooking any of them requires a **byte-pattern scan** (or string-xref-relative resolution) computed against this exact wifid build. |
| `-[WiFiScanObserver ingestScanResults:ofType:clientName:directed:]` | wifid | **ObjC method** (class present in wifid's ObjC metadata) | **Easy `%hook`** — ObjC runtime metadata survives stripping. Also `-[WiFiScanObserverNetwork BSSID]`, `accessPoints`, etc. are available for de-dupe keys. |

Inferred signatures:
```c
// MobileWiFi export, confirmed exported; args read from the CNS call site
void WiFiDeviceClientScanAsync(WiFiDeviceClientRef device,
                               CFDictionaryRef params,       // may carry CFSTR("SCAN_MAXAGE") = CFNumber(SInt32)
                               void (*completion)(WiFiDeviceClientRef, CFArrayRef results, void *ctx),
                               void *ctx);

// MobileWiFi export
void WiFiDeviceClientRegisterScanUpdateCallback(WiFiDeviceClientRef device, bool enable,
                                                void (*cb)(WiFiDeviceClientRef, int, CFArrayRef, void *),
                                                void *ctx);   // enable/cb/ctx inferred from _registerForScanResults
```
Request-dict keys seen on the scan path (wifid `__WiFiDeviceManagerScanAsync` `sub_100014650` reads them): `SCAN_MAXAGE`, `CacheOnly`, `BeaconCacheOnly`, `SCAN_TYPE`, `SCAN_TRIM_RESULTS`, `CHANNEL`, `BSSID`. **[FACT]**

---

## 4. Proposed fixes (minimal, UI-safe) — ranked

The UI invariant to preserve: **do not change which networks appear in Settings, and do not change which network auto-join selects.** Settings' Wi-Fi list is driven by Preferences' own interactive scans and by wifid's known-network/auto-join logic, **not** by CNS's captive-detection cache pull. So anything scoped to the CNS maxage=-1 pull is UI-neutral by construction.

### Fix A — **PRIMARY**: clamp CNS's maxage=-1 pull, in `configd`, at the exported boundary
**Hook:** `_WiFiDeviceClientScanAsync` (exported C from MobileWiFi → `MSHookFunction` after `MSFindSymbol`/`dlsym`). Injected into **configd** via a rootless tweak whose filter targets the configd bundle/executable (CNS loads inside configd).
**What the hook does:** if `params` contains `CFSTR("SCAN_MAXAGE")` equal to `-1` (the CNS cached-re-request signature), make a `CFMutableDictionary` copy and overwrite `SCAN_MAXAGE` with a small bounded age (e.g. **10–15 s**), then call the original with the rewritten dict. Everything else (device, completion, context, all other keys) passes through untouched.
**Effect:** wifid's serve now returns only entries from the last ~10–15 s → N drops to ~1–2 scans' worth → both wifid's flatten/ingest CPU and configd's downstream processing collapse. Captive-portal detection still runs every cycle on a current list; it just stops demanding the full historical cache.
**Kinds:** exported C symbol (robust). No stripped-symbol problems.
**Risk:** LOW–MEDIUM. configd is a critical daemon — the hook must be paranoid (null-check `params`, verify `CFGetTypeID(params)==CFDictionaryGetTypeID()`, verify the value is a `CFNumber` before reading, fall straight through to `orig` on anything unexpected). Worst plausible functional regression: captive detection sees a slightly shorter history; acceptable since a fresh scan just happened. Does **not** touch Preferences' scans or auto-join. **Flagged judgment call:** the exact clamp value (10 vs 15 s) and whether to match *only* `{SCAN_MAXAGE:-1}` with no other discriminating keys — I did not change anything; decide before implementing.

### Fix B — **defense in depth / alternative**: debounce the CNS re-request
**Hook:** same `_WiFiDeviceClientScanAsync` in configd. Instead of clamping, **coalesce** calls carrying `SCAN_MAXAGE==-1`: keep a per-process last-fire timestamp and drop (return success without calling orig) re-requests arriving < e.g. 5 s after the previous one.
**Effect:** cuts the *frequency* of full-cache pulls rather than their size.
**Risk:** MEDIUM. Dropping a call means synthesising a benign return and skipping the completion, or deferring it — fiddly and easy to get wrong (a missed completion could stall CNS state). Clamping (Fix A) is safer because it always calls orig. Prefer A; keep B only if A proves insufficient.

### Fix C — **direct cure, higher cost**: de-dupe-by-BSSID (keep newest) on the served list, in wifid
**Target options:**
- ObjC: `%hook` `-[WiFiScanObserver ingestScanResults:ofType:clientName:directed:]` — collapse the incoming results to one entry per BSSID (newest RSSI/sample) before calling `%orig`. **Easy `%hook`**, but this is the *observer* path; it reduces wifid's own per-record BssDetails/CFPreferences cost but may **not** reduce the configd-facing reply size (that goes through the C flatten). Needs on-device confirmation of which path carries the 6 s.
- static C: de-dupe inside the flatten `sub_10006f128` or `__WiFiDeviceCopyPreparedScanResults`. **Byte-pattern scan required** (wifid stripped). Highest effort/fragility; rebuild-specific pattern.
**Effect:** fixes N at the source for all clients (not just CNS).
**Risk:** MEDIUM–HIGH and it is the option most able to alter the UI: de-dupe must key strictly on BSSID and keep the newest sample so the *set of unique networks and their current RSSI* is identical to today; any over-collapse (e.g. keying on SSID, or dropping band/channel variants auto-join needs) would change the list or auto-join. Only pursue if a cross-client fix is required; otherwise Fix A is smaller and safer.

**Recommendation:** ship **Fix A** alone first (smallest, UI-neutral by construction, exported-symbol hook, no stripped-binary pattern-matching, confined to the captive-detection pull). Hold B and C as fallbacks pending on-device measurement.

---

## 5. Things I could not determine / flags
- **[Open]** Exact mechanism by which wifid's 14/30 s age-trim fails to bound the entry count (see §2b "Open question"). Needs dynamic inspection, which the guardrails disallow; the proposed fixes don't depend on it.
- **[Open]** Whether the 6 s/cycle wifid CPU is dominated by the configd-facing flatten/`CopyPreparedScanResults` or by the `WiFiScanObserver` ingest observer path. This determines whether Fix A alone is sufficient or whether Fix C's ObjC hook is also wanted. Confirm on device by measuring after Fix A (do **not** attach idevicesyslog while the other session is sampling).
- **[Flag — judgment calls left to you]** clamp value for Fix A; the precise predicate for "this is the CNS cached re-request" (I used `SCAN_MAXAGE == -1`); and whether to hook in configd (CNS) vs wifid. All left unchanged pending your call.
- **[Flag — safety]** Both candidate hook hosts (configd, wifid) are critical networking daemons; a faulty hook can break networking or SSH-over-Wi-Fi. Any implementation must fall through to `%orig`/orig on every unexpected input and be tested against dev.repo staging on a recoverable device state first.

## 6. Evidence index (addresses in the copied binaries)
- CNS `_handle_scan_results` @ cache `0x205276db4`; `_registerForScanResults` @ `0x2052751a8`; `_handle_cached_scan_results` @ `0x205276ec0`; `_CNScanListFilterHandleScanResults` @ `0x205269928`; rate-limit `_CNPluginStateListShouldSendFilterCommand` @ `0x2052718a0`.
- MobileWiFi exports: `_WiFiDeviceClientScanAsync` @ `0x1ba4bd7a8` (T); `_WiFiDeviceClientRegisterScanUpdateCallback` @ `0x1ba4c0828` (T).
- wifid: `__WiFiDeviceAddScanCacheEntry` `sub_1000164ec`; age-trim `sub_100016e88`; flatten/serve `sub_10006f128`; `__WiFiDeviceManagerScanAsync` (reads SCAN_MAXAGE) `sub_100014650`; `WiFiCacheEntrySetRequest` `sub_10014b8ac`; `WiFiCacheEntrySetResults` `sub_10014b8dc`; `WiFiCacheEntrySetTimestampNow` `sub_10014b90c`; `WiFiCacheEntryGetTimestamp` `sub_10014b948`; `setPreparedScanResults:` builder `sub_1001397c4` @ call `0x100139e00`. Cache array held at `*(device + 0x15f8)`; purge dispatch source at `*(device + 0x1608)`.
- wifid ObjC: `-[WiFiScanObserver ingestScanResults:ofType:clientName:directed:]` (+ `WiFiScanObserverNetwork` accessors `BSSID`, `accessPoints`, `RSSI`).
- Log strings confirming the path: `"received scan results"` (CNS), `"Async scan requested by \"%@\" for %ld iterations with maxage=%d …"`, `"%s: Scan Requested with Empty Channels List (Scan all channels!) by %@"`, `"%s: using scan cache (%ld) to serve scan request"`, `"__WiFiDeviceCopyPreparedScanResults: network records count: %lu"`, `"ScanCache: Successfully Retrieved Scan Results from Scan Cache."`, `"scanCache: Purging scan cache"` (wifid).
