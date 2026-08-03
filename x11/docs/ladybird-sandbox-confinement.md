# Confining Ladybird helpers with iOS's precompiled sandbox profiles

**Conclusion for `com.apple.WebKit.WebContent`: impossible, and not for a fixable reason.
Do not retry that profile.** The `container` profile is a separate, still-open question —
see [Reopening `container`](#reopening-container) below.

`com.apple.WebKit.WebContent` denies `poll()`, `select()` **and** `kevent()`. Ladybird's
`Core::EventLoop` waits on file descriptors, so a confined helper cannot wait for events at
all. There is no call site, no patch, and no alternative event-loop backend that gets around
it: the profile forbids descriptor waiting outright, because Apple's real WebContent waits on
Mach messages instead.

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
| `bootstrap_look_up` | OK | **DENIED** (0x44c) | OK (measured 2026-08-02) |
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

## Reopening `container`

The original write-up dismissed the other available profile in one line: `container` "leaves
the network reachable and so removes nothing worth having from a renderer." That weighs the
wrong axis, and the matrix above contradicts it. Under `container`, `poll`, `select`,
`kevent`, `pipe()` and both socket families are **permitted** — every primitive that made
`com.apple.WebKit.WebContent` unusable — while the `/var/jb/tmp` write is **denied**.

Network egress is not what a renderer compromise is worth on this device. Write access under
`/var/jb` is: overwrite a dylib in `/var/jb/usr/lib` or a binary in `/var/jb/usr/bin` and you
have persistent code execution across the entire desktop stack, not just the browser. And
WebContent does not do its own networking — RequestServer does, in a separate process that
would stay unconfined either way. So "leaves the network reachable" costs little, and "denies
writes" may remove the single most valuable thing an attacker gets.

### Measured, 2026-08-02

`probes-ladybird-sandbox/sbprobe5.c`, on iPad7,12 (A10, iPadOS 17.6.1, Dopamine rootless), run
as both `root` and `mobile`, in `none` and `confined` modes off one binary. **`container` is a
usable renderer jail. Every primitive survives; every write outside the container is denied.**

| capability | root: none → confined | mobile: none → confined |
| --- | --- | --- |
| `poll()` / `select()` / `kevent()` on pre-made fds | OK → **OK** | OK → **OK** |
| `pipe()` *after* confinement | OK → **OK** | OK → **OK** |
| operate on a pre-held mach receive right | OK → **OK** | OK → **OK** |
| `bootstrap_look_up` | OK → **OK** | OK → **OK** |
| read Lagom fonts, `/var/jb` dylib, system font, `dyld`, `cert.pem` | OK → **OK** | OK → **OK** |
| write `/var/jb/usr/lib` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/usr/bin` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/usr/share/Lagom` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/etc` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/tmp` | OK → **DENIED** | OK → **DENIED** |
| write `/tmp` | OK → **DENIED** | OK → **DENIED** |
| write `$HOME` | OK → **DENIED** (`/var/jb/var/root`) | OK → **OK** (`/var/mobile`) |
| `socket(AF_UNIX)` / `socket(AF_INET)` | OK → OK | OK → OK |

Two things are better than expected. `bootstrap_look_up` **works** under `container`, so unlike
`com.apple.WebKit.WebContent` there is no ordering constraint at all — a helper can confine
itself early rather than having to wait out the Mach handshake. And the write denial is not
partial: it is everything outside the process's own container, `/var/jb/tmp` and `/tmp`
included. Under `container`, `$HOME` stays writable for `mobile` and not for `root`, which is
the profile behaving exactly as its name suggests: `/var/mobile` *is* mobile's container.

### What this is actually worth — read this before quoting the win

The claim that motivated the re-test ("a renderer compromise can write anywhere under
`/var/jb`, so this is a persistence primitive for the whole desktop stack") is **only true for
a helper running as `root`**, and it overstated the case for the flavor most users run.

`/var/jb/usr/lib`, `/var/jb/usr/bin`, `/var/jb/usr/share/Lagom` and `/var/jb/etc` are all
`root:wheel` `0755`. A `mobile` process cannot write them with or without a sandbox — the
mobile columns above show them denied in the *control* run, with `EACCES` rather than the
`EPERM` the sandbox returns. Plain file permissions were already doing that work. So:

- **`.app` flavor (SpringBoard-launched, runs as `mobile`)** — `container` adds the denial of
  `/var/jb/tmp` and `/tmp`. That is not nothing: both are world-writable `1777` staging dirs
  shared with every other process on the device, so a compromised renderer dropping a file
  there is a real cross-process vector. It does **not** take away `$HOME`, which is correct —
  that is where cookies and cache live, and removing it would break the browser.
- **`ladybird-wayland` under the desktop session** — `iosc` and `ioscd` run as **root** on this
  device, so a helper parented by that session inherits root, and the root columns apply. There
  the win is large: the entire `/var/jb` tree plus `$HOME` become unwritable.

The honest summary is that `container` is worth wiring in for both flavors, that it is close to
free (nothing a renderer needs was denied), and that its value is concentrated in the root-run
case rather than being the universal persistence fix the original framing implied.

Scope stays **WebContent and ImageDecoder.** RequestServer needs the network by definition —
`container` permits `socket()`, so it *could* be confined, but the write denial is the whole
point and RequestServer is the one helper that genuinely writes (HTTP disk cache, alt-svc).
Compositor's IOSurface path is still unmeasured under this profile.

Not yet done: wiring `sandbox_init_with_parameters("container", 0x1, NULL, &err)` into the
helper startup path behind a `LADYBIRD_IOS_SANDBOX` env guard, and re-running the device A/B
that validated the entitlement trim (byte-identical screenshot against an unconfined control).
The probe says the primitives are there; it does not prove a real helper renders a page.

## What to do instead: entitlement minimisation

The fallback named in `ios-platform-features.md` is uid separation, `setrlimit`, and
entitlement minimisation. Entitlements are the cheapest real win, and unlike the sandbox they
are independent of it: writes were denied under confinement even as root with the read-write
path exception present, so trimming entitlements is a real restriction rather than cosmetic.

**Done (2026-07-29):** `task_for_pid-allow` and `com.apple.system-task-ports` are removed from
`x11/packages/ladybird-app/entitlements/ladybird-helper.entitlements`. Those grant the ability
to obtain another process's task port, i.e. read and write its memory, which is a
privilege-escalation primitive and the worst thing to hand a process that parses untrusted web
content. Nothing needed them: a helper sends its *own* task port during the Mach bootstrap
handshake (no entitlement required), and the iOS path discards the received port
(`(void)request.task_port`; `set_process_mach_port` is macOS-only).

Device-validated without a rebuild, because entitlements are a signing-time property: the
shipped helpers were re-signed with the trimmed set, run from an isolated prefix, and loaded a
page. Result was a byte-identical 52742-byte screenshot to the untrimmed control, with
MessageChannel, MessagePort transfer, image decode via RequestServer and canvas all reporting
OK on the rendered page. WebContent, RequestServer, ImageDecoder and Compositor all spawn and
work without those two grants.

**Still to do, blocked on splitting the file per helper.** One entitlement file is shared by
both flavors' signing paths (`packages/ladybird-wayland/build.sh` and
`packages/ladybird-app/resign-ladybird-app-deb.sh`), and the `.app` flavor signs **Compositor**
with it too, so nothing GPU- or write-related can be narrowed until there are per-helper files:

- `com.apple.security.exception.files.absolute-path.read-write` over all of `/var/jb/`.
  WebContent has no runtime write requirement at all (the Skia cache directory the macOS
  profile grants read-write has no writer anywhere in the tree). RequestServer is the only
  helper that genuinely writes, for the HTTP disk cache and alt-svc cache.

  **But do not expect trimming this one to restrict anything by itself.** The distinction the
  paragraph above draws — entitlements as a real restriction rather than a cosmetic one —
  holds for `task_for_pid-allow`, which AMFI checks directly and independently of any sandbox.
  It does not hold for `com.apple.security.exception.*`, which are App Sandbox *exception*
  keys: they widen a profile that is already applied, and no profile is applied here. Removing
  this key from an unconfined helper changes nothing about what it can write; the helper keeps
  everything the `mobile` user can reach. It is worth splitting per helper so the file stops
  describing a boundary that does not exist, and so it is already correct if `container` (see
  above) turns out to be usable — but on its own it is documentation, not mitigation.
- The AGX/IOGPU IOKit classes, which only Compositor needs. Removing them from the shared file
  today would break the `.app` flavor's WebGL, since that flavor signs Compositor with this
  file.

Caveats on the validation above: headless mode uses in-process raster (patch 0009), so
Compositor was proven to *launch* without task ports but its paint path was not exercised, and
the test page uses no Web Workers so WebWorker was not exercised.

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
