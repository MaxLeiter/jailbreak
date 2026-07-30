# Jailbreak Utilities and Xios

Rootless iOS jailbreak projects: Theos tweaks, small companion apps, static APT
repo tooling, and the Xios X11/Wayland-on-iOS desktop stack.

> **Want to see more about the X11/Wayland work?** See **[`x11/`](x11/)** — a
> native Linux desktop (a GPU Wayland compositor, hardware Xwayland, and
> GNOME/KDE apps) running on a jailbroken iPad. Write-up:
> **[maxleiter.com/blog/xios](https://maxleiter.com/blog/xios)**. Wiki:
> **[xios.maxleiter.com](https://xios.maxleiter.com)**.

## Public development

This repo is being prepared for public development. Read
[`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a PR and
[`docs/PUBLIC-READINESS.md`](docs/PUBLIC-READINESS.md) for the remaining launch
checklist. Package publication, APT signing, Vercel deployment, and device
verification remain maintainer-controlled.

## Reference Device

| Field | Value |
|---|---|
| Model | iPad 7th gen (`iPad7,12`, A10 Fusion) |
| OS | iPadOS **17.6.1** (build 21G93) |
| Arch | `arm64` (A10 — **not** arm64e) |
| Jailbreak | **Dopamine** — **rootless** |
| Layout | rootless → everything installs under **`/var/jb`** |
| Substrate | ElleKit (provides `mobilesubstrate`) |
| Package manager | Sileo |
| SSH | OpenSSH on port 22, user `root`; configure the host in `device.env` |

Because this is a **rootless** jailbreak, every tweak builds with
`THEOS_PACKAGE_SCHEME = rootless`, installs to `/var/jb`, and is packaged as
`iphoneos-arm64`. (rootful builds install to `/` — not used here.)

## Toolchain

- **Theos** at `~/theos` (`$THEOS`) — the tweak build system + Logos preprocessor
- iOS SDK: `iPhoneOS16.5.sdk` in `$THEOS/sdks` (newer SDK, deployment target 15.0)
- `ldid`, `xz` (via Homebrew) — signing + packaging
- `libimobiledevice` (via Homebrew) — USB device tools (`idevicesyslog`, `ideviceinfo`)
- `THEOS=$HOME/theos` exported in your shell

## Layout

```
jailbreak/
├── apps/                 # companion iOS apps (SwiftUI, built unsigned)
├── bin/
│   ├── build.sh          # build a tweak's .deb
│   ├── install.sh        # build + install a tweak to the iPad over SSH, then respring
│   ├── uninstall.sh      # recovery: remove a tweak by package id + respring
│   ├── install-app.sh    # build + push an apps/<Name> bundle over SSH + uicache
│   ├── package-app.sh    # build an apps/<Name> bundle into an installable .deb
│   ├── sim.sh            # build a tweak for the iOS Simulator + load via simject
│   ├── sim-app.sh        # build + launch an app in the Simulator + screenshot it
│   ├── logs.sh           # live device console over USB (idevicesyslog)
│   ├── publish-repo.sh   # deploy the APT repo (--staging for dev.repo, --only to scope)
│   ├── publish-staging.sh # same as publish-repo.sh --staging
│   ├── upload-debs-to-blob.sh # push package payloads to Vercel Blob
│   ├── setup-repo-guards.sh # once per clone: index merge driver + agent guardrails
│   └── lib/              # repo-pipeline internals (make-repo, index scoping, solvability, audit)
├── docs/                 # public-readiness and process notes
├── repo/                 # generated static APT repo site and metadata
├── tweaks/               # Theos tweak projects
└── x11/                  # Xios: X11/Wayland desktop stack for iOS
```

`AGENTS.md` holds the working conventions for this tree (including for coding
agents); each subproject has its own README and, where it matters, its own
`AGENTS.md`.

### What's in here

| Tweak | What it does |
|---|---|
| [`tweaks/PullToRespring2`](tweaks/PullToRespring2) | Pull down at the top of Settings to respring. Rootless refresh of NoahSaso's PullToRespring. |
| [`tweaks/KioskMode`](tweaks/KioskMode) | Keeps one chosen app frontmost; volume-button escape. Paired with `apps/KioskMode`. |
| [`tweaks/AutoLockPicker`](tweaks/AutoLockPicker) | Replaces the Auto-Lock preset list with a real time picker. |
| [`tweaks/XiosPrefs`](tweaks/XiosPrefs) | Settings pane for Xios Home Screen app sync. |

| App | What it is |
|---|---|
| [`apps/KitchenHub`](apps/KitchenHub) | Wall-mounted kitchen dashboard: timers, weather, recipes, Sonos, Apple TV remote. |
| [`apps/TaskManager`](apps/TaskManager) | Activity-Monitor-style process monitor with kill actions. |
| [`apps/KioskMode`](apps/KioskMode) | Onboarding + dashboard that configures the KioskMode tweak. |

## Workflow

```bash
# Build only (produces packages/*.deb)
bin/build.sh tweaks/PullToRespring2

# Build + install to the iPad + respring (needs SSH key set up, see below)
bin/install.sh tweaks/PullToRespring2

# Build + install a companion app
bin/install-app.sh apps/TaskManager

# Watch the device log live (works over USB, no SSH needed)
bin/logs.sh PullToRespring2
```

## Sileo repo (hosted on Vercel)

A static APT repo is published at **https://repo.maxleiter.com**. `repo/` holds
the static site and signed metadata; package payloads live locally in ignored
`repo/debs/` and are uploaded to Vercel Blob before deployment.
`bin/lib/make-repo.py` generates the index (`Packages`, `Packages.gz`,
`Release`, `index.html`, `CydiaIcon.png`) from that local cache. Use the staging
publisher for low-cache iteration; production `.deb` filenames are immutable, so
bump the package version/revision instead of replacing an already-published file.

Publishing runs locally, because the gates that matter need the actual `.deb`
files: the Blob upload, DER entitlement re-signing, and the Procursus shadow
check. CI validates the index on every PR but does not deploy.

```bash
bin/build.sh tweaks/<Name>
cp tweaks/<Name>/packages/*.deb repo/debs/   # stage what you want public
bin/publish-staging.sh                       # upload payloads + deploy low-cache staging (dev.repo.maxleiter.com)
git add repo/Packages && git commit          # review the diff: it is what goes public
bin/publish-repo.sh                          # production: publish the committed index
bin/publish-repo.sh --only <pkg>[,<pkg>]     # ship just these against the live index
```

Production publishes the *committed* index, so the diff you commit is the change
users receive — and a prod publish refuses to run while `repo/Packages` differs
from `HEAD`. Staging is the step that uploads payloads, so don't run the
production step alone for something you just built. `--only pkg[,pkg]` scopes a
publish to named packages instead: it swaps only those stanzas into the live
index in a throwaway deploy copy and re-checks dependency solvability there.

Run `bin/setup-repo-guards.sh` once per clone: it registers the structural merge
driver for `repo/Packages` (so branches stop conflicting on the index) and a
Claude Code hook that blocks the two operations that destroy work silently.

Add it in Sileo: `sileo://source/https://repo.maxleiter.com/` (the landing page
also has Sileo / Zebra / Cydia buttons and the copyable URL).

## iOS Simulator loop (device-free, via simject)

For fast iteration you can load a tweak into the **iOS Simulator** instead of the
iPad. [simject](https://github.com/akemin-dayo/simject) injects your tweak's
dylib into Simulator processes via a Simulator build of Cydia Substrate, so your
`%hook`s run against the real iOS frameworks in the sim.

**This is a complement, not a replacement.** There's no real jailbreak or device
SpringBoard in the sim, and some frameworks (Weather, etc.) are missing or differ.
Iterate logic here, then `bin/install.sh` to confirm on the iPad. The sim also
runs whatever runtime you have (e.g. iOS 18.x), **not** the device's 17.6.1.

```bash
bin/sim.sh tweaks/PullToRespring2     # build for Simulator (arm64) + copy to /opt/simject + resim
```

This Mac is Apple Silicon, so the Simulator is **arm64** — ignore older guides
that say `x86_64`. `sim.sh` overrides the device build settings on the command
line: `TARGET=simulator:clang::12.0 ARCHS=arm64 THEOS_PACKAGE_SCHEME=` (the
rootless scheme is device-only), finds the built `.dylib`, copies it **and** its
filter `.plist` into `/opt/simject`, **re-signs it ad-hoc**, then runs `resim`.

If more than one Simulator is booted, `resim` (no args) is ambiguous — target one
explicitly: `resim -i <UUID>` or `resim -d "iPad (10th generation)" -v 18.2`.

### Gotchas (learned the hard way)

- **Code signing is mandatory.** The Simulator enforces real code signing on
  Apple Silicon. Theos signs during the build, but its post-link fixups leave the
  signature stale → the kernel kills the host process (SpringBoard) with an
  *"Invalid Page" / Code Signature Invalid* `SIGKILL`, i.e. a **respring loop**.
  `sim.sh` fixes this by re-signing the dylib **last** (`codesign --force --sign -`)
  on the final on-disk bytes. If you load a tweak by hand, do the same.
- **tmpfs symlinks vanish on macOS reboot.** Runtimes now live as *sealed,
  read-only* volumes under `/Library/Developer/CoreSimulator/Volumes/iOS_*`, so
  the installer mounts a RAM-backed `tmpfs` over each runtime's `Library` and puts
  the substrate symlinks there. After a **Mac reboot** they're gone — re-run
  `cd ~/simject && ./installsubstrate.sh link` (fast, no rebuild), or install the
  **LaunchDaemon** below so it happens automatically.

### Auto-relink on reboot (LaunchDaemon)

`bin/simject-relink.sh` re-runs `installsubstrate.sh link` automatically.
`bin/launchd/com.max.simject-relink.plist` runs it as root at boot
(`RunAtLoad`) and whenever a runtime volume mounts (`StartOnMount`, since those
volumes can mount lazily when Simulator launches). The wrapper is idempotent and
logs to `~/Library/Logs/simject-relink.log`. Install once (needs sudo):

```bash
sudo cp ~/Documents/jailbreak/bin/launchd/com.max.simject-relink.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.max.simject-relink.plist
sudo chmod 644        /Library/LaunchDaemons/com.max.simject-relink.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.max.simject-relink.plist
# verify:
sudo launchctl kickstart -k system/com.max.simject-relink && cat ~/Library/Logs/simject-relink.log
```

### One-time simject setup

Requires Xcode selected, an iOS Development cert, and **Terminal granted Full
Disk Access** (System Settings → Privacy & Security). simject's substrate build
([PoomSmart/substitute](https://github.com/PoomSmart/substitute)) needs
**Python 3.9** specifically — its `configure` imports the stdlib `parser` module,
removed in Python 3.10+. Get one with `uv python install 3.9` and put it on PATH
(`ln -sf "$(uv python find 3.9)" /opt/homebrew/bin/python3.9`).

```bash
sudo xcode-select -s /Applications/Xcode.app
git clone https://github.com/akemin-dayo/simject.git ~/simject
cd ~/simject && make setup
./installsubstrate.sh subst       # build + symlink substrate into all runtimes
./installsubstrate.sh theos       # install the simulator CydiaSubstrate.tbd into Theos (so tweaks LINK)
# later: ./installsubstrate.sh link    # re-symlink after a reboot or adding a new simulator
```

Drag-and-drop alternative:
[simulator-trainer](https://github.com/EthanArbuckle/simulator-trainer).

Inside a tweak directory you can also use Theos directly:

```bash
make package            # build the .deb into ./packages
make package install    # build + push to THEOS_DEVICE_IP + respring
make clean              # required when switching rootless <-> rootful
```

## One-time SSH key setup

So install scripts do not prompt for a password every time, authorize your Mac's
key on the iPad once. Set the host with `device.env` or `THEOS_DEVICE_IP`.

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id -o StrictHostKeyChecking=accept-new root@<device-hostname>
```

If the device still uses a default root password, change it before putting it on
an untrusted network.

## Anatomy of a tweak

- **`Tweak.x`** — Logos source. `%hook ClassName` ... `%end` intercepts methods;
  `%orig` calls the original. `.x` = ObjC + Logos, `.xm` = ObjC++ + Logos.
- **`<Name>.plist`** — the *filter*: which processes get the dylib injected.
  `Bundles = ( "com.apple.springboard" )` injects into SpringBoard;
  use an app's bundle id to target a specific app.
- **`control`** — Debian package metadata (id, version, deps).
- **`Makefile`** — build config: `TARGET`, `TWEAK_NAME`, frameworks, and
  `THEOS_PACKAGE_SCHEME = rootless`.

## Finding things to hook

- **Headers:** dump with `class-dump`, or use community headers
  (e.g. the iOS runtime headers repos). Drop headers in a `headers/` dir and add
  `-I` to `<Tweak>_CFLAGS`.
- **Class/method discovery:** Look at the target binary in a disassembler, or
  use `cycript`/`Frida` on-device, or browse existing tweak source for the same app.
- **Logging:** `NSLog(@"[Name] ...")` then `bin/logs.sh Name`.

## Notes / gotchas

- A10 is `arm64`; the build also emits an `arm64e` slice (harmless — the iPad
  uses the `arm64` one).
- Run `make clean` when switching package schemes.
- This is standard Dopamine `/var/jb` rootless. A different fork, **roothide**,
  uses a *relocated* jbroot and needs `roothide/Developer`'s Theos fork instead —
  not applicable here.
