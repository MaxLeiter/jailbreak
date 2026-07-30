# Shelved patches

Deliberately **not** in any `series` file. Nothing here is applied by
`ladybird-m0-patches.sh`; these are kept because they are finished, validated work whose
motivation went away, and rewriting them from scratch later would be wasteful.

Do not add these to `patches-m0/series` without re-reading the doc that explains why they
were shelved.

## `0010-ios-m0-mach-transport-shared-notify-pipe.patch`

Replaces `TransportMachPort`'s per-transport read-notification pipe with one shared pipe per
thread, dispatching on the `m_read_notification_pending` flag that already exists. Removes two
file descriptors per IPC connection.

**Status: device-validated.** Built and run on iPad7,12; produced a screenshot byte-identical
(52742 bytes) to the unpatched control, via `ladybird --headless=screenshot`.

**Why shelved:** it was written to make kernel-profile sandbox confinement possible, by removing
the `pipe()` call that the `com.apple.WebKit.WebContent` profile denies. Confinement then turned
out to be impossible for an unrelated and unfixable reason (the same profile denies `poll()`,
`select()` and `kevent()`, so `Core::EventLoop` cannot run at all). With that motivation gone,
a concurrency-sensitive rewrite of upstream Mach IPC has no functional payoff, so it is not
worth the divergence from upstream. See
[`../../../docs/ladybird-sandbox-confinement.md`](../../../docs/ladybird-sandbox-confinement.md),
including the startup ordering trap that the patch header documents — get that wrong and
WebContent hangs silently on launch.

Revive it only if the file-descriptor count per IPC connection becomes a real problem.
