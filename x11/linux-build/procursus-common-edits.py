#!/usr/bin/env python3
"""Toolchain fixes a fresh Procursus clone needs before anything will build here.

These are not about any one package -- they are what makes the cctools-port
cross toolchain and the staged macOS SDK work at all, so every target needs them
before `make setup`. Extracted from build.sh so a cold volume can be bootstrapped
without dragging the X server along with it (the rootful bring-up starts on the
Wayland path, where Xvfb is not wanted).

Run from inside the Procursus checkout, in the container:

    python3 /work/procursus-common-edits.py

Idempotent. Package-specific edits (tigervnc, the Xios DDX, mesa's swrast
tweaks) stay in build.sh, which calls this first.
"""
import pathlib
import re


def edit(path, fn):
    p = pathlib.Path(path)
    if not p.exists():
        print(f"   (absent, skipped) {path}")
        return
    s = p.read_text()
    n = fn(s)
    if n != s:
        p.write_text(n)
        print(f"   patched {path}")
    else:
        print(f"   (already patched) {path}")


def apply_all():
    # The `setup` target copies macOS-SDK framework headers (FSEvents, Kernel,
    # IOKit, Security, sys/ttydev.h, ...). We provide a real MacOSX.sdk in the
    # image, but keep these copies non-fatal as a safety net for any header a
    # newer SDK might drop.
    edit("Makefile", lambda s: re.sub(r'(\n\t)@(cp -af\s+\$\(MACOSX_SYSROOT\))', r'\1-@\2', s))

    # cctools-port's clang++ defaults to GNU libstdc++ (absent); force Apple libc++.
    def cxxflags(s):
        if "-stdlib=libc++" in s:
            return s
        s = s.replace("CXXFLAGS            := $(CFLAGS)",
                      "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
        s = s.replace("-Wl,-not_for_dyld_shared_cache",
                      "-Wl,-not_for_dyld_shared_cache -stdlib=libc++", 1)  # LDFLAGS line
        return s
    edit("Makefile", cxxflags)

    # Xcode-26 macOS headers (arpa/inet.h, ...) that setup copies into build_base
    # #include <_bounds.h> (bounds-safety, 2024+). Also copy _bounds.h so they
    # resolve (it only needs sys/cdefs.h, which is present).
    edit("Makefile", lambda s: s.replace(
        "/usr/include/{arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}",
        "/usr/include/{_bounds.h,arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}"))

    # dladdr/Dl_info are gated behind `!_POSIX_C_SOURCE || _DARWIN_C_SOURCE`
    # (dlfcn.h:39); define _DARWIN_C_SOURCE globally so dlfcn.h exposes them.
    # (No global -include dlfcn.h -- that regressed C deps like ncurses/libffi.)
    def darwinsrc(s):
        s = s.replace("-D_DARWIN_C_SOURCE -include dlfcn.h", "-D_DARWIN_C_SOURCE")
        if "-D_DARWIN_C_SOURCE" in s:
            return s
        return s.replace("CXXFLAGS            := $(CFLAGS) -stdlib=libc++",
                         "CFLAGS              += -D_DARWIN_C_SOURCE\n"
                         "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
    edit("Makefile", darwinsrc)

    # mesa's freedesktop archive 404s for older versions. This is a dead upstream
    # URL, not anything to do with the X server, so every build that reaches mesa
    # needs it -- gtk+3.0 pulls mesa in, and without this the tarball downloads as
    # an error page and the extract dies with "tar: Child returned status 1".
    edit("makefiles/mesa.mk", lambda s: s.replace(
        "https://mesa.freedesktop.org/archive/mesa-$(MESA_VERSION).tar.xz",
        "https://archive.mesa3d.org/older-versions/21.x/mesa-$(MESA_VERSION).tar.xz"))

    # libpng's sourceforge "files" URL 404s for curl; use the direct-download mirror.
    edit("makefiles/libpng16.mk", lambda s: s.replace(
        "https://sourceforge.net/projects/libpng/files/libpng16/$(LIBPNG16_VERSION)/libpng-$(LIBPNG16_VERSION).tar.xz",
        "https://downloads.sourceforge.net/libpng/libpng-$(LIBPNG16_VERSION).tar.xz"))


if __name__ == "__main__":
    apply_all()
