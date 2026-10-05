# Feedback draft: passd ApplePayCloudStoreUnarchivedTask resubmits itself immediately after uploading nothing

**Title:** passd `ApplePayCloudStoreUnarchivedTask` uploads 0 transactions and immediately reschedules itself; dasd reports "the activity is running in a loop" (~2,000 runs/day on charger)

**Area:** iOS > Wallet & Apple Pay (secondary: iOS > Battery Life)

**Type:** Performance

## Description

On a charger, passd's cloud-store task runs, finds nothing to upload, and schedules itself to run again right away:

```
passd [com.apple.passkit:CloudStore] PDApplePayCloudStoreContainer starting activity: ApplePayCloudStoreUnarchivedTask
passd [com.apple.passkit:CloudStore] Uploading 0 unarchived transactions
passd [com.apple.passkit:CloudStore] Did upload local data following container setup for transactions:0
passd [com.apple.passkit:CloudStore] Scheduled cloud store fetch activity ApplePayCloudStoreUnarchivedTask
passd [com.apple.passkit:General] Beginning Scheduled Activity: ApplePayCloudStoreUnarchivedTask for Client: ApplePayCloudStoreContainerClientIdentifier
```

It runs five times in under a second. Then dasd's loop detector pushes the next submission out by about 3 minutes and asks for a bug:

```
dasd Please file a bug for <private> – the activity is running in a loop.
dasd Submitted Activity: ApplePayCloudStoreContainerClientIdentifier.ApplePayCloudStoreUnarchivedTask:<id> at priority 30 (<T+3 min> - <T+3 min>)
dasd Setting timer (isWaking=1, activityRequiresWaking=0) ...
```

## Measured impact (one device)

- 1,531 to 1,954 runs a day while on a charger. 2,956 of 4,328 measured intervals were under 1 s. 863 dasd "running in a loop" reports.
- It doesn't run on battery (the activity appears to need external power), so the battery cost is close to zero.
- On a charger with the screen off, the ~3 minute re-arm produced 685 RTC wake requests in one day.
- Cost: passd, UserEventAgent and dasd XPC churn all day while charging. Low impact; filing because dasd asks for it.

## Steps to reproduce

1. Plug the device in and leave it idle, screen off, for 30 minutes or more.
2. Capture a sysdiagnose.
3. Search the log:
   ```
   log show system_logs.logarchive --info --last 1h \
     --predicate 'process == "passd" AND eventMessage CONTAINS "unarchived transactions"'
   log show system_logs.logarchive --last 1h \
     --predicate 'process == "dasd" AND eventMessage CONTAINS "ApplePayCloudStoreUnarchivedTask"'
   ```

## Expected

When there is nothing to upload, the task completes and doesn't resubmit until there's new work or its normal interval comes round.

## Actual

It resubmits immediately and loops until dasd throttles it, then repeats about every 3 minutes for as long as the charger is connected.

---

## Internal (not for the report body)

- **Discovery:** passive log analysis of a jailbroken iPad7,12 on iPadOS 17.6.1 (`tweaks/_research/hunt-dasd.md` #5). There was no reverse engineering of passd/PassKitCore and no static evidence.
- **Open:** it may depend on Wallet state. The iPad may have no Apple Pay cards or an unusual cloud-store container state. Max's iPhone, with real cards, may behave differently. A negative result there doesn't rule the bug out.
- **Current release:** not checked statically (see `REPRO.md`). **Verdict for 27.0.1: can't tell.** The logic is in the shared cache (PassKitCore), so a check needs the dyld cache.
- Low priority. File it only if the stock iPhone shows the loop.
