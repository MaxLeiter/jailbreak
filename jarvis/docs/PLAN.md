# Jarvis — Plan & Status

Living roadmap. Update the **Status** and **Backlog** as work lands. Stable
orientation is in [`../AGENTS.md`](../AGENTS.md).

_Last updated: 2026-07-03._

## Vision

An always-available, on-device intelligence that knows your device and can act on
it — read state, drive apps, compile context about you — behind a permission
model you can see and steer. Cloud model for reasoning (Claude via AI Gateway),
with room for a local model to handle the cheap always-on heartbeat later.

Two faces, one brain:
- **Web console** (built) — the control plane: chat, live telemetry, knowledge,
  policy, audit, and the human-in-the-loop approval surface.
- **Native surface** (later) — a thin client of the same daemon HTTP API for
  on-the-go quick-ask + permission push notifications. Do **not** fork the brain.

## Milestones

- **M0 — Harness** ✅ Agent loop, permission broker, tiered routing, compaction,
  subagents, durable sqlite store + audit. Typechecks, live-verified.
- **M1 — Gateway auth** ✅ CLI-minted AI Gateway key, harness + Claude Code wired,
  end-to-end verified through the gateway.
- **M2 — Web console** ✅ `Bun.serve`, SSE, chat, live policy, audit, browser
  approvals. Phosphor-instrument UI. Browser-verified.
- **M3 — On-device daemon** ✅ Runs natively on the iPad, LAN-reachable, full loop
  through the gateway. One-command `deploy.sh` + `jarvisctl.sh`.
- **M4 — Real device tools** 🚧 FFI/AX-back the sense+act surface. Battery,
  screenshot, speech output, and microphone recording done.
- **M5 — Permission surface on-device** ⏳ Route `PolicyBroker.ask` to a real
  device prompt / push notification (not just the browser).
- **M6 — Sensing + memory** ⏳ The layer that compiles durable context about the
  user (notifications, calendar, usage, location) into pinned state + a store.
- **M7 — Native chat client** ⏳ Thin client over the daemon API.

## Status — what's live and verified

- Harness, console, gateway auth, and durable store: all built, typecheck clean.
- Web console UX now renders tool calls as compact live-updating cards, treats
  `speak` output like a transcript message, renders screenshot/audio
  attachments through the daemon, exposes a live AI Gateway language-model
  selector, shows the full persistent session transcript, presents policy
  controls in human-readable access groups, and includes an explicit Wake toggle
  for the Jarvis-owned voice loop. The sidebar is collapsible and now defaults
  to an activity feed backed by the audited action stream.
- **Native Settings pane:** `com.max.jarvisprefs` adds a Jarvis pane under iOS
  Settings via PreferenceLoader. It controls the master enabled switch, quiet
  hours, and coarse policy overrides for speech replies, microphone/wake, and
  shell commands. The launchd job now runs `jarvis-supervisor.sh`, which keeps
  only a small supervisor alive while Jarvis is disabled or inside quiet hours.
  Device-verified: a temporary quiet-hours window stopped the Bun daemon while
  leaving the supervisor running, and a temporary speech policy override showed
  up in `/state`.
- **Persistent session + memory:** sqlite restores the live session across
  restarts, model compaction keeps the live context bounded, a Maxbot-style
  200-message sliding transcript is exposed through `session_status` /
  `session_scrollback`, and concise markdown memory under
  `/var/jb/var/root/jarvis/memory` is loaded into the prompt. `index.md` is the
  root memory: it is always injected first and should hold only the most
  important standing instructions.
- **Model switching:** `switch_model` validates against the AI Gateway model
  list, asks for approval, updates the live router, and persists the base model
  to `/var/jb/var/root/jarvis/settings.json`. Use only when explicitly requested.
- **On the iPad now:** daemon at `http://MaxsiPad.local:8787`, single instance,
  full agent turn (`list_dir` / `battery` → `anthropic/claude-sonnet-5` → answer)
  runs on-device with permission + audit intact.
- **First FFI tool:** `battery` via IOKit `IOPSCopyPowerSourcesInfo` over
  `bun:ffi` — device-validated real data (25%, charging, AC Power).
- **First native screen tool:** `screenshot` via `JarvisScreenshotBridge`, a
  SpringBoard-side rootless tweak. Jarvis writes a request file, posts a Darwin
  notification with `notify_post`, and the bridge writes a PNG/status file.
  Device-validated through the daemon: permission/audit path intact, returned a
  1620x2160 PNG.
- **Speech output:** `speak` via the same SpringBoard bridge using
  `AVSpeechSynthesizer`; `change_voice` lists installed voices and saves a
  default voice for future speech. Device-validated through the daemon with
  `act.speech` defaulting to `ask`; approval and audit path intact.
- **Microphone recording + Apple transcription:** `listen` records short `.m4a`
  clips through the SpringBoard bridge with `sense.microphone` defaulting to
  `ask`. Recording works and is audited. Apple Speech works from the deployed
  root helper after mirroring mobile Dictation settings into root's preference
  domain; a known speech sample transcribed on-device as "Hello Jarvis
  transcription test." AI Gateway speech-to-text is kept behind
  `JARVIS_STT_GATEWAY_FALLBACK=1` because the current key returns "Unsupported
  gateway protocol version."
- **Wake voice prototype:** `GET/POST /wake` controls an explicit daemon-owned
  wake loop. When enabled, it records short clips, transcribes them with Apple
  Speech, detects "hey jarvis" in the same utterance, and sends the command after
  the wake phrase into the persistent Jarvis session. The console shows the
  wake state/transcripts. Start/stop is audited as `wake_loop`; model-requested
  actions still flow through the normal tool permission path. Device smoke test:
  start with a 1s sample, no speech detected, stop, single daemon instance.
- Environment proven on device: bun 1.4.0, `bun:sqlite` works, gateway + npm
  reachable.

## Backlog (M4 — device tools, safety order)

1. **Input injection** (tap / type) — via `IOHIDEvent` posting.
   ⚠️ **Open question, resolve first:** does a fakesigned/unsandboxed bun process
   have the entitlement to post HID events? Precedent in this repo (Metal needs an
   explicit GPU IOKit entitlement) says this may hit a wall. If so, tap/type needs
   a small *entitled* helper daemon and Jarvis calls it — don't assume bun can do
   it directly. Probe the wall before writing the tool.
2. **Notifications** — read SpringBoard notifications (sense) → feeds M6.
3. **AX control** — read the accessibility tree + post AX actions to native apps
   (the reliable path for first-party app control; visible, not headless).
4. **Wake voice path** — explicit daemon wake loop is live for one-utterance
   commands ("hey jarvis, ..."). Next: prove live speech command quality, then
   add a two-stage interaction ("hey jarvis" -> "yes?" -> command) or move the
   loop into a native helper/app. Do not plan on replacing Siri UI/backend as the
   product path; Siri hooks are research-only until proven safe.
5. **Brightness / volume controls** — research/probe in an isolated helper first.
   Do **not** put experimental `AVSystemController` or other private setting APIs
   in SpringBoard: `JarvisScreenshotBridge` 0.0.3/0.0.4 safe-moded the device via
   `AVSystemController getVolume:forCategory:mode:`. Device is rolled back to the
   known-good 0.0.2 bridge; local source has the private volume path removed.

## Backlog (other tracks)

- **M5:** on-device approval UI — a tweak/notification that surfaces
  `PolicyBroker.ask` and resolves it, so gated actions work without the browser.
- **M6:** memory/knowledge store beyond pinned state + rolling summary; an indexer
  over the context sources above.
- **Harness niceties:** token-level streaming (currently step-level events);
  interrupt/cancel a running turn from the console; per-tool budgets.
- **Tiered local model** for the heartbeat (escalate to Claude for real work).

## Open questions

- HID-injection entitlement wall (above) — blocks M4.2.
- Device settings control path — public `UIScreen.brightness` is plausible, but
  system volume control needs a safer route. The private `AVSystemController`
  selector/signature guessed in SpringBoard crashed SpringBoard. Any future work
  must run in an isolated helper/probe before becoming a Jarvis tool.
- Screenshot direct-from-Bun was probed and did **not** work: `SSMainScreenSnapshotter`
  throws from the CLI process, `UICreateScreenImage` returns NULL even with
  QuartzCore capture entitlements, and `CARenderServerRenderDisplay` renders an
  empty buffer. Keep screen capture in the SpringBoard bridge unless a better
  native context appears.
- Transcription provider choice:
  - Apple Speech is the working primary path. The helper runs as root, so deploy
    must keep root's Dictation preferences mirrored from mobile or the recognizer
    fails with "Siri and Dictation are disabled."
  - Vercel AI Gateway speech-to-text is implemented as an opt-in fallback
    (`JARVIS_STT_GATEWAY_FALLBACK=1`), but the current gateway key returns
    "Unsupported gateway protocol version" for the transcription endpoint.
- Where the on-device approval prompt should live (tweak vs. local notification
  vs. the native client) — informs M5 vs M7 ordering.

## Guardrails for contributors

Single-owner on the device; additive by default; no unrequested judgment calls;
verify on the real iPad. See [`../AGENTS.md`](../AGENTS.md#golden-rules).
