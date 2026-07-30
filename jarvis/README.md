# Jarvis

On-device AI assistant harness. Anthropic-native agent loop, in-process tools,
a permission broker on every tool call. Hand-rolled on `@anthropic-ai/sdk` rather
than driving the opencode binary — because the parts worth owning (permissions,
model routing, prompt-cache breakpoints, compaction policy) are exactly the parts
a generic coding harness won't let you touch. The loop itself is small; the
policy hung off it is the product.

## Shape

```
src/main.ts    thin CLI over the shared daemon
src/daemon.ts  wiring: client + tools + policy + router + store + model catalog
src/harness.ts the engine (generic, tool-agnostic):
                 · Session.run()      the loop — call model, dispatch tools, repeat
                 · dispatch()         permission check → run → tool_result (parallel)
                 · PolicyBroker       capability policy, most-restrictive-wins, audited
                 · TieredRouter       cheap model by default, escalate on deep tool use
                 · maybeCompact()     fold old history into a summary; never split a
                                      tool_use/tool_result pair; pinned state survives
                 · makeSpawner()      subagents (parallel = call spawn N times)
src/server.ts  Bun.serve control plane behind public/console.html (SSE + JSON)
src/tools.ts   in-process tool surface: filesystem, shell, battery, memory,
               screenshot, speech/voice, listen, MCP config
src/wake.ts    the "hey jarvis" listen loop: record → transcribe → match phrase
src/ios/*      device primitives for power, screenshot, speech, and audio/listen
src/memory.ts  markdown memory topics under the Jarvis data dir
src/mcp.ts     MCP server config and client-config export
src/settings.ts persisted model, policy, MCP, and iOS preferences
src/store.ts   bun:sqlite durable sessions + append-only audit log
native/JarvisSpeechHelper   small ObjC helper for the on-device speech path
```

## The seams that matter

- **Permissions** live in `dispatch()`, not around it. Every call is capability-tagged
  and gated; `PolicyBroker.ask` is the human-in-the-loop hook (wire to a device
  prompt / push notification on-device). Every decision is audited, allowed or not.
- **Tools are in-process.** No MCP boundary for first-party device code — MCP is an
  optional edge for external servers, not the spine.
- **Compaction preserves pinned state.** Durable facts go in `session.pin(...)` /
  the rolling summary, injected into the (cached) system prefix, so a bad summary
  can't lose the thing that matters.
- **Model routing** is one decision in a loop you own — cheap heartbeat model,
  escalate to the heavy one when a request proves it's real work.

## Run

```sh
bun install
bun run src/main.ts "list my home dir and tell me what stands out"   # uses .env
bun run typecheck
```

## Auth — Vercel AI Gateway

Requests route through the [Vercel AI Gateway](https://vercel.com/docs/ai-gateway)
(Anthropic-compatible endpoint) for unified observability + spend tracking. The
harness key lives in `.env` (gitignored), minted from the CLI:

```sh
vercel ai-gateway api-keys create --name jarvis   # prints vck_… once — save it
vercel api "/v1/api-keys?purpose=ai-gateway"       # list        keys
```

`.env` holds `AI_GATEWAY_API_KEY` + the Anthropic-compat vars. `main.ts` detects
the gateway and switches model ids to `provider/model` slugs
(`anthropic/claude-opus-4.8`, `anthropic/claude-sonnet-5`, `anthropic/claude-haiku-4.5`).
Drop the gateway vars and set `ANTHROPIC_API_KEY` to hit Anthropic directly instead.

**Claude Code / any Anthropic-SDK tool** through the same gateway (fish):

```fish
source gateway.fish   # exports ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN, empties ANTHROPIC_API_KEY
claude
```

**Claude Agent SDK** — pass the same vars in `query({ options: { env: {...} } })`;
it spawns Claude Code as a subprocess so the env carries through.

## Console (web)

A single `Bun.serve` process (`src/server.ts`) — no framework, no build step —
holds one long-lived Session and serves a self-contained console
(`public/console.html`). One bun process + one sqlite file: fits an on-device budget.

```sh
bun run serve            # http://<device>:8787 — reachable from any device on the LAN
```

It's a control plane, not just a chat box:
- **Chat** with live agent trace (turns, tool calls, results stream over SSE).
- **Knowledge / Session** — pinned durable state, rolling summary, context size,
  and the full 200-message persistent transcript.
- **Memory** — markdown files under `/var/jb/var/root/jarvis/memory`. The root
  file, `index.md`, is always injected first and is reserved for the most
  important standing instructions; ordinary durable facts should use topic files.
- **Policy** — flip each capability allow/ask/deny live (`POST /policy`).
- **Models** — select a gateway model in the UI or ask Jarvis to use
  `switch_model`; changes persist in `settings.json`.
- **Wake** — explicitly start/stop the daemon-owned "hey jarvis" listener. The
  first version handles one-utterance commands like "hey jarvis, what's my
  battery?" and routes the command into the same persistent session.
- **Approvals** — a gated ("ask") tool call renders as Approve/Deny in the browser;
  the `PolicyBroker.ask` hook resolves on your click. This is the human-in-the-loop.
- **Audit** — the append-only log of every tool call.

Endpoints: `GET /events` (SSE), `POST /chat`, `GET /state`, `GET /attachment`,
`POST /approve`, `POST /policy`, `GET /models`, `POST /model`, `GET /mcp`,
`POST /mcp`, `GET /mcp/client-config`, `GET /wake`, `POST /wake`.
A native chat surface can later be a thin client of these same endpoints.

## Deploying to the iPad

```sh
./deploy.sh                       # from the Mac; reads ../device.env for host/port/key
ssh root@<ipad> 'cd /var/jb/var/root/jarvis && sh jarvisctl.sh status'
```

`deploy.sh` bundles `src/server.ts` with `bun build`, syncs it plus `.env`, the
console, `jarvisctl.sh`, the supervisor, and the launchd plist to
`/var/jb/var/root/jarvis`, compiles `native/JarvisSpeechHelper` **on the device**
with clang, grants that helper mic/speech TCC entries, and restarts the daemon.

- **`com.max.jarvis.plist`** — launchd job; it keeps only the small
  `jarvis-supervisor.sh` alive.
- **`jarvis-supervisor.sh`** — starts the Bun daemon only when Jarvis is enabled
  and outside quiet hours, reading `enabled` / `quietEnabled` / `quietStart` /
  `quietEnd` from `/var/mobile/Library/Preferences/com.max.jarvis.plist`. That
  file is what the [`tweaks/JarvisPrefs`](../tweaks/JarvisPrefs) Settings pane
  writes, so scheduling is a stock-looking toggle rather than a config file.
- **`jarvisctl.sh {start|stop|restart|status|launch}`** — device-side control.
  iOS/rootless has no `pkill`/`pgrep`, so it finds PIDs with `ps`+`awk`; it
  prefers `launchctl kickstart` when the job is loaded and falls back to `nohup`.
- **[`tweaks/JarvisScreenshotBridge`](../tweaks/JarvisScreenshotBridge)** — the
  SpringBoard-side screenshot, speech, and audio bridge the device tools call
  into.

## On-device

Several sense/act tools are now real device paths: IOKit for `battery`, the
SpringBoard screenshot bridge for `screenshot`, AVSpeech for `speak` and
`change_voice`, AVFoundation recording plus Apple Speech for `listen`, markdown
memory topics, MCP config export, and model switching through persisted
settings. Input injection, notifications, accessibility control, and
brightness/volume remain backlog; the harness does not change as those tools
land.

The wake path is intentionally Jarvis-owned rather than Siri-backed. The daemon
can run an explicit short-clip loop from the console; when a transcript contains
the configured wake phrase, the text after it is sent to Jarvis as a voice
command. Model-selected tools still use the normal permission policy.

Device brightness/volume controls are intentionally not live right now. A
private `AVSystemController` volume probe inside SpringBoard crashed SpringBoard;
future device-settings work must be proven in an isolated helper before it is
exposed as a Jarvis tool.

Next: (1) test live "hey jarvis, ..." command quality, (2) add a two-stage wake
conversation or native helper if the prototype is useful, (3) probe the HID
entitlement wall for tap/type, (4) route `PolicyBroker.ask` to a real on-device
prompt, (5) expand the sensing layer that compiles context about the user.
