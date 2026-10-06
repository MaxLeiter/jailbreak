# Xios v2: several desktops at once, launcher-first

Status: approved 2026-10-06 ("just ship it"); open questions resolved with the proposed defaults, see Decisions.

Goals, in Max's words: run several sessions at once, be much more robust, launcher-first UI,
and redesign the socket protocol if that is a real improvement.

This doc is built on three read-only investigations of the current code and the iPad. Their
findings are summarized where they drive a decision; file:line evidence lives in the
investigation notes linked at the end.

## What we found

**The wire is mostly good.** Every channel already uses one 32-byte `xios_msg` envelope
(`apps/shared/XiosProtocol.h`), the IOSurface handoff over a Mach port is cheap and proven, and
stream-v2 buffer ownership plus the XPC fence broker already work for any number of sessions.
There is only one compositor-side implementation of each server: iosc and mutter link the same
`libxios_glue`, and KWin runs nested inside iosc, so it never talks to the app at all.

**What actually blocks several sessions and causes the flaky behavior:**

1. **Discovery by polling a shared, non-atomic file.** The app re-reads `/var/jb/tmp/xios.json`
   every 30 display ticks. Whichever compositor started last owns that file, which is why the
   app grew a "pin" concept and then a dead-pin bug.
2. **Version skew is silent.** `XIOS_PROTOCOL_VERSION` has been 1 through several incompatible
   changes. On 2026-08-02 an older iosc accepted and immediately dropped the app; the app sat at
   "holding frame / input not connected" while the desktop looked alive. The only evidence was
   in `iosc.log`.
3. **The app assumes one session.** The input, clipboard and SysInt clients keep their
   connection in C statics, and `XScreen.swift` (5.3k lines) has one connection, one config,
   one of everything. App launches always go to the global session.
4. **Scripts kill each other's sessions.** A non-slot KDE start kills every iosc, kwin and
   plasmashell on the device (`run-kde-plasma.sh:240-251`), slots included. GNOME slots are not
   recorded, so stopping one leaks gnome-shell, and a global switch kills it.
5. **Singleton helpers.** `xios-sysintd` and `xios-a11yd` listen on fixed global paths, so a
   second session steals or loses them. Two iosc instances overwrite one status sidecar.
6. **Nothing pauses.** A session nobody is looking at keeps rendering at 60 Hz.
7. **Jetsam is inverted.** Every desktop process runs in jetsam band 180, above the foreground
   Xios app. Under pressure iOS kills Xios before any desktop. With two desktops that gets worse.
8. **App bugs found on the way.** Per-frame texture creation plus a status-file write and two
   JSON reads on the main thread (iosc rotates three surfaces, so the "texture changed" path runs
   almost every frame). Rotation goes through the "compositor lost" path and shows up to ~1.5 s
   of black. File reads on the touch path. A long-press menu that eats right-click on iosc.

**Memory, measured on the iPad:** a KDE session is about 600-650 MB (plasmashell alone 333 MB,
peak 433), an iosc-only desktop about 190 MB, and each 2880x2160 output holds 71 MB of
IOSurfaces that cannot be compressed. GNOME has never been measured. The device already runs
with ~1.25 GB in the compressor. Two desktops fit; three heavy ones will not.

## The design

### 1. Every desktop is a slot

The special global namespace goes away. The default session is just the slot named `main`.
Each slot gets one directory:

```
/var/jb/tmp/xios/<slot>/
  session.json          registry entry (written atomically by ioscd)
  ddx.sock input.sock clipboard.sock wm.sock sysint.sock a11y.sock
  wayland-0             (or the KDE runtime under it)
  run/                  XDG_RUNTIME_DIR, session bus, logs
```

Old global paths (`xios.json`, `wayland-0`, `iosc-ddx.sock`) stay as symlinks to the presented
slot for one release, for scripts and CLI tools, then go.

Per slot: compositor, session bus, sysintd, hwbridged, sensord, a11yd, AT-SPI bus. Shared:
PulseAudio, audiod, mediad, ioscd, the Metal broker. KDE and GNOME can run together with no
config collision (GNOME's config is already per run). Two KDE slots would share `~/.config`;
see open questions.

### 2. ioscd becomes the session manager

ioscd already launches sessions and holds the policy. It takes over the registry:

- **Registry** of slots: preset, state (`starting`, `running`, `hidden`, `stopping`, `failed`,
  `killed`), the process groups it forked (no more `ps | grep` heuristics), endpoints, geometry,
  measured footprint, last presented time.
- **Event stream.** A long-lived `SUBSCRIBE` connection gets the full registry, then one NDJSON
  event per change. The app stops polling files. ioscd moves from a serial accept loop to a
  small multi-client loop. A snapshot file stays for SSH tooling.
- **New verbs:** `PRESENT <slot>`, `STOP <slot>`, `LAUNCH <slot> <desktop-id>`, `LIST`.
  `SESSION` keeps working for the CLI.
- **Per-slot locks** instead of the global one, so starting GNOME does not wait for KDE.
- **Budget check** before a start: live footprints plus a per-preset estimate. Over budget, the
  start is refused with "stop <oldest hidden desktop>?" and the user decides. Nothing is killed
  automatically.
- **Jetsam priorities.** ioscd sets the presented slot's processes to band 180 and hidden slots
  below the foreground app, so iOS reclaims a background desktop before it kills Xios. When a
  hidden slot gets killed, it shows as `killed` in the launcher with a restart button. Needs a
  device check that root can set these without an extra entitlement.

### 3. Hidden sessions pause

Only the session on screen is connected to the app. When the app detaches from a compositor
(it already survives that today), the compositor treats "no viewer" as hidden:

- iosc stops sending frame callbacks and stops compositing, so nested KWin and its clients stop
  rendering too. It keeps one output buffer and frees the other two (about 47 MB back per
  hidden iosc). On the next viewer it does one full repaint.
- mutter does the same with its frame clock.
- ioscd corks the hidden slot's PulseAudio streams.

This needs no new message: "no app client attached" is the signal. Switching costs one
handshake plus one repaint, well under a second, and no compositor restarts. SIGSTOP of
long-hidden slots is a possible later step, not part of this plan.

### 4. Protocol v2: a narrow handshake change, not a new wire

Keep the 32-byte envelope, the input code registry, the Mach-port IOSurface handoff, stream-v2
ownership, the fence broker, and the separate ddx / input / clipboard sockets (the split is
load-bearing: the ddx socket never blocks and drops on EAGAIN, input runs on the Wayland loop).

Change:

- **Version 2 HELLO** carries a supported range, capability bits and a build string. The server
  answers with the chosen version and its own build, **or an explicit ERROR record** with a code
  and text, before closing. The launcher shows it plainly: "iosc 0.9.43 is too old for this
  app, needs 0.9.49". No more silent holding frames.
- **Endpoints in the HELLO reply.** The ddx server tells the app the input and clipboard paths
  for the same compositor instance, so the three channels can never belong to different
  compositors or generations.
- **An "ignorable" bit** (`0x8000` in the type) for notifications. Readers skip those by length,
  so adding a notification no longer needs a lock-step co-deploy. Ownership records stay strict.
- Fix the partial-write desync in `XSurface.c:632-640` while moving to one shared C link.

Scope: the ddx and clipboard handshakes. The input/sysint HELLO stays as is, which keeps
PulseAudio's sink module, xios-fhs and sysintd out of the co-deploy. Co-deploys: glue, iosc,
mutter (statically linked, so a Docker rebuild), com.max.xios, iosc-host.

### 5. The app, rewritten

Same bundle id, same `Xios.app/Xios` path (ioscd's picker trust depends on it), same deb.

```
App/          AppDelegate, RootViewController (Launcher <-> Desktop)
Core/         SessionRegistry (subscribes to ioscd), IOSCDClient, models, paths
Session/      SessionConnection, one per slot:
                SurfaceLink   XSurface.c, per-surface texture cache, fences, held-release
                InputLink     handle-based IoscInput (the iosc-host version), touch slots, latches
                ClipboardLink, SysIntLink (handle-based)
              SessionManager: owns connections, present(slot), detach/attach, thumbnails
Present/      PresentView, Renderer, FrameClock (setPacingRange seam), FitTransform, CursorPlane
Input/        TouchRouter, Gestures, Pointer, Keyboard (GC keys, UIKeyInput, OSK policy)
Integration/  SystemIntegration, A11yBridge, CameraBroker (flagged, off)
UI/           Launcher, Desktop chrome, Switcher sheet, App picker, Key pad, Debug
Diagnostics/  StatusWriter (background queue, writes on change only)
```

Rules: UIKit, Metal encoding and the C link handles live on the main actor. Every blocking
call (connect, fence import, ioscd request, clipboard, status writes) runs on its own queue and
comes back through a generation token, so a stale result can never touch a newer connection.
The C clients share one small `xios_link` (connect, HELLO, framed read/write with a write queue)
instead of four copies.

**Must-preserve list.** The investigation produced 64 invariants from the docs, comments and
fix commits (frame acks only from `addPresentedHandler`, release the IOSurface on EOF, 1x1
holding frame, background release, AXIS fixed point with no synthetic momentum, the KDE
one-finger pointer policy, held keys released on every disconnect, and so on). That list becomes
`x11/apps/Xios/INVARIANTS.md` and is the acceptance checklist: every item gets a test, a code
reference, or a device check before v2 ships.

Dropped: the X-server paths, the test card, the pin concept, the second app catalog (ioscd's
`APPS_LIST` only), raw keysym entry, Plasma Nano and raw Mutter in the main list (kept under
Debug), "tap the running desktop to restart".

### 6. The UI

**Launcher (what the app opens to).** A grid of desktop cards. Each card shows a live-ish
thumbnail (captured when you leave that desktop), name, state, size and memory. Tap a card to go
full screen into it. Long-press: Stop, Open app in it, Change size. A **+ New Desktop** card
picks KDE / GNOME / Shell and a screen size, and shows the memory estimate before starting. A
killed or failed desktop shows why and offers Restart. Version-skew errors show on the card.

**Inside a desktop.** Nothing but the desktop. Three-finger tap or a pull down from the top edge
opens the switcher sheet: Home (back to the launcher), the other desktops, Apps, Keyboard pad,
Stop. Long-press is always right-click (the system context menu that ate it on iosc goes away).
The status pill shows briefly on entry, then hides.

**Settings / Debug** sit behind one row in the launcher: render scale, diagnostics, home screen
app sync, the key pad, developer presets.

## Phasing

Each milestone ships on its own and leaves the device working.

| Milestone | What | Components that ship together |
|---|---|---|
| **M0. Coexistence** | Remove the global kill blocks; scope teardown to one slot; record GNOME's process group; per-slot sysintd and a11yd sockets; per-slot iosc status producer; per-slot clipboard/wm sockets verified on the current iosc | xios-session, xios-session-stubs, a11y-tools, iosc (status name only) |
| **M1. New app on today's wire** | The rewrite with launcher, per-session connections, detach of hidden sessions, thumbnails, kqueue watch of the slot directory as a stopgap for push events | com.max.xios, plus M0 |
| **M2. Session manager** | ioscd registry, `SUBSCRIBE` events, `PRESENT` / `STOP` / `LAUNCH <slot>`, per-slot locks, budget, jetsam bands; slot directory layout and legacy symlinks; iosc and mutter pause with no viewer; PulseAudio cork | xios-launcher-tools (ioscd), xios-session, iosc, libmutter, com.max.xios |
| **M3. Handshake v2** | Version range + explicit ERROR + endpoints in HELLO + ignorable bit; shared C link | glue, iosc, libmutter, com.max.xios, iosc-host |

M0 and M1 alone deliver "KDE and GNOME running together, switch between them from a launcher".
M2 makes it cheap and safe on memory. M3 makes it hard to break.

**Testing.** Each milestone is device-tested before staging: start KDE then GNOME, switch both
ways ten times, launch an app into the hidden one, rotate, background and foreground, kill one
desktop out of band, plus the touch / keyboard / trackpad matrix from `xios-app.md`. Memory is
read with `footprint -p`, not RSS. GNOME's footprint gets measured in M0, before the budget
numbers are fixed.

## Decisions (2026-10-06)

1. **One desktop per preset** for now (one KDE, one GNOME, one Shell). Two KDE slots need a
   per-slot config home; revisit later.
2. **Over budget: refuse and ask** which hidden desktop to stop. Never kill automatically.
3. **Volume, dark mode and appearance apply to every desktop.**
4. **Handshake v2 (M3) after M2** has been on the device for a while.

## Investigation notes

Session scratchpad: protocol inventory, concurrency + memory report, app responsibility map
and the 64-item invariant list. They will be folded into `x11/apps/Xios/INVARIANTS.md` and the
relevant handoff docs as the work lands.
