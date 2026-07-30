# Confining Ladybird helpers with iOS's precompiled sandbox profiles

**Conclusion: impossible, and not for a fixable reason. Do not retry this.**

`com.apple.WebKit.WebContent` denies `poll()`, `select()` **and** `kevent()`. Ladybird's
`Core::EventLoop` waits on file descriptors, so a confined helper cannot wait for events at
all. There is no call site, no patch, and no alternative event-loop backend that gets around
it: the profile forbids descriptor waiting outright, because Apple's real WebContent waits on
Mach messages instead. The other available profile, `container`, leaves the network reachable
and so removes nothing worth having from a renderer.

Everything below was measured on iPad7,12 (A10 / T8010, iPadOS 17.6.1, Dopamine rootless)
with fakesigned throwaway binaries, as both `root` and `mobile`. Probes are in
`x11/linux-build/probes-ladybird-sandbox/`. Background on what the platform offers at all is
in `ios-platform-features.md` section 1.

## The capability matrix

Baseline vs confined, same binary, same paths. For the wait primitives the fds are created
*before* confinement, which is the only way a confined process could have any.

| capability | unconfined | `com.apple.WebKit.WebContent` | `container` |
| --- | --- | --- | --- |
| read `/var/jb` dylib, `/System` frameworks, fonts | OK | OK | OK |
| CoreText: family enumeration, glyph lookup (cold) | OK | OK | OK |
| `mach_port_allocate` RECEIVE / PORT_SET, `insert_right` | OK | OK | OK |
| `mach_msg` on an already-held port | OK | OK | OK |
| `pthread_create` | OK | OK | OK |
| `read()` on a pre-made pipe | OK | OK | OK |
| **`poll()`** on a pre-made pipe | OK | **DENIED** | OK |
| **`select()`** on a pre-made pipe | OK | **DENIED** | OK |
| **`kevent()`** on a pre-made kqueue | OK | **DENIED** | OK |
| `pipe()` | OK | **DENIED** | OK |
| `bootstrap_look_up` | OK | **DENIED** (0x44c) | not retested |
| `socket(AF_UNIX)` | OK | DENIED | OK |
| `socket(AF_INET)` | OK | DENIED | **OK** |
| write `/var/jb/tmp` | OK | DENIED | DENIED |

The profile applies (`rc=0`) to an unconfined root process and to `mobile` alike. **Success
from `sandbox_init_with_parameters` says nothing about whether the process can still
function** — that was the trap in this whole investigation.

## What it took to find the real blocker

Worth recording, because each layer looked like the answer:

1. **The call site.** `bootstrap_look_up` is denied, so confining before the Mach handshake
   leaves a helper with no IPC channel (`0x44c BOOTSTRAP_NOT_PRIVILEGED`). Rights already
   held keep working, so confinement has to follow the handshake. Fixable by moving the call.
2. **`pipe()`.** `TransportMachPort`'s constructor did `MUST(Core::System::pipe2(...))` per
   transport, to bridge its Mach IO thread to the poll-based event loop. Transports are
   created long after startup, including by `MessagePort::entangle_with` for every
   `new MessageChannel()` in page JavaScript, so confinement would have handed any website a
   renderer abort. Also fixable: one shared pipe per thread instead of one per transport.
   That patch was written, built, and **validated on device** (see below).
3. **`poll()`/`select()`/`kevent()`.** Not fixable. With the pipe problem solved, a confined
   ImageDecoder got exactly one step further and died in the event loop itself:

   ```
   [status] sandbox=applied process=ImageDecoder profile=com.apple.WebKit.WebContent
   ImageDecoder(19672): EventLoopImplementationUnix::wait_for_events: poll: Operation not permitted (errno=1)
   VERIFICATION FAILED: false at Libraries/LibCore/EventLoopImplementationUnix.cpp:406
   ```

The device A/B that produced this used three runs off one build: unpatched control, patched
with `LADYBIRD_IOS_SANDBOX=0`, and patched with confinement on. The control and the
sandbox-off run both produced a byte-identical 52742-byte screenshot; only the confined run
failed. That is what makes the attribution airtight.

## The shared-notify-pipe patch (validated, not retained)

Layer 2's fix worked and is worth knowing about if the fd count per IPC connection ever
matters: one read-notification pipe per *thread* rather than per *transport*, with dispatch
scanning the thread's registered transports for the `m_read_notification_pending` flag that
already existed. It removes two fds per IPC connection. It was device-validated
(byte-identical screenshot to the unpatched control).

It is **not** in the patch series, because its only purpose was to enable confinement and
confinement is unreachable. Carrying a concurrency-sensitive rewrite of upstream Mach IPC
with no functional payoff is not worth the divergence. If it is ever revived, the ordering
trap that cost a build cycle is this:

> The channel must be joined in the transport **constructor**, not in `set_up_read_hook()`.
> Creating it in `set_up_read_hook()` loses the first message on every connection: the IO
> thread sets the pending flag with no channel to ring, and the catch-up path then asks
> `schedule_read_notification_if_needed_locked()` whether to ring, is told "already pending,
> someone else will", and nobody ever does. WebContent hangs on startup with no output. The
> catch-up must therefore ring unconditionally rather than consulting that helper.

## What to do instead

The fallback named in `ios-platform-features.md`: uid separation, `setrlimit`, and
entitlement minimisation. The last of those is the cheapest real win available, because the
current helper entitlements are far broader than a renderer needs
(`x11/packages/ladybird-app/entitlements/ladybird-helper.entitlements`):

- `task_for_pid-allow` and `com.apple.system-task-ports` — cross-process inspection, which a
  renderer has no business holding.
- `com.apple.security.exception.files.absolute-path.read-write` over all of `/var/jb/` —
  WebContent has no runtime write requirement at all. The Skia cache directory the macOS
  profile grants read-write has no writer anywhere in the tree, and the HTTP disk cache and
  alt-svc cache belong to RequestServer.
- The AGX/IOGPU IOKit classes are needed by Compositor, not by WebContent or ImageDecoder.

Note that entitlements and the sandbox are independent layers: writes were denied under
confinement even as root with that read-write path exception present. So trimming
entitlements is a real restriction, not a cosmetic one.

## Other notes

- Flags must be `0x1` (`SANDBOX_NAMED`); `0x3` is refused with "profile not found".
- The profile permits `mprotect` RW to RX, so it is not a W^X guarantee. It does not matter
  here because LibJS is built interpreter-only (`-DENABLE_CRANELIFT_JIT=OFF`), but do not
  describe it as preventing code injection.
- RequestServer was never a candidate: it needs network, and this profile denies `socket()`.
- Visibility, if any of this is revived: emit the `[status] sandbox=...` line on stderr, not
  through an `iosc_status` sidecar file. A confined process cannot write the sidecar, so that
  mechanism cannot carry this key. fd 2 is inherited and always works. Include a
  `process=` tag; the helpers share one stderr and the lines are otherwise identical.

## Two pre-existing bugs found on the way

Neither is caused by any of the above; both block launching a freshly built
`ladybird-wayland` and are filed as separate tasks.

1. **The wayland deb ships no monospace font.** `share/Lagom/fonts/` has only `NotoEmoji` and
   `SerenitySans-Regular`, so `FontPlugin`'s constructor fails
   `VERIFY(m_default_fixed_width_font)` (`FontPlugin.cpp:53`) and **WebContent aborts on every
   launch**. This is why a running `/var/jb/usr/bin/ladybird` has Compositor, ImageDecoder and
   RequestServer children but no WebContent child. The `.app` flavor ships the full Liberation
   set (14 files) and works. Copying those in makes headless screenshots work.
   Related: `--force-fontconfig` is broken on iOS, because patch 0008 only installs the
   CoreText `SkFontMgr` when the provider is *not* FontConfig and its `#elif AK_OS_IOS` branch
   is a comment, so `VERIFY(font_manager)` fires at `TypefaceSkia.cpp:105`.
2. **A fresh build lacks the `ladybird-tls` rpath.** The committed build script defaults to
   `0.1.0+wl1` and does not do the rpath prepend that published `wl2` has, so `libcrypto`
   resolves to base OpenSSL 3.2.1 and `_EVP_PKEY_sign_message_init` is missing at launch.
   Workaround for testing only:
   `DYLD_LIBRARY_PATH=/var/jb/usr/lib/ladybird-tls:/var/jb/usr/lib:/var/jb/lib/angle`.
   Do not put that on a global launcher path; the whole point of `ladybird-tls` is that the
   private OpenSSL 3.5 shadows nothing.
