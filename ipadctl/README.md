# ipadctl

Lets Claude drive Max's jailbroken iPad's native apps as him: screenshot, tap, swipe, type, keys, home button, open apps.

```
Claude (Claude Code / Desktop in auto mode, or agent/ runner)
  | MCP over stdio
ipad-mcp   (Mac, bun/TypeScript, mcp/)    thin translator
  | HTTP JSON over LAN/Tailscale, bearer token   (API.md)
ipadctld   (iPad, root daemon)            capture + HID injection + policy
```

Layout: `mcp/` the MCP server plus a fake daemon and tests, `agent/` an Agent SDK runner, `API.md` the daemon contract, `core/` the reusable native capture + HID + display core, `daemon/` the on-device root daemon `ipadctld`, `probe/` the phase-0 feasibility probe. The core builds into both the probe and the daemon.

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

Or keep the token out of the MCP config: if `IPADCTL_TOKEN` is unset, the server reads `~/.config/ipadctl/token` (override the path with `IPADCTL_TOKEN_FILE`).

```sh
mkdir -p ~/.config/ipadctl && (umask 077; ipadctl/daemon/deploy.sh token > ~/.config/ipadctl/token)
claude mcp add --scope user ipad -e IPADCTL_URL=http://MaxsiPad.local:8790 -- bun run /abs/path/to/ipadctl/mcp/src/index.ts
```

Tools appear as `mcp__ipad__screenshot`, `zoom`, `tap`, `double_tap`, `long_press`, `swipe`, `scroll`, `type`, `key`, `button`, `open_app`, `open_url`, `list_apps`, `batch`. Coordinates are screenshot pixels.

### Auto mode config (Claude Code)

`autoMode` is read only from `~/.claude/settings.json`, managed settings, or SDK inline settings, never from project `.claude/settings.json`. Merge the `autoMode` block from `agent/auto-mode-settings.example.json` into your `~/.claude/settings.json` yourself. Keep `"$defaults"` in each list or the built-in protections are dropped. Do not add `mcp__ipad__*` to your allow rules, because an allow rule skips the classifier.

## Device daemon (ipadctld)

`ipadctld` is the native root daemon on the iPad that implements `API.md`. Build, deploy and control it with `daemon/deploy.sh` (it signs the binary with `ldid` **on the device** — host-signing private entitlements is an AMFI landmine here):

```sh
ipadctl/daemon/deploy.sh deploy     # build, scp, ldid -S on device, launchctl load
ipadctl/daemon/deploy.sh token      # print the bearer token -> use as IPADCTL_TOKEN
ipadctl/daemon/deploy.sh status     # is it loaded? recent action log
ipadctl/daemon/deploy.sh stop       # launchctl unload
ipadctl/daemon/deploy.sh start      # launchctl load
```

It listens on `:8790` on all interfaces. Everything lives under `/var/jb/var/root/ipadctl/`: the binary, the bearer `token` (mode 0600, generated on first start), the append-only `actions.log`, and `com.max.ipadctld.plist`. The launchd job is loaded explicitly and is **not** installed into `/var/jb/Library/LaunchDaemons`, so it does not auto-start at boot (that waits for the phase-2 safety layer). `GET /v1/info` includes a `selftest` object reporting whether capture returns a non-black frame while the screen is on — the way a silently-denied capture entitlement is noticed.

Point the MCP at the device:

```sh
export IPADCTL_URL=http://MaxsiPad.local:8790
export IPADCTL_TOKEN=$(ipadctl/daemon/deploy.sh token)
```

Live smoke test (opt-in; leave the iPad unlocked on the home screen):

```sh
cd ipadctl/mcp
IPADCTL_LIVE=1 IPADCTL_URL=$IPADCTL_URL IPADCTL_TOKEN=$IPADCTL_TOKEN bun test test/live.test.ts
```

### Device gotcha: PullToRespring2

This iPad runs the **PullToRespring2** tweak: pulling a list **downward past its top** (overscrolling the top by ~92pt) resprings the device. A `scroll` up / `swipe` downward used to reveal a search bar above a list top (e.g. the Settings sidebar search) will respring SpringBoard. `ipadctld` survives a respring (it is a root launchd daemon, independent of SpringBoard, and reconnects without restarting), but avoid the gesture: scroll a list to its top by tapping the status bar and tap the search field directly. The `swipe` and `scroll` tool descriptions carry this warning.

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

Mac side is done and tested against the fake daemon (13 bun tests, typecheck clean). The runner typechecks but has not run live because the Agent SDK OAuth session on this machine has expired.

The device daemon `ipadctld` (phase 1) is built and running on the iPad. Every endpoint and error code in `API.md` is verified live with curl (info + selftest, apps, full and native-resolution-region screenshots, 401 on bad/missing token, 400 on bad JSON, and `app_mismatch`, `invalid` and `locked`). Capture, HID input, orientation mapping, app launching and the action log are working. Not yet done (phase 2): `target` OCR verification (`target_mismatch`), app policy tiers (`app_blocked`), non-ASCII `type` (returns `invalid` today rather than take a pasteboard entitlement), and boot auto-start. The daemon ships with exactly the probe's ablation-proven entitlement set.
