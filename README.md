# Jailbreak utilities and Xios

My rootless iOS jailbreak stuff: a few Theos tweaks, some companion apps, the
tooling for a static APT repo, and Xios, which is a Wayland/X11 desktop running
natively on a jailbroken iPad.

If you're here for the desktop, that lives in [`x11/`](x11/). There's a write-up
at [maxleiter.com/blog/xios](https://maxleiter.com/blog/xios) and a slopwiki at
[xios.maxleiter.com](https://xios.maxleiter.com).

Most of this was written by Claude, and I've leaned on it heavily throughout.
Read anything here with that in mind.

Contributions are welcome. Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before
opening a PR, and [`docs/PUBLIC-READINESS.md`](docs/PUBLIC-READINESS.md) for the
remaining GitHub history-cache cleanup. Publishing packages, signing the repo,
deploying, and verifying on a device are things I do myself.

It's largely rootless only. Everything builds with
`THEOS_PACKAGE_SCHEME = rootless`, installs under `/var/jb`, and is packaged as
`iphoneos-arm64`. I test on an iPad running iPadOS 17.6.1, so that's the setup I
know works.

## What you need

- Theos at `~/theos`, with `THEOS=$HOME/theos` exported in your shell
- `iPhoneOS16.5.sdk` in `$THEOS/sdks` (deployment target is 15.0)
- `ldid` and `xz` from Homebrew, for signing and packaging
- `libimobiledevice` from Homebrew, for `idevicesyslog` and `ideviceinfo`

## Building things

```bash
# Build only, produces packages/*.deb
bin/build.sh tweaks/PullToRespring2

# Build and install to the iPad, then respring (needs an SSH key, see below)
bin/install.sh tweaks/PullToRespring2

# Build and install a companion app
bin/install-app.sh apps/TaskManager

# Watch the device log live, over USB, no SSH needed
bin/logs.sh PullToRespring2
```

Inside a tweak directory you can also use Theos directly:

```bash
make package            # build the .deb into ./packages
make package install    # build, push to THEOS_DEVICE_IP, respring
make clean              # needed when switching rootless <-> rootful
```

## The Sileo repo

There's a static APT repo at [repo.maxleiter.com](https://repo.maxleiter.com),
hosted on Vercel. To add it in Sileo:
`sileo://source/https://repo.maxleiter.com/`. The landing page has buttons for
Sileo, Zebra, and Cydia plus a copyable URL.

`repo/` holds the static site and the signed metadata. The actual package
payloads live in `repo/debs/`, which is gitignored, and get uploaded to Vercel
Blob before a deploy. `bin/lib/make-repo.py` generates the index (`Packages`,
`Packages.gz`, `Release`, `index.html`, `CydiaIcon.png`) from that local cache.

```bash
bin/build.sh tweaks/<Name>
cp tweaks/<Name>/packages/*.deb repo/debs/   # stage what you want public
bin/publish-staging.sh                       # upload payloads, deploy to dev.repo.maxleiter.com
git add repo/Packages && git commit          # the diff here is what goes public
bin/publish-repo.sh                          # publish the committed index to production
bin/publish-repo.sh --only <pkg>[,<pkg>]     # ship just these against the live index
```

Publishing runs locally because the checks that matter need the real `.deb`
files: the Blob upload, DER entitlement re-signing, and the Procursus shadow
check. CI validates the index on every PR but never deploys.

Two things worth knowing. Production publishes the committed index, and refuses
to run if `repo/Packages` differs from `HEAD`. Staging is the step that actually
uploads payloads, so don't run the production step alone for something you just
built. `--only` scopes a publish to named packages: it swaps just those stanzas
into the live index in a throwaway copy and re-checks that dependencies still
solve.

Production filenames are immutable, so bump a package's version or revision
rather than trying to replace a file that's already published.

Run `bin/setup-repo-guards.sh` once per clone. It registers a structural merge
driver for `repo/Packages`, so branches stop conflicting on the index, and a
Claude Code hook that blocks the two operations that silently destroy work.

## Using the Simulator instead of the iPad

You can load a tweak into the iOS Simulator for faster iteration.
[simject](https://github.com/akemin-dayo/simject) injects your dylib into
Simulator processes using a Simulator build of Cydia Substrate, so your `%hook`s
run against the real iOS frameworks.

```bash
bin/sim.sh tweaks/PullToRespring2   # build for the Simulator, copy to /opt/simject, resim
```

This doesn't replace testing on the device. There's no jailbreak or real
SpringBoard in the sim, some frameworks are missing or behave differently, and
you're running whatever runtime you have installed (18.x for me) rather than the
device's 17.6.1. Iterate here, then `bin/install.sh` to confirm on the iPad.

This Mac is Apple Silicon, so the Simulator is arm64. Ignore older guides that
say x86_64. `sim.sh` overrides the device build settings on the command line
(`TARGET=simulator:clang::12.0 ARCHS=arm64 THEOS_PACKAGE_SCHEME=`, since the
rootless scheme is device-only), finds the built dylib, copies it and its filter
plist into `/opt/simject`, re-signs it ad-hoc, and runs `resim`.

If more than one Simulator is booted, `resim` with no arguments is ambiguous.
Target one explicitly with `resim -i <UUID>` or
`resim -d "iPad (10th generation)" -v 18.2`.

Two things that cost me time:

Code signing isn't optional. The Simulator enforces real code signing on Apple
Silicon. Theos signs during the build, but its post-link fixups leave the
signature stale, and the kernel then kills SpringBoard with an invalid signature
`SIGKILL`, which looks like a respring loop. `sim.sh` handles this by re-signing
the dylib last (`codesign --force --sign -`) on the final bytes on disk. If you
load a tweak by hand, do the same.

The tmpfs symlinks disappear when the Mac reboots. Runtimes now live as sealed
read-only volumes under `/Library/Developer/CoreSimulator/Volumes/iOS_*`, so the
installer mounts a RAM-backed tmpfs over each runtime's `Library` and puts the
substrate symlinks there. After a reboot, re-run
`cd ~/simject && ./installsubstrate.sh link`, or install the LaunchDaemon below.

### Relinking automatically after a reboot

`bin/simject-relink.sh` re-runs `installsubstrate.sh link`.
`bin/launchd/com.max.simject-relink.plist` runs it as root at boot and whenever
a runtime volume mounts, since those can mount lazily when the Simulator
launches. The wrapper is idempotent and logs to
`~/Library/Logs/simject-relink.log`. Install it once:

```bash
sudo cp ~/Documents/jailbreak/bin/launchd/com.max.simject-relink.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.max.simject-relink.plist
sudo chmod 644        /Library/LaunchDaemons/com.max.simject-relink.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.max.simject-relink.plist
# check it worked:
sudo launchctl kickstart -k system/com.max.simject-relink && cat ~/Library/Logs/simject-relink.log
```

### Setting simject up the first time

You need Xcode selected, an iOS Development cert, and Full Disk Access granted
to Terminal (System Settings > Privacy & Security). simject's substrate build
([PoomSmart/substitute](https://github.com/PoomSmart/substitute)) needs Python
3.9 specifically, because its `configure` imports the stdlib `parser` module
that was removed in 3.10. `uv python install 3.9` gets you one, then put it on
PATH with `ln -sf "$(uv python find 3.9)" /opt/homebrew/bin/python3.9`.

```bash
sudo xcode-select -s /Applications/Xcode.app
git clone https://github.com/akemin-dayo/simject.git ~/simject
cd ~/simject && make setup
./installsubstrate.sh subst       # build and symlink substrate into all runtimes
./installsubstrate.sh theos       # install the simulator CydiaSubstrate.tbd so tweaks link
# later: ./installsubstrate.sh link   # after a reboot, or a new simulator
```

There's also a drag-and-drop alternative,
[simulator-trainer](https://github.com/EthanArbuckle/simulator-trainer).

## SSH keys

So the install scripts stop asking for a password, authorize your Mac's key on
the iPad once. Set the host in `device.env` or `THEOS_DEVICE_IP`.

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id -o StrictHostKeyChecking=accept-new root@<device-hostname>
```

If your device still has the default root password, change it before putting it
on a network you don't trust.

## Finding things to hook

- Headers: dump them with `class-dump`, or use one of the community header
  repos. Put them in a `headers/` dir and add `-I` to `<Tweak>_CFLAGS`.
- Finding classes and methods: open the target binary in a disassembler, use
  cycript or Frida on-device, or read an existing tweak that hooks the same app.
- Logging: `NSLog(@"[Name] ...")`, then `bin/logs.sh Name`.
