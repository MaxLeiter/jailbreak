# Audio plan

Goal: make X11/GTK apps running under Xios able to play sound on the iPad speakers or
current iOS audio route, without writing a kernel driver.

## Short answer

Do not start with an iOS kernel audio driver. The practical "audio driver" for this stack is
a userspace service or library bridge:

```
Linux-ish desktop app
  -> ALSA / PulseAudio / libao / PortAudio / SDL / GStreamer API
  -> Xios audio bridge
  -> iOS CoreAudio / AudioToolbox RemoteIO
  -> device route selected by iOS
```

X11 itself has no audio transport. Xios owns pixels and input; audio should be a sibling
subsystem launched with the session.

## Status (verified on device)

A1 is live and confirmed on the iPad (iPad7,12, iPadOS 17.6.1, palera1n rootless):

- `xios-audiod` opens `kAudioUnitSubType_RemoteIO` from a fakesigned userspace daemon and
  plays audible PCM out the speaker. No GPU-style entitlement wall like Metal had; the
  `audio.xml` entitlements (`platform-application`, `no-container`, `skip-library-validation`,
  tmp read-write) are sufficient.
- The daemon activates an `AVAudioSession` (category `Playback`, route resolves to `Speaker`)
  before opening RemoteIO, so audio ignores the hardware mute switch and survives screen
  lock. AVAudioSession is reachable from a non-app, fakesigned process.
- The render callback is confirmed to be serviced by the HAL: `SIGUSR1` dumps render stats
  (`render_calls` / `render_frames`) which climb at ~48 kHz whether or not a client is
  connected.
- `xios-audio-play` (the native smoke-test sine client) routes PCM into the daemon over
  `/var/jb/tmp/xios-audio.sock`.
- Lifecycle: `SIGTERM`/`SIGINT` shut the daemon down cleanly and unlink the socket
  (handlers installed via `sigaction` without `SA_RESTART`; lifecycle signals blocked in
  client threads so the main accept loop receives them).

Still untested on device in this early note: a real GTK/XFCE app. The current desktop
audio path is the real PulseAudio daemon described in `audio-desktop-plan.md`.

## What already exists

Procursus already carries useful audio building blocks:

- `libsoundio` with an iOS patch that swaps macOS HAL output for `kAudioUnitSubType_RemoteIO`.
- `libao` with the same RemoteIO adaptation for its macOS/CoreAudio plugin.
- `portaudio`, `libsndfile`, `mpg123`, `ffmpeg`, and SDL2 recipes.
- `build_misc/entitlements/audio.xml`, including microphone TCC allowance for signed audio
  binaries.

That is enough for direct audio smoke tests and apps that can be configured to use these
libraries. It is not enough for arbitrary Linux desktop apps, which usually expect ALSA,
PulseAudio, or PipeWire.

## Recommended path

### A0: prove native output

Build and install `libsoundio` or `libao` from the existing Procursus recipe, then run the
smallest possible sine-wave player on-device.

Acceptance:

- signed binary opens RemoteIO and plays a tone through the iPad route;
- volume follows system volume;
- the app survives suspend/resume or at least fails cleanly;
- no microphone permission is needed for output-only playback.

This validates entitlements, framework linkage, route behavior, and fakesigned process
permissions before we touch desktop compatibility.

### A1: ship a small Xios audio daemon [implemented]

Add `xios-audiod`, a tiny daemon launched beside the X server. It owns the CoreAudio
RemoteIO unit and exposes a Unix-domain socket under `/var/jb/tmp`, for example:

```
/var/jb/tmp/xios-audio.sock
```

Protocol v0 is intentionally boring: PCM frames only, little-endian signed 16-bit or
float32, mixed into 48 kHz stereo RemoteIO output.

Acceptance:

- multiple short-lived clients can connect without wedging audio;
- one active output stream plays with low enough latency for UI sounds/video;
- daemon restart does not require restarting the X server.

### A2: expose Linux app audio [implemented through PulseAudio]

Pick the compatibility surface based on target apps:

- Fastest: configure apps that support `libao`, PortAudio, SDL2, or mpg123 CoreAudio output.
- Implemented now: the real PulseAudio daemon exposes `/var/jb/tmp/pulse/native`;
  `module-xios-sink` forwards mixed PCM to `xios-audiod`, and
  `module-xios-source` exposes `xios-mediad` microphone capture as `xios_mic`.
- Lower-level option: provide a minimal ALSA PCM plugin that forwards to
  `xios-audiod`.
- Defer PipeWire unless GNOME portal/screencast/media-session work becomes the main target;
  it drags in more policy and desktop-session assumptions than basic playback needs.

PulseAudio is the likely sweet spot for GTK/XFCE-era apps: many libraries already know how
to talk to it through `libpulse`, and a Unix socket maps naturally onto the rootless
`/var/jb` world.

### A3: input and session polish

Microphone capture is implemented through `xios-mediad` plus the PulseAudio
`module-xios-source` adapter. Camera capture is a separate desktop-integration
feature: the right desktop surface is PipeWire/portal camera or a GStreamer
source plugin backed by the existing Xios app camera broker/media framing.

Longer-term polish:

- per-app streams and volume;
- route-change handling for headphones/AirPlay/Bluetooth;
- sample-rate negotiation;
- video sync and latency measurement;
- background audio behavior if Xios is backgrounded.

## Why not a kernel driver?

On iOS, the real hardware path is owned by Apple's audio stack. A custom kernel/IOKit audio
driver would be fragile, device/version-specific, harder to sign, and unnecessary for the
goal. We only need to feed PCM into the system route, which CoreAudio/AudioToolbox already
does from userspace.

The only reason to revisit a kernel-level driver would be if fakesigned userspace processes
cannot open RemoteIO reliably even with the existing Procursus audio entitlements. The
existing libsoundio/libao iOS patches make that unlikely enough that the first spike should
be userspace.

## First implementation spike

1. Add a `linux-build/test/audio-sine.c` or `xios-audio-smoke.c` using libsoundio or plain
   AudioToolbox RemoteIO.
2. Add a small build target that signs it with `audio.xml`.
3. Run on-device and record the exact entitlement/framework requirements.
4. If output works, build `xios-audiod` around the same RemoteIO code.
5. Only then choose any additional app-specific audio backends.
