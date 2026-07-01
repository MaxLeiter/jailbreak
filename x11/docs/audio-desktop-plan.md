# Desktop audio integration plan

How GNOME/GTK apps and gnome-shell's volume UI (gvc) get sound on the iPad,
built on the audio stack that is already verified audible on-device
(see `audio-plan.md` for that stack's history). This document is the
integration layer: what sits between libpulse clients and `xios-audiod`.

## The pipeline

```
gvc (gnome-shell volume UI)      GTK/GNOME apps, paplay, gst pulsesink...
        \                              /
         libpulse + libpulse-mainloop-glib     (libpulse0, PA 17 client libs)
                      |
             PA native protocol, unix:/var/jb/tmp/pulse/native
                      |
              pulseaudio daemon                (pulseaudio deb, this track)
        mixing, per-stream volume, resample
                      |
              module-xios-sink                 (in the pulseaudio deb)
        timer-clocked, 48 kHz stereo f32le, XIOA framing
                      |
             unix:/var/jb/tmp/xios-audio.sock
                      |
               xios-audiod                     (xios-audio-server deb, verified)
        AVAudioSession + CoreAudio RemoteIO
                      |
                iPad speakers / current route
```

`xios-audiod` keeps sole ownership of the device and the entitlement story
(fakesigned, `audio.xml`). PulseAudio is a plain fakesigned CLI process with
no special entitlements; to it, the iPad is just a Unix socket.

## Assessment answers

### 1. Does gvc need a real PulseAudio server? Yes.

gvc is a full native-protocol client: `pa_context_connect`, sink/source
introspection, subscription events, `pa_context_set_sink_volume_by_index`,
default-sink queries. That is the server side of the native protocol plus a
live sink object with volume; a `pa_simple`-level shim cannot fake it, and
extending the shim to a full libpulse would mean reimplementing PulseAudio.
Meanwhile apps are the same story: anything GTK-adjacent that plays sound
does it through libpulse, libcanberra, or GStreamer's pulsesink, all of which
speak the native protocol.

So the middle of the pipeline is the real PulseAudio 17 daemon, built from
the same source tree as the already-shipped client libs, with one custom
sink module as its hardware output. The alternative (per-app patches onto
SDL/libao/CoreAudio backends) does not reach gvc at all.

### 2. libpulse0 vs the libpulse-simple-xios0 shim: resolved, real PA wins.

Already decided and encoded in packaging (verified in the built deb):
`libpulse0` Provides `libpulse-simple0`, Conflicts/Replaces
`libpulse-simple-xios0`; `libpulse-dev` the same for the -dev shim. apt
evicts the shim on install. The shim existed only because Procursus had no
PulseAudio; the real `libpulse-simple.0.dylib` serves the same
`pa_simple_write()` API, now through the daemon like everything else.

One real leftover from the shim era, now fixed: `xios-audio-session.sh`
(profile.d, shipped in xios-audio-server) exports
`PULSE_SERVER=unix:/var/jb/tmp/xios-audio.sock`. That was correct for the
shim, which spoke the XIOA protocol, but real libpulse clients would send a
native-protocol handshake at a socket expecting XIOA magic and fail. The
pulseaudio deb ships `/var/jb/etc/profile.d/xios-pulse.sh`, which sources
after `xios-audio.sh` (alphabetical) and overrides `PULSE_SERVER` to
`unix:/var/jb/tmp/pulse/native`. `client.conf` carries the same default for
processes that never source profile.d.

### 3. The missing piece was a PA server with a CoreAudio-daemon sink. Built.

`module-xios-sink` (`linux-build/audio/module-xios-sink.c`), compiled inside
the PA tree by the extended recipe. Design points:

- **Timer-clocked, not write-clocked.** `xios-audiod` reads the socket as
  fast as clients write and mixes through a drop-oldest 4 s ring; the socket
  gives no backpressure. A `module-pipe-sink` style POLLOUT-clocked loop
  would free-run and shred the ring. The sink is modeled on
  `module-null-sink`: `pa_rtclock` drives `pa_sink_render()` at exactly real
  time in 25 ms blocks, and the socket is a dumb byte pipe.
- **Native format end to end.** Fixed 48 kHz stereo f32le, which is the
  daemon's mix format; PA renders float natively, so nothing converts twice.
  PA soft volume and mute apply during render, which is what makes the gvc
  slider actually attenuate PCM.
- **Resilient.** Connects lazily, reconnects every 2 s if `xios-audiod` is
  down or restarts, renders to /dev/null in between (the sink object, and
  with it gvc's UI, stays alive). Suspend/resume resets the render clock so
  no stale burst plays after idle.
- **iOS module set.** Upstream's darwin modules are macOS-only
  (module-coreaudio-* speak the CoreAudio HAL, `AudioHardware.h`, absent in
  the iOS SDK). `recipes/pulseaudio-ios-fixes.sh` swaps that block for
  module-xios-sink.

Known, accepted v1 limits: pa_rtclock vs HAL clock drift is absorbed by the
daemon's 4 s ring rather than corrected (worst case an occasional dropped or
repeated block after hours of playback); the trivial resampler serves
44.1 kHz streams (speex/soxr are compiled out; revisit if music playback
warrants it); no capture path yet (mic is a separate feature with a
permission story, per audio-plan.md A3).

## Packaging

Same recipe builds everything from one tree (`recipes/pulseaudio.mk`,
`-Ddaemon=true`), Debian-shaped split, version 17.0-1:

| deb | contents |
| --- | --- |
| libpulse0 | client dylibs + private libpulsecommon (content unchanged) |
| libpulse-dev | headers, .pc, unversioned symlinks |
| pulseaudio | daemon, libpulsecore, modules incl. module-xios-sink, etc/pulse configs, profile.d/xios-pulse.sh. Depends: xios-audio-server, libltdl7 |
| pulseaudio-utils | pactl/pacat/paplay/... |

The daemon needs ltdl, so the recipe grew a dependency on the Procursus
libtool subproject (libltdl7 deb). Config choices in `audio/pulse-config/`:
anonymous auth on a fixed socket (no cookie plumbing across users),
`enable-shm = no` until POSIX shm between differently signed processes is
validated on-device (socket copies are cheap at stereo 48 kHz),
no realtime scheduling, `exit-idle-time = -1` (the session owns the
lifecycle), `module-suspend-on-idle` so the render clock stops on battery
when nothing plays, `module-always-sink` as a null fallback so gvc never
faces an empty sink list.

Driver: `linux-build/build-audio-server.sh` on procursus-vol-shell (wipes the
client-only pulseaudio build tree when present; the recipe's `.build_complete`
guard would otherwise skip the daemon reconfigure). It also runs
`libtool-package`: libltdl7 must ship as a deb, not just get staged.

### Cross-build gotchas (why the recipe/fixes script look the way they do)

- **meson hard-errors a daemon build with zero echo cancellers.** speex and
  webrtc are disabled, so `-Dadrian-aec=true` (bundled, dependency-free C).
- **PA's NEON simd files are armv7-only inline asm** (q0/d4 register names).
  Upstream aarch64 escapes them because gcc/clang reject `-mfpu=neon` and the
  meson simd check fails; Apple clang plus our
  `-Wno-unused-command-line-argument` wrapper accept it silently, so
  `mix_neon.c` explodes with "unknown register name 'q0'". The fixes script
  drops the neon simd variant.
- **The shared sysroot has a stub `linux/input.h`** (staged by the mutter
  track's inert libei/dma-buf shim), so `cc.has_header('linux/input.h')`
  wrongly enables module-mmkbd-evdev, which then fails on the missing struct
  definitions. The fixes script kills that gate.
- **`lib/pulseaudio/` is on nobody's run path.** meson emits only
  build-tree-relative `@loader_path` rpaths plus `/var/jb/usr/lib`, so the
  daemon dies on `@rpath/libpulsecore` and every libpulse client dies on
  `@rpath/libpulsecommon` (this was a LATENT bug in the client-only libpulse0
  17.0 deb; the static closure check matched dylibs by name, not by rpath
  walk). Fix: `install_name_tool -add_rpath /var/jb/usr/lib/pulseaudio` on
  libpulse.0/-simple.0/-mainloop-glib.0 and the daemon binary at package
  time. dyld consults the loading dylib's own LC_RPATHs, so fixing libpulse.0
  fixes all of its consumers transitively. 17.0-1 supersedes the 17.0 debs
  (dpkg orders 17.0-1 above 17.0).
- meson names PA modules `module-*.dylib` here and upstream sets
  `PA_SOEXT ".dylib"` on darwin, so the loader and the files agree; no rename
  needed.

## Session integration (gnome-session / launcher owner)

1. Install `pulseaudio` (pulls xios-audio-server, libltdl7). Optionally
   `pulseaudio-utils` for debugging.
2. Launchers source profile.d as they already do; the only new call is
   `xios_pulse_start` (idempotent, also starts xios-audiod if needed) before
   gnome-session/gnome-shell comes up. No gsd changes: gvc in gnome-shell
   and gsd's media-keys both just find `PULSE_SERVER`.
3. Expected gvc behavior: one sink named `xios`, description
   "iPad speakers (xios-audiod)"; volume slider and mute work (PA soft
   volume); output device switching UI stays single-entry (iOS owns real
   route changes, invisible to PA, which is correct here).

## On-device validation sequence

```
apt install pulseaudio pulseaudio-utils
. /var/jb/etc/profile.d/xios-audio.sh && . /var/jb/etc/profile.d/xios-pulse.sh
xios_pulse_start
pactl info                      # Server Name: pulseaudio, Default Sink: xios
pactl list sinks short          # xios ... FLOAT32LE 2ch 48000Hz
paplay /var/jb/usr/share/sounds/... .wav   # audible end to end
pactl set-sink-volume xios 50%  # audibly quieter (proves the gvc path)
```

Then the desktop: launch the GNOME session, open the shell volume slider
(gvc), confirm it tracks `pactl get-sink-volume xios`.

## Follow-on work (not this track's blockers)

- **libcanberra + gsound (PA backend)** for GTK event sounds, and
  **gst-plugins-good pulsesink** for GNOME media apps (gnome-text-editor and
  friends do not play audio; Videos/Music would come through GStreamer).
- soxr resampler if 44.1 kHz music quality matters.
- enable-shm after an on-device shm_open test between fakesigned processes.
- Drift correction (rate-adjust the sink from xios-audiod ring depth
  feedback) only if long-session drift is audible in practice.
- Capture (mic) per audio-plan.md A3.
