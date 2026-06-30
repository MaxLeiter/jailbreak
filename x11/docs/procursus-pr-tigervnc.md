# Upstream proposal — make `tigervnc` (Xvnc) work on rootless targets

**Target:** [`ProcursusTeam/Procursus`](https://github.com/ProcursusTeam/Procursus)
**Component:** `makefiles/tigervnc.mk`, `build_info/tigervnc-standalone-server.control`
**Type:** bug fix (two independent fixes, can ship together or separately)

This documents two changes that make Procursus's `tigervnc-standalone-server` (the
self-contained `Xvnc`) both **installable** and **runnable** on a rootless jailbreak
(`MEMO_PREFIX=/var/jb`). Both reproduced on iPadOS 17.6.1 (palera1n rootless, CFVER 1900,
`iphoneos-arm64`); the local fork that proves them is in `x11/linux-build/`.

---

## Fix 1 — `Xvnc` keyboard init crashes: `/bin/sh` is hardcoded in `os/utils.c`

### Symptom

On a rootless device, `Xvnc` dies during startup:

```
XKB: Failed to compile keymap
Keyboard initialization failed. This could be a missing or incorrect setup of xkeyboard-config.
(EE) Fatal server error:
(EE) Failed to activate virtual core keyboard: 2
```

### Root cause

xorg-server's `os/utils.c` runs the `xkbcomp` helper through a shell. Its `System()` and
`Popen()` both do:

```c
execl("/bin/sh", "sh", "-c", command, (char *) NULL);
```

On a **rootless** bootstrap there is no `/bin/sh` — the shell is at `$(MEMO_PREFIX)/bin/sh`
(`/var/jb/bin/sh`), and `/` and `/bin` are read-only system paths. The `execl` fails →
`xkbcomp` never runs → keymap compilation fails → the server aborts. `xkbcomp` itself works
perfectly when invoked directly; only the shell hand-off is broken.

This is the same class of `/bin/sh` hardcode Procursus already rewrites elsewhere for the
bootstrap prefix — e.g. `makefiles/fakeroot.mk`
(`sed -i 's|@SHELL@|$(MEMO_PREFIX)/bin/sh|'`) and `makefiles/libiosexec.mk`
(`DEFAULT_INTERPRETER="$(MEMO_PREFIX)/bin/sh"`).

### Proposed change (idiomatic, prefix-aware)

`tigervnc.mk` already patches the bundled xserver tree right after applying tigervnc's own
`xserverNNN.patch`. Add a `sed` immediately after it, mirroring the existing
`MEMO_PREFIX`-based rewrites:

```make
 cd $(BUILD_WORK)/tigervnc/unix/xserver && patch -p1 < $(BUILD_WORK)/tigervnc/unix/xserver$(XORG_VERSION).patch && \
+sed -i 's|execl("/bin/sh"|execl("$(MEMO_PREFIX)/bin/sh"|g' os/utils.c && \
 export ACLOCAL='aclocal -I $(BUILD_BASE)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/aclocal' && \
 export gcc=cc && autoreconf -fiv && ./configure -C \
```

This is a **no-op on rootful targets** (`MEMO_PREFIX` is empty there, so the path stays
`/bin/sh`) and correct on rootless (`/var/jb/bin/sh`). No conditional needed.

### Alternative (explicit patch file)

If maintainers prefer a tracked patch over an inline `sed`, the equivalent diff against
`os/utils.c` is below (this is the literal patch our fork applies, gated to `/var/jb`; for
upstream the `sed` above is preferred because it derives the path from `MEMO_PREFIX` and so
covers every target):

```diff
--- a/os/utils.c
+++ b/os/utils.c
@@ -1388,7 +1388,7 @@
             _exit(127);
         if (setuid(getuid()) == -1)
             _exit(127);
-        execl("/bin/sh", "sh", "-c", command, (char *) NULL);
+        execl("/var/jb/bin/sh", "sh", "-c", command, (char *) NULL);
         _exit(127);
     default:                   /* parent */
         do {
@@ -1474,7 +1474,7 @@
             }
             close(pdes[1]);
         }
-        execl("/bin/sh", "sh", "-c", command, (char *) NULL);
+        execl("/var/jb/bin/sh", "sh", "-c", command, (char *) NULL);
         _exit(127);
     }
```

(File reference in this repo: `x11/ports/tigervnc/patches/0001-xserver-popen-shell-rootless.patch`.)

---

## Fix 2 — `tigervnc-standalone-server` is uninstallable: unsatisfiable
`tigervnc-xorg-extension` dependency

### Symptom

`apt install tigervnc-standalone-server` (or `dpkg -i`) fails with an unsatisfiable
dependency chain; users resort to `dpkg -i --force-depends`.

### Root cause

`build_info/tigervnc-standalone-server.control` lists:

```
Depends: …, tigervnc-common, tigervnc-xorg-extension
```

`tigervnc-xorg-extension` is `libvnc.so`, the VNC module **loaded into a full Xorg server**.
It in turn requires `xserver-xorg-core`, which Procursus does **not** ship for `iphoneos`
(there is no Xorg DDX on iOS) — so `tigervnc-xorg-extension` is itself uninstallable, and
pulling it in makes the standalone server uninstallable too.

The standalone server is a **self-contained `Xvnc`** (a kdrive-style server with a built-in
VNC backend). It does not load `libvnc.so` and does not need the Xorg extension at all. The
dependency is simply wrong for this package.

### Proposed change

```diff
--- a/build_info/tigervnc-standalone-server.control
+++ b/build_info/tigervnc-standalone-server.control
@@
-Depends: xauth, libgl1, libgeneral0, libmd0, libgnutls30, libjpeg62-turbo, libpam2, libpixman-1-0, libx11-6, libxau6, libxdmcp6, libxdamage1, libxfont2, xkbcomp, xkeyboard-config, tigervnc-common, tigervnc-xorg-extension
+Depends: xauth, libgl1, libgeneral0, libmd0, libgnutls30, libjpeg62-turbo, libpam2, libpixman-1-0, libx11-6, libxau6, libxdmcp6, libxdamage1, libxfont2, xkbcomp, xkeyboard-config, tigervnc-common
```

After this, `tigervnc-standalone-server` installs with a plain `dpkg -i` / `apt install` —
no `--force`. (`tigervnc-xorg-extension` can keep building as its own package for any future
target that does ship `xserver-xorg-core`; it just shouldn't be a hard dep of the standalone
server.)

---

## Validation

Built from a fresh Procursus clone with both fixes
(`MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900`) and installed on the device:

- `dpkg -i tigervnc-standalone-server_1.11.0_iphoneos-arm64.deb` — **no `--force`, no broken
  deps.**
- `Xvnc :1 -geometry 2160x1620 -depth 24 -SecurityTypes None -localhost` — **starts cleanly;
  XKB keymap compiles** (the `/var/jb/bin/sh` exec succeeds), `fluxbox` + `xterm` + `xeyes`
  run on the display.
- Confirmed the shipped binary contains `/var/jb/bin/sh` and no longer references `/bin/sh`
  for the spawn path.

---

## Ready-to-paste PR description

> ### Fix `tigervnc-standalone-server` on rootless targets (install + Xvnc keyboard init)
>
> Two small fixes so `tigervnc-standalone-server` installs and runs on rootless bootstraps
> (`MEMO_PREFIX=/var/jb`), e.g. palera1n/Dopamine. Both are no-ops on rootful targets.
>
> **1. `Xvnc` keyboard init crashes — `/bin/sh` hardcoded in the bundled xserver.**
> xorg-server's `os/utils.c` execs `/bin/sh` to run `xkbcomp`; rootless has no `/bin/sh`
> (the shell is `$(MEMO_PREFIX)/bin/sh`), so XKB init fails and the server aborts with
> "Failed to activate virtual core keyboard". Rewrite the spawn path in `tigervnc.mk` after
> the xserver patch, using the same `MEMO_PREFIX` idiom as `fakeroot.mk` / `libiosexec.mk`:
>
> ```make
> sed -i 's|execl("/bin/sh"|execl("$(MEMO_PREFIX)/bin/sh"|g' os/utils.c && \
> ```
>
> No-op on rootful (`MEMO_PREFIX` empty → `/bin/sh`); fixes rootless (`/var/jb/bin/sh`).
>
> **2. Unsatisfiable `tigervnc-xorg-extension` dependency.**
> The standalone server is a self-contained `Xvnc` and doesn't load `libvnc.so`, but it
> Depends on `tigervnc-xorg-extension`, which requires `xserver-xorg-core` (not shipped for
> iphoneos). That makes the standalone server uninstallable without `--force-depends`. Drop
> the dep from `build_info/tigervnc-standalone-server.control`.
>
> **Testing:** built for `iphoneos-arm64` rootless (CFVER 1900) and installed on iPadOS
> 17.6.1 — `dpkg -i` with no force, and `Xvnc` starts with a working keymap (fluxbox + xterm
> render). Both changes are inert on rootful, where `/bin/sh` exists and the dep already
> resolves.

---

## Notes for maintainers

- The shell-path rewrite is intentionally prefix-derived rather than hardcoded, so a single
  change covers rootless and rootful without a conditional.
- If you'd rather not carry an inline `sed`, the patch-file form is in
  `x11/ports/tigervnc/patches/0001-xserver-popen-shell-rootless.patch` in our tree — but it
  hardcodes `/var/jb` and would need a `MEMO_PREFIX` gate, which the `sed` avoids.
- We can split this into two PRs (shell fix / dependency fix) if you prefer to review them
  separately; they're independent.
