# Feedback draft: chronod's 300 s no-op timeline-refresh heartbeat

**Title:** chronod re-arms `com.apple.chronod.nextScheduledTimelineRefresh` every 300 s without reloading anything, and its handler defers and completes in the same callback (dasd: "deferred without being asked to defer")

**Area:** iOS > Widgets (secondary: iOS > Battery Life)

**Type:** Performance

## Description

chronod keeps a wake/refresh activity that fires, reloads nothing, and schedules itself again exactly 300 s later:

```
chronod [com.apple.chrono:wake] Wake event fired for date: <T>
chronod [com.apple.chrono:wake] Scheduling task for: <T + 300 s> in 300.000000s
```

In the same callback the handler sets the XPC activity to DEFER (state 4) and then DONE (state 5):

```
chronod [com.apple.xpc.activity:Client] _xpc_activity_set_state: com.apple.chronod.nextScheduledTimelineRefresh (...), 4
chronod [com.apple.xpc.activity:Client] _xpc_activity_set_state: com.apple.chronod.nextScheduledTimelineRefresh (...), 5
```

dasd flags this itself:

```
dasd Please file a bug for com.apple.chronod.nextScheduledTimelineRefresh – the activity deferred without being asked to defer
```

Most likely one widget timeline's next date is already in the past, or inside a minimum interval, and chronod clamps it to 300 s indefinitely. The timeline involved isn't named in the logs (`<private>`).

## Measured impact (one device)

- 106 to 277 activity runs a day, depending on how much the device sleeps. 275 `Wake event fired` and 290 `Scheduling task` lines in 24 h, against a few dozen real reloads.
- About half the runs on battery end as CANCELED. dasd filed 817 "deferred without being asked" reports over the logged period, 53 to 77 a day.
- On a charger it was a top RTC wake *requester* (514 requests in one day), though only 5 became actual wakes. On battery it piggybacks on other wakes, so the cost is CPU and process wakeups, not extra sleep wakes. Low impact; filing because dasd asks for it.

## Steps to reproduce

1. Use a device with several Home Screen / Today View widgets for a day. The affected device had Photos, TV, a third-party calendar widget and Wallet (Apple Card) widgets.
2. Capture a sysdiagnose.
3. Search the log:
   ```
   log show system_logs.logarchive --info --last 24h \
     --predicate 'process == "chronod" AND eventMessage CONTAINS "Scheduling task for"'
   log show system_logs.logarchive --last 24h \
     --predicate 'process == "dasd" AND eventMessage CONTAINS "chronod.nextScheduledTimelineRefresh"'
   ```

## Expected

The refresh activity fires at the next real timeline date (or backs off), and doesn't defer and complete in the same callback.

## Actual

A constant 300 s cadence with no reload. dasd reports misuse every few runs.

---

## Internal (not for the report body)

- **Discovery:** passive log analysis of a jailbroken iPad7,12 on iPadOS 17.6.1 (`tweaks/_research/hunt-dasd.md` #4). There was no reverse engineering of chronod and no static evidence.
- **Not confirmed on stock hardware:** whether it happens there at all, and which widget drives it. It may be state-dependent (a specific widget with a stale timeline).
- **Current release:** not checked statically (see `REPRO.md`). **Verdict for 27.0.1: can't tell.** The binary is `/System/Library/PrivateFrameworks/ChronoServices.framework/Support/chronod` if someone pulls it later. Look for the `Scheduling task for: %@ in %fs` and `Wake event fired for date` strings and the 300.0 constant.
- Low priority. File it only if the stock iPhone sysdiagnose shows the same 300 s cadence or the dasd misuse line.
