# Xios session launcher — pick a desktop flavor from the iPad

Goal: Max picks a preset on the device and the chosen desktop comes up on the
iPad — no more SSHing a `run-*.sh` script for each flavor. This is the first
concrete step of the "install one `xios` meta-package, then pick your flavor"
distribution.

## What it is

One shared library plus two triggers, all under `x11/apps/iosc-desktop/`:

| File | Installed to | Role |
|------|--------------|------|
| `xios-session-lib.sh` | `/var/jb/libexec/xios-session/` | teardown + preset bring-up (single source of truth) |
| `xios-session` | `/var/jb/usr/local/bin/` (in PATH) | on-device / SSH CLI trigger |
| `xios-sessiond` | `/var/jb/libexec/xios-session/` | root daemon; serves the in-app picker |
| `com.max.xios-sessiond.plist` | `/var/jb/Library/LaunchDaemons/` | keeps the daemon up |
| `run-shell.sh`, `run-mutter.sh`, `run-gnome-shell.sh` | `/var/jb/libexec/xios-session/` | reused bring-up scripts |

The library reuses the existing `run-*.sh` scripts behind clean preset names; the
one thing it adds on top is a **bulletproof teardown** so switching sessions never
leaves a stale compositor or socket behind.

Script resolution prefers the **LIVE installed copy** shipped by the owning package
(`/var/jb/usr/local/bin/run-shell.sh` from iosc-shell, `/var/jb/usr/bin/…` for the
GNOME/mutter scripts) over the launcher's own pinned `/var/jb/libexec/xios-session/`
snapshot, which is only a fallback for when the owner package isn't installed. That
way owner edits (e.g. run-shell.sh's `-logical` line) are tracked automatically
instead of drifting behind a stale pin. Override with `XIOS_SESSION_BRINGUP_DIR`.

## Presets (honest about what works today)

| Preset | Brings up | State |
|--------|-----------|-------|
| `iosc` | iosc compositor + wallpaper + panel (`run-shell.sh`) | **works today** |
| `mutter` | raw Mutter 46 `--wayland` (`run-mutter.sh`) | up — flat clutter stage, no shell yet |
| `gnome` | `gnome-shell --wayland` (`run-gnome-shell.sh`) | **experimental** — status reflects the real paint (see below) |
| `app <name>` | a Wayland client against the RUNNING compositor | works where the client + compositor do |
| `stop` | tears everything down, back to SpringBoard | works |

`app <name>` does NOT tear down the compositor — it launches a client onto
whatever is already up. Known names: `kgx`/`console`, `gnome-text-editor`/`editor`,
`gnome-calculator`/`calc`; any other name is run as-is.

The `gnome` preset does NOT trust `xios.json` for success — Mutter writes that file
before the gjs shell loads, so it only proves the compositor came up (identical to
bare mutter). Instead it polls `gnome-shell.log` for ~15s and reports honestly:
`up` only on `GNOME Shell started at` (JS UI + stage loaded); `error` on a hard
failure (`Failed to load module` / typelib `couldn't be found` / `JS ERROR` /
`Execution of main.js threw exception` / `MTLCreateSystemDefaultDevice` nil, or the
process exiting) with the last 40 log lines captured to `xios-session.log`; and a
distinct `compositor-only` when Mutter is up but the shell never painted. Signal
spec courtesy of gnome-session.

The `iosc` preset forwards `IOSC_PANEL_OPACITY` (0-100) when set, e.g.
`IOSC_PANEL_OPACITY=70 xios-session iosc` for a less translucent panel (iosc-shell
>= 0.9.3; default 85).

## Two hard-won gotchas the launcher respects

- **(a) Bulletproof teardown.** Before starting the next compositor, the library
  kills ALL of iosc / mutter / gnome-shell / Xios / panels / clients / session
  buses, then removes every stale `/var/jb/tmp/{wayland-0(.lock), xios.json,
  *-ddx.sock, *-input.sock, iosc-wm.sock, iosc-native.sock}`. The kill pattern is
  anchored to binary paths so it never matches `xios-session` / `xios-sessiond`
  themselves (verified), and it also skips `$$`/`$PPID`.
- **(b) Screen must be awake.** The Xios Metal app returns a nil device when
  backgrounded, so the iPad must be **unlocked and awake** when a preset launches.
  With the in-app picker this is automatic (you're looking at the app). Over SSH,
  unlock the device first.
- **(c) Settle the GPU between compositors (no jetsam).** Switching flavors kills
  the old compositor (which holds a ~30MB GPU IOSurface + Metal/ANGLE context) and
  starts a new one that allocates its own. Back-to-back, the two surfaces co-reside
  and iOS jetsams the foreground Xios app mid-transition (Max hit this switching
  iosc→mutter). So every switching preset: tears down (kills the old compositor AND
  the app, so it isn't holding stale GPU state) → **settles** `XIOS_SESSION_SETTLE`
  seconds (default 2) to let the kernel reclaim the old surface → starts the new
  compositor → **relaunches the display** (`uiopen -b`) once the new surface exists,
  re-launching the app if it isn't running. Every step updates
  `xios-session-status.json` (`stopping → starting → waiting → relaunching → up`) so
  the picker shows progress instead of going dark. App-side resilience (surviving the
  surface teardown without a jetsam so the switch is flash-free) is tracked with
  xios-app.

## How Max picks a flavor

### Path 1 — on-device / SSH CLI (works now, no daemon required)

From a terminal on the iPad, or over SSH
(`ssh -o BatchMode=yes -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@MaxsiPad.local`):

```sh
xios-session iosc                 # lightweight iosc desktop
xios-session mutter               # raw Mutter --wayland
xios-session gnome                # gnome-shell (experimental)
xios-session app kgx              # a terminal onto the running compositor
xios-session app gnome-text-editor
xios-session stop                 # back to SpringBoard
xios-session status               # last session status (JSON)
```

The CLI calls the shared library directly, so it works with no daemon running.
Add `-d`/`--via-daemon` to instead write the request file the in-app picker uses
(exercises the daemon path).

### Path 2 — in-app picker (writes the request; daemon serves it)

The Xios app's Tools card gets a "Desktop Session" section. Tapping a preset writes
`/var/jb/tmp/xios-request.json`:

```json
{ "action": "session", "preset": "iosc", "created_at": "2026-07-01T14:00:00" }
```

`xios-sessiond` watches that file (the SAME channel the app already uses for
`display-profile` requests — it ignores any `action` other than `session`, so the
two coexist) and runs the matching preset. `created_at` changes on every write, so
re-picking the same preset re-triggers. The daemon primes itself with the file's
current contents at startup, so a stale request never auto-launches on boot.

Result feedback: both paths write `/var/jb/tmp/xios-session-status.json`
(`{"preset","state","message","at"}`) which the app / CLI can poll. `state` walks
`stopping → starting → waiting → relaunching → up` through a switch, or ends `error`
/ `stopped` / `compositor-only` (the gnome-specific "Mutter up but the shell never
painted"). The app can surface `message` live so the picker shows what's launching.

## Install

- Deb (shippable): `bash x11/apps/iosc-desktop/package-session.sh` →
  `xios-session_1.0.2_iphoneos-arm64.deb` (postinst bootstraps the daemon). Depends
  on `iosc`; recommends `iosc-shell` (for `run-shell.sh` + panel) and `xios` (the app).
- Fast iterate (lead, touches device):
  `bash x11/apps/iosc-desktop/install-xios-session.sh` (scp + bootstrap).

## In-app picker spec (for the Xios app)

Add to `apps/Xios/Sources/XScreen.swift`. A `writeSessionRequest` mirroring the
existing `writeDisplayRequest`, plus a "Desktop Session" section in `presentTools()`:

```swift
private func writeSessionRequest(_ preset: String, app: String? = nil) {
    var obj: [String: Any] = [
        "action": "session",
        "preset": preset,
        "created_by": "Xios.app",
        "created_at": ISO8601DateFormatter().string(from: Date()),
    ]
    if let app = app { obj["app"] = app }
    do {
        let data = try JSONSerialization.data(withJSONObject: obj,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)
        lastToolMessage = "Session: \(preset)" + (app.map { " \($0)" } ?? "")
    } catch {
        lastToolMessage = "Session request failed: \(error.localizedDescription)"
    }
    writeDebugSnapshot()
}
```

In `presentTools()`, right after `stack.addArrangedSubview(message)`:

```swift
addSection("Desktop Session", to: stack)
for (label, preset, app) in [
    ("iosc  lightweight (works today)", "iosc", String?.none),
    ("Mutter  raw compositor", "mutter", nil),
    ("GNOME Shell  experimental", "gnome", nil),
] {
    stack.addArrangedSubview(panelButton(label) { [weak self, weak message] in
        self?.writeSessionRequest(preset, app: app)
        message?.text = self?.lastToolMessage
    })
}
stack.addArrangedSubview(buttonRow([
    panelButton("+ Console")     { [weak self, weak message] in self?.writeSessionRequest("app", app: "kgx");                message?.text = self?.lastToolMessage },
    panelButton("+ Text Editor") { [weak self, weak message] in self?.writeSessionRequest("app", app: "gnome-text-editor");  message?.text = self?.lastToolMessage },
    panelButton("+ Calculator")  { [weak self, weak message] in self?.writeSessionRequest("app", app: "gnome-calculator");   message?.text = self?.lastToolMessage },
]))
stack.addArrangedSubview(panelButton("Stop  (back to SpringBoard)") { [weak self, weak message] in
    self?.writeSessionRequest("stop"); message?.text = self?.lastToolMessage
})
```

Optional polish: poll `/var/jb/tmp/xios-session-status.json` after a tap and surface
`state`/`message` in the card. Requires `xios-session` installed (the daemon serves
the request). No new socket, no `iosc.c`/protocol change — same file channel the app
already writes.
