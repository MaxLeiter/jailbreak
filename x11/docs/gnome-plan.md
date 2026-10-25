# GNOME on iOS: the original feasibility plan

**Status: historical.** This was the June 2026 feasibility study for GNOME on this stack. Every
blocker it named is solved, and the approach changed: GNOME Shell runs as a Wayland compositor
(Mutter with an iOS backend), not as an X11 window manager on the old software Xios X server, which
is retired. Current state lives in:

- [handoff/gnome-session.md](handoff/gnome-session.md): the session, the launcher, what `xios-gnome` installs
- [handoff/mutter.md](handoff/mutter.md): MetaBackendIOS
- [handoff/gtk4-typelibs.md](handoff/gtk4-typelibs.md) and [gjs-plan.md](gjs-plan.md): typelibs and gjs/mozjs
- [gnome-apps.md](gnome-apps.md): the GTK4/libadwaita app chain

What follows is the short version of the original argument, kept because recipe comments still cite
the blocker numbers.

## The two targets

"GNOME" meant two different things:

- **GNOME apps** (GTK4 + libadwaita, plain C or Vala). These never needed gjs, typelibs or Mutter.
  They were the near-term win and most of them are published now.
- **GNOME Shell**, the full session. It needed all four blockers below. It boots on the iPad today
  as `xios-gnome`.

## Blocker #1: SpiderMonkey / gjs

gnome-shell is JavaScript on gjs, which embeds SpiderMonkey (mozjs 115 for gjs 1.78 on glib 2.78).
The worry was a Linux to iOS Mach-O cross of mozjs (Rust, cbindgen, `mach`) and the lack of JIT.
Resolved: mozjs 115 cross-builds with a small patch series, runs JIT-less by default, and an
opt-in JIT build works on the A10 through mprotect W^X flips. See [gjs-plan.md](gjs-plan.md) and
[mozjs-jit-plan.md](mozjs-jit-plan.md).

## Blocker #2: GObject-Introspection typelibs for Mach-O

g-ir-scanner compiles and runs a dumper against the target library. Cross builds normally run it
under qemu-user, which only executes Linux ELF. Resolved by running the scanner on the iPad itself,
which is a native arm64 Darwin machine with a Procursus toolchain. Libraries are still cross-built
with `-Dintrospection=false`; typelibs are scanned on the device and shipped (for the Shell, in
`xios-gnome-typelibs`). See [handoff/gtk4-typelibs.md](handoff/gtk4-typelibs.md).

## Blocker #3: Mutter without DRM/KMS/EGL

The original plan assumed Mutter as an X11 compositor on software GLX, which would have been
llvmpipe-slow and could not use the GPU (ANGLE has no X11 platform). Resolved differently: Mutter
runs in Wayland mode with a new `MetaBackendIOS` that renders into the Xios IOSurface through Cogl
on ANGLE/Metal. See [mutter-on-iosc.md](mutter-on-iosc.md) for the design and
[handoff/mutter.md](handoff/mutter.md) for the current backend.

## Blocker #4: logind / systemd / the session daemons

There is no systemd or logind on iOS. Resolved with small GDBus stubs for
`org.freedesktop.login1`, PolicyKit, Accounts and BlueZ (`xios-session-stubs`), a non-systemd
gnome-session build (the FreeBSD-ports patch set, `--builtin`), and a minimal
gnome-settings-daemon. See [gnome-session-plan.md](gnome-session-plan.md).

D-Bus itself was never hard, only unpackaged in Procursus at the time. It is packaged now and the
session runs under `dbus-run-session`.

## The GNOME version ceiling

glib 2.78 pins the GNOME 45/46 generation, and that is what ships (GNOME 46 components on gjs 1.78).
The original reason to stay at or below GNOME 48 was the X11 session, which GNOME 49 drops. That
reason is moot now that the Shell runs on Wayland, but moving past 46 still means moving glib, gjs
and mozjs together.
