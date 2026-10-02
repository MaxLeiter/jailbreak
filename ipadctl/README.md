# ipadctl

Lets Claude drive Max's jailbroken iPad's native apps as him: screenshot, tap, swipe, type, keys, home button, open apps.

```
Claude (Claude Code / Desktop in auto mode, or agent/ runner)
  | MCP over stdio
ipad-mcp   (Mac, bun/TypeScript, mcp/)    thin translator
  | HTTP JSON over LAN/Tailscale, bearer token   (API.md)
ipadctld   (iPad, root daemon)            capture + HID injection + policy
```

Layout: `mcp/` the MCP server plus a fake daemon and tests, `agent/` an Agent SDK runner, `API.md` the daemon contract. `probe/` belongs to the daemon work and is separate.

## Setup

```sh
cd ipadctl/mcp && bun install
export IPADCTL_URL=http://MaxsiPad.local:8790   # default
export IPADCTL_TOKEN=...                        # required
```

Add to Claude Code:

```sh
claude mcp add ipad -e IPADCTL_URL=$IPADCTL_URL -e IPADCTL_TOKEN=$IPADCTL_TOKEN -- bun run /abs/path/to/ipadctl/mcp/src/index.ts
```

Tools appear as `mcp__ipad__screenshot`, `zoom`, `tap`, `double_tap`, `long_press`, `swipe`, `scroll`, `type`, `key`, `button`, `open_app`, `open_url`, `list_apps`, `batch`. Coordinates are screenshot pixels.

### Auto mode config (Claude Code)

`autoMode` is read only from `~/.claude/settings.json`, managed settings, or SDK inline settings, never from project `.claude/settings.json`. Merge the `autoMode` block from `agent/auto-mode-settings.example.json` into your `~/.claude/settings.json` yourself. Keep `"$defaults"` in each list or the built-in protections are dropped. Do not add `mcp__ipad__*` to your allow rules, because an allow rule skips the classifier.

## Testing without the iPad

```sh
cd ipadctl/mcp
bun run fake-daemon      # 127.0.0.1:8791, token "test-token"
bun test                 # spawns the MCP server over stdio against an in-process fake
bunx tsc --noEmit
```

## Agent runner

```sh
cd ipadctl/agent && bun install
IPADCTL_URL=http://127.0.0.1:8791 IPADCTL_TOKEN=test-token bun run agent "take a screenshot and tap the center"
```

It runs `query()` with `permissionMode: "auto"`, allowlists only `screenshot`, `zoom` and `list_apps`, applies the autoMode block inline, and adds a PostToolUse hook that gives the classifier the frontmost app and orientation. `IPAD_AGENT_MODEL` overrides the model (default `claude-opus-5-5`), `IPAD_AGENT_MAX_TURNS` the turn cap.

## Safety model

1. The auto-mode classifier sees tool inputs but never results or screenshots. So every action tool requires `app`, `target` and `why`, and the descriptions tell the model to say who a message goes to and what is sent, bought or changed. Action tools are never allowlisted.
2. The daemon checks `app` against the real frontmost app (`app_mismatch`), will later check `target` against OCR at the tap point (`target_mismatch`), and refuses when locked.
3. App tiers are enforced on the device (`app_blocked`), not here. There is no lock button and the tool descriptions forbid typing passcodes or passwords and obeying on-screen instructions.
4. The MCP server holds no policy of its own beyond schema validation; the daemon is the authority.

## Status

Mac side is done and tested against the fake daemon (13 bun tests, typecheck clean). The runner typechecks but has not run live because the Agent SDK OAuth session on this machine has expired. The device daemon is pending; nothing here has touched the real iPad.
