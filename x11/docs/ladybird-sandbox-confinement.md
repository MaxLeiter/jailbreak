# Confining Ladybird helpers with iOS's precompiled sandbox profiles

**Conclusion: impossible under both available profiles. Do not retry this.**

`com.apple.WebKit.WebContent` fails at the event loop (below). `container` was re-tested on
2026-08-02 and fails too, at the paint backing store for WebContent and at Mach port descriptor
passing for ImageDecoder — see [Measured, 2026-08-02](#measured-2026-08-02--and-the-answer-is-still-no).
That section also records a synthetic probe that briefly said `container` worked, and why it was
wrong; read it before trusting any future probe result on this.

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
| `bootstrap_look_up` (Apple *system* service) | OK | **DENIED** (0x44c) | OK (2026-08-02) |
| `bootstrap_look_up` (app-registered service) | OK | **DENIED** | **DENIED** (2026-08-02) |
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

## Reopening `container` — re-tested, and closed

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

### Measured, 2026-08-02 — and the answer is still no

**Conclusion: `container` cannot host a Ladybird helper either. Both available profiles are
now closed, for different reasons.** The synthetic probe said yes; the real helpers said no.
That gap is the whole lesson of this section, so read the order it happened in.

`probes-ladybird-sandbox/sbprobe5.c`, on iPad7,12 (A10, iPadOS 17.6.1, Dopamine rootless), run
as both `root` and `mobile`, in `none` and `confined` modes off one binary. On a *synthetic*
process, every primitive survived and every write outside the container was denied:

| capability | root: none → confined | mobile: none → confined |
| --- | --- | --- |
| `poll()` / `select()` / `kevent()` on pre-made fds | OK → **OK** | OK → **OK** |
| `pipe()` *after* confinement | OK → **OK** | OK → **OK** |
| operate on a pre-held mach receive right | OK → **OK** | OK → **OK** |
| `bootstrap_look_up` (Apple *system* service — see below, this row misled) | OK → **OK** | OK → **OK** |
| read Lagom fonts, `/var/jb` dylib, system font, `dyld`, `cert.pem` | OK → **OK** | OK → **OK** |
| write `/var/jb/usr/lib` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/usr/bin` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/usr/share/Lagom` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/etc` | OK → **DENIED** | denied by file perms either way |
| write `/var/jb/tmp` | OK → **DENIED** | OK → **DENIED** |
| write `/tmp` | OK → **DENIED** | OK → **DENIED** |
| write `$HOME` | OK → **DENIED** (`/var/jb/var/root`) | OK → **OK** (`/var/mobile`) |
| `socket(AF_UNIX)` / `socket(AF_INET)` | OK → OK | OK → OK |

The write-denial rows are real and still stand. The `bootstrap_look_up` row **was a false
pass**, and it is the reason this section briefly claimed `container` was usable. The probe
looked up `com.apple.system.notification_center` — an Apple *system* service. Ladybird looks up
`org.ladybird.Ladybird.helper.<pid>`, a custom service its parent registered. `container`
permits the first and denies the second. One line of a synthetic probe, one wrong conclusion.

This is the same trap named at the top of this document, in a new costume: **success from
`sandbox_init_with_parameters` says nothing about whether the process can still function**, and
neither does a probe that exercises primitives in isolation rather than the IPC patterns the
real program uses. If this gets revisited again, test against a real helper first.

### What the real helpers do (sbinject, no rebuild required)

`probes-ladybird-sandbox/sbinject.c` confines actual helpers by interposing `bootstrap_look_up`
via `DYLD_INSERT_LIBRARIES`, so confinement lands exactly where a source patch would put it —
after the handshake — with no engine rebuild. Raw output in
`sbinject-results-2026-08-02.txt`. Four headless screenshot runs of the same local page:

| run | confined | result |
| --- | --- | --- |
| control | nothing | renders |
| `WHEN=constructor` | WebContent + ImageDecoder | `Unable to look up service org.ladybird.Ladybird.helper.N in bootstrap` → `Runtime error: Permission denied`. **Confirms the ordering constraint the probe missed.** |
| after-bootstrap | WebContent | `VERIFICATION FAILED: !buffer_or_error.is_error()` at `Services/WebContent/PageClient.cpp:176`, then `Compositor/ConnectionFromClient.cpp:68` and `LibIPC/Connection.h:74`. **No screenshot.** |
| after-bootstrap | ImageDecoder | `VERIFICATION FAILED: MACH_PORT_VALID(descriptor.name)` at `LibIPC/TransportMachPort.cpp:75`. Screenshot renders **without the image**. |

So confinement fails at a different layer for each helper, and neither is a fixable ordering
problem:

- **WebContent** cannot allocate its paint backing store under `container`. That buffer is
  created per page and again on every resize, so it cannot be pre-allocated before confinement
  the way the pre-made fds were — the same shape as the `pipe()`-per-transport problem, but
  without a shared-instance trick available.
- **ImageDecoder** cannot pass Mach port descriptors after confinement, which is how it returns
  decoded bitmaps. It survives, and the page still renders — just with nothing decoded. A
  renderer that silently drops every image is not a working renderer.

Caveat on method, since it cuts against a claim made elsewhere in this document: **the headless
screenshots were not byte-stable across unconfined control runs here** (two controls of the
same page hashed differently). Byte-identical comparison was usable for the entitlement trim;
it was not usable as the pass/fail signal for these runs. The failures above are read from
`VERIFICATION FAILED` lines and from a missing or visibly wrong screenshot, not from hashes.

Under `container`, `$HOME` stays writable for `mobile` and not for `root`, which is the profile
behaving exactly as its name suggests: `/var/mobile` *is* mobile's container.

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

This correction outlives the confinement idea, so keep it even though `container` failed: the
threat model for the `.app` flavor is smaller than "renderer compromise owns the desktop
stack," because file permissions already stop a `mobile` process from writing the tree. The
root-run `ladybird-wayland` case is the one where a renderer compromise really does get the
whole prefix — and since confinement is unavailable, **running those helpers as `mobile`
instead of `root` is now the cheapest real mitigation left.** That is uid separation, which
`ios-platform-features.md` named as the fallback and which nothing here has ruled out.

Do not reopen `container` without new information. The two failures above are architectural,
not ordering or entitlement problems: a renderer that cannot allocate a backing store and an
image decoder that cannot return a bitmap are not configuration issues. If someone does revisit
it, the cheap first step is `sbinject.c` against a real helper — one command, no rebuild — not
another synthetic probe.

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
2. **SHIPPED BROKEN: `ladybird-wayland` 0.1.0+wl4 lacks the `ladybird-tls` rpath.**
   Confirmed 2026-08-02 against the published deb's installed payload: `WebContent` and
   `ladybird` carry only `@executable_path/../lib`, so `libcrypto` resolves to the base
   3.2.1 and every helper dies at dyld on `_EVP_PKEY_sign_message_init`. **The wayland
   browser cannot start a renderer for anyone who installs it.** It fails closed, so it is
   not a weak-crypto exposure -- it is a dead browser.

   Not a build-script bug: `prepend_tls_rpath` is correct and fails closed per binary, and
   it landed in 879cfd7c *before* the wl4 bump in 1a5655b6. The deb simply reached users
   without anything re-checking the property on the artifact. `bin/lib/check-ladybird-tls-rpath.py`
   is now a publish gate for exactly that, and flags these binaries.

   The `.app` flavor is unaffected: it links `@executable_path/lib/libcrypto.3.dylib` by
   path and bundles OpenSSL 3.5.3 inside the bundle, so no rpath search happens.

   Remedy is a rebuild + republish as `wl5` -- the packaging script needs no change. Do not
   hand-patch the deb. Testing-only workaround meanwhile:
   `DYLD_LIBRARY_PATH=/var/jb/usr/lib/ladybird-tls:/var/jb/usr/lib:/var/jb/lib/angle`;
   do not put that on a global launcher path, since the whole point of ladybird-tls is that
   the private OpenSSL 3.5 shadows nothing.

   (Original note, now superseded by the above.) **A fresh build lacks the `ladybird-tls` rpath.** The committed build script defaults to
   `0.1.0+wl1` and does not do the rpath prepend that published `wl2` has, so `libcrypto`
   resolves to base OpenSSL 3.2.1 and `_EVP_PKEY_sign_message_init` is missing at launch.
   Workaround for testing only:
   `DYLD_LIBRARY_PATH=/var/jb/usr/lib/ladybird-tls:/var/jb/usr/lib:/var/jb/lib/angle`.
   Do not put that on a global launcher path; the whole point of `ladybird-tls` is that the
   private OpenSSL 3.5 shadows nothing.
