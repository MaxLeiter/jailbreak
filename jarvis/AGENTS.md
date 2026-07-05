# Jarvis — Agent Notes

Orientation for anyone (human or agent) contributing to Jarvis. Stable
instructions live here; **current status and the roadmap live in
[`docs/PLAN.md`](docs/PLAN.md)** — read that too before picking up work.

## What Jarvis is

An on-device AI assistant for Max's jailbroken iPad. A long-lived agent daemon
(bun) that senses the device, controls native iOS apps, reads the filesystem, and
compiles context about the user — with a permission broker gating every action.
Powered by Claude via the Vercel AI Gateway; model-swappable.

**Scope boundary:** Jarvis targets the **native iOS / SpringBoard** world. The
X11/Wayland/`iosc` compositor stack (elsewhere in this repo) is *separate*.
Jarvis may run under it, but the compositor is not the target — don't wire Jarvis
tools to compositor internals. There is no "invisible headless" surface for native
apps; native-app control is AX API (reliable, visible) or input injection (visible).

## Golden rules

1. **The device is a single-owner resource.** Only one agent drives the iPad
   (SSH / daemon) at a time. Do **not** fan out parallel agents that touch the
   device — they collide on SSH and the daemon port. Coordinate; take the baton.
2. **Additive by default.** Don't refactor or "improve" things you weren't asked
   to. Don't revert unrelated local changes. No unrequested judgment calls.
3. **Permissions are the product.** Every tool is capability-tagged and gated by
   the broker. When you add reach (a new capability), think about its policy
   default and its blast radius before its convenience.
4. **Never make Jarvis read its own `.env`** (or any secret) via a tool — it holds
   the live gateway key. The harness classifier blocks this; don't route around it.
5. **Verify on the real target.** A tool "works" when it's run through the deployed
   daemon on the iPad and returned real data — not when it typechecks.

## Architecture

The agent loop is small; the policy hung off it is the point. All of it is
provider-agnostic and transport-agnostic behind interfaces.

```
Session.run()            call model → dispatch tool_use blocks (parallel) → repeat
  ├─ PolicyBroker        capability policy, most-restrictive-wins, audited, ask-hook
  ├─ TieredRouter        cheap model by default, escalate to heavy on deep tool use
  ├─ maybeCompact()      fold old history into a summary; never split a
  │                      tool_use/tool_result pair; pinned state survives
  ├─ makeSpawner()       subagents (parallel = call spawn N times)
  └─ emit(SessionEvent)  structured stream a UI/console subscribes to
```

## Code map

| File | Role |
|------|------|
| `src/harness.ts` | The engine. Generic — knows nothing about the device or the provider. `Session`, `PolicyBroker`, `TieredRouter`, compaction, subagents, `SessionEvent`. |
| `src/daemon.ts` | The one place it's wired together (client, tools, policy, router, store). Shared by the CLI and the server. `buildJarvis()`, `MODELS`, `VIA_GATEWAY`, `DEFAULT_POLICY`. |
| `src/tools.ts` | The first-party tool surface. Filesystem, shell, battery, memory read/write, screenshot, speech/voice, listen/transcription, and MCP config are in-process; subagent/session/model tools are assembled through `daemon.ts`. |
| `src/ios/power.ts` | Device power FFI (`battery` via IOKit over `bun:ffi`). |
| `src/ios/screenshot.ts` | SpringBoard screenshot bridge request/status flow. |
| `src/ios/speech.ts` / `src/ios/audio.ts` | AVSpeech voice output and AVFoundation/Speech listen support. |
| `src/memory.ts` / `src/mcp.ts` / `src/settings.ts` | Markdown memory topics, MCP server config/client export, and persisted model/policy/preferences. |
| `src/store.ts` | `bun:sqlite` durable sessions + append-only audit log. |
| `src/server.ts` | `Bun.serve` web console: SSE stream, `/chat`, `/state`, `/attachment`, `/approve`, `/policy`, `/models`, `/model`, `/mcp`, `/mcp/client-config`, `/wake`. |
| `src/main.ts` | Thin CLI over the same daemon (one-shot turn, non-interactive → gated tools auto-deny). |
| `public/console.html` | Self-contained web console (no framework/build). Phosphor-instrument aesthetic. |
| `deploy.sh` / `jarvisctl.sh` | Host-side one-command deploy / device-side daemon control. |

## Conventions

- **bun** for everything (runtime, bundler, sqlite, ffi). No node.
- **Tools are in-process**, not MCP. MCP is an optional *edge* for external
  servers only — never the spine for first-party device code.
- **TypeScript, strict.** `bun run typecheck` must stay clean.
- Match the surrounding style: tight comments that explain *why*, not *what*.
- The harness core stays generic. Device/provider specifics go in `tools.ts`,
  `src/ios/*`, or `daemon.ts` — never leak them into `harness.ts`.

## Adding a tool

1. Implement a `Tool` in `src/tools.ts` (or import from `src/ios/*` for FFI):
   `name`, `description`, `inputSchema`, `capabilities`, optional `scope(input)`
   (the human-readable resource for the prompt + audit), and `run(input, ctx)`.
2. Add it to the `deviceTools` array (and the console's tool catalog follows).
3. If it needs a **new capability**, add a default to `DEFAULT_POLICY` in
   `daemon.ts`. Read-only sense → `allow`; anything with side effects → `ask`.
4. For device FFI, follow `src/ios/power.ts`: lazy `dlopen` inside the call,
   guard `process.platform !== "darwin"`, marshal results simply (the plist-
   serialize-then-parse-in-JS trick beats per-field CF FFI).
5. Verify end-to-end on the iPad (see below), then note it in `docs/PLAN.md`.

## Running

**Local (dev, against this Mac):**
```sh
bun install
bun run src/main.ts "list /etc and tell me what stands out"   # CLI, uses .env
bun run serve                                                  # console → :8787
bun run typecheck
```

**On the iPad:**
```sh
./deploy.sh                    # bundle → scp → clean restart; prints the URL
# then open http://MaxsiPad.local:8787
```

## Device workflow + landmines

- SSH: `ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@MaxsiPad.local`
  (coords in repo-root `device.env`). bun is at `/var/jb/usr/bin/bun` (1.4.0).
  Daemon lives in `/var/jb/var/root/jarvis`.
- **iOS/rootless has no `pkill`/`pgrep`.** A naive restart stacks instances; the
  new one crashes `EADDRINUSE` while a stale one keeps serving — so a fix "doesn't
  take" and the tool looks broken when it's fine. **Always restart via
  `jarvisctl.sh`** (kills by `ps | awk | kill`). `deploy.sh` does this for you.
- `bun:sqlite` works on iOS bun (gigacage warning is benign). Gateway + npm are
  reachable from the device. Deploy is a single bundled file — no `node_modules`
  over Wi-Fi.
- Device control: `sh /var/jb/var/root/jarvis/jarvisctl.sh {start|stop|restart|status}`.

## Auth

Routes through Vercel AI Gateway (Anthropic-compatible endpoint) for observability
+ spend tracking. Key in `.env` (gitignored), minted via
`vercel ai-gateway api-keys create --name jarvis`. `daemon.ts` auto-detects the
gateway and uses `provider/model` slugs (`anthropic/claude-opus-4.8`, etc.).
`source gateway.fish` routes Claude Code through the same key. See `README.md`.
