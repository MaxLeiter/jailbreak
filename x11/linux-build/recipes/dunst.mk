ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# dunst.mk — dunst, a lightweight notification daemon (github.com/dunst-project/dunst) that
# implements org.freedesktop.Notifications and draws notifications with pangocairo into wl_shm
# buffers mapped as zwlr_layer_surface_v1 (top/overlay layer). Pairs with the iosc compositor.
#
# WHY dunst (not mako): mako hard-requires an sd-bus provider (libsystemd | basu), and basu does
# NOT cross-compile to Darwin (ELF-section error-maps, struct ucred/SCM_CREDENTIALS, kdbus, /proc);
# see recipes/mako.mk + recipes/basu.mk for that dead end. dunst sidesteps it entirely: it speaks
# D-Bus via GDBus (gio-2.0, part of GLib) — NO libdbus-1 link and NO sd-bus at all. At runtime it
# just needs a session bus, provided by the `dbus` package (dbus-daemon).
#
# PROTOCOLS (served by the iosc compositor): its bundled wlr-layer-shell-unstable-v1 (top/overlay
# layer, to float notifications over everything) + wlr-foreign-toplevel + idle, plus xdg-shell,
# cursor-shape-v1 and tablet-unstable-v2 from wayland-protocols (the gtk-calc volume ships 1.38;
# dunst needs >=1.32 for cursor-shape). Protocol headers are generated at build time by the host
# wayland-scanner (native, via WAYLAND_NATIVE_ROOT/bin on PATH) over the wayland-protocols XML in
# build_base (DATA_DIR_WAYLAND_PROTOCOLS).
#
# BUILD SYSTEM: plain Makefile (config.mk knobs), NOT meson/cmake. We force WAYLAND=1 X11=0 (drops
# the whole libx11/xrandr/xinerama closure), DUNSTIFY=0 (skips the libnotify helper so we don't take
# a libnotify dep), SYSTEMD=0 and COMPLETIONS=0. VERSION is pinned (the release tarball has no git).
#
# PORTABILITY: dunst is mostly clean on Darwin/iOS except:
#   * config.mk's DEFAULT_LDFLAGS carries `-lrt` — no librt on iOS (clock_gettime is in libc); the
#     -setup rule seds it out.
#   * ports/dunst/patches aliases `st_mtim` to Darwin's `st_mtimespec` and replaces the unavailable
#     iOS wordexp()/wordfree() path with a GLib config-path expansion helper.
#   * src/input.c, src/wayland/wl.c and src/wayland/wl_seat.c include <linux/input-event-codes.h>
#     for BTN_* codes — the driver drops the same lightweight shim foot/imv/slurp use into build_base.
# No inotify (1.13 dropped it), no memfd/timerfd/signalfd/epoll (event loop is GLib's GMainLoop),
# no getrandom; the wl_shm pool is backed by shm_open (portable). CLOCK_BOOTTIME is already
# `#ifdef __linux__`-guarded, falling back to CLOCK_MONOTONIC on Darwin.
#
# DEPENDS (target): gio/glib-2.0, gdk-pixbuf-2.0, pango/pangocairo, cairo, wayland(-client/-cursor)
# — all already staged on procursus-vol-gtk-calc (the full GTK4 stack). Plus `dbus` at runtime.

SUBPROJECTS   += dunst
DUNST_VERSION := 1.13.2
DEB_DUNST_V   ?= $(DUNST_VERSION)+ios2

dunst-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/dunst-project/dunst/archive/refs/tags/v$(DUNST_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(DUNST_VERSION).tar.gz,dunst-$(DUNST_VERSION),dunst)
	$(call DO_PATCH,dunst,dunst,-p1)

ifneq ($(wildcard $(BUILD_WORK)/dunst/.build_complete),)
dunst:
	@echo "Using previously built dunst."
else
dunst: dunst-setup wayland wayland-protocols cairo pango gdk-pixbuf
	# 1) Generate the wayland protocol headers with the NATIVE wayland-scanner (on PATH via
	#    WAYLAND_NATIVE_ROOT, same trick as slurp/foot). dunst reads xdg-shell/cursor-shape/tablet/
	#    ext-idle XML from the cross wayland-protocols staged in build_base; point it there directly
	#    (cross-pkg-config's --variable=pkgdatadir returns the logical /var/jb path, but the native
	#    scanner needs the real on-disk build_base path).
	cd $(BUILD_WORK)/dunst && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" $(MAKE) wayland-protocols \
			WAYLAND=1 X11=0 \
			PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config \
			DATA_DIR_WAYLAND_PROTOCOLS=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/wayland-protocols
	# 2) Build the daemon + the D-Bus service activation file. CC is the cross wrapper (cc-nounused,
	#    injected by build-wayland-utils.sh); cross-pkg-config resolves gio/pango/cairo/wayland from
	#    build_base. X11 backend fully off. docs (pod2man) and dunstify (libnotify) are not built.
	cd $(BUILD_WORK)/dunst && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" $(MAKE) dunst service-dbus \
			WAYLAND=1 X11=0 DUNSTIFY=0 SYSTEMD=0 COMPLETIONS=0 \
			VERSION=$(DUNST_VERSION) \
			CC="$(CC)" \
			EXTRA_CFLAGS="-Wno-error" \
			PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config \
			BINDIR=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			DATA_DIR_WAYLAND_PROTOCOLS=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/wayland-protocols
	# 2b) libintl-dev unversioned trap: pango's .pc adds `-lintl`, and the linker resolves it to the
	#    unversioned libintl.dylib symlink (a -dev artefact), so the binary records an install_name of
	#    @rpath/libintl.dylib — which does NOT exist at runtime (libintl8 ships only libintl.8.dylib).
	#    Retarget it to the versioned dylib so dyld resolves it against the runtime libintl8 package.
	#    BEFORE staging/SIGN (install_name_tool invalidates the ad-hoc signature; SIGN re-covers it).
	$(I_N_T) -change @rpath/libintl.dylib @rpath/libintl.8.dylib $(BUILD_WORK)/dunst/dunst
	# 3) Stage by hand (avoid `make install`, whose install-dunst pulls the pod2man doc chain).
	#    Ship: dunst daemon, dunstctl (POSIX sh client), the org.freedesktop.Notifications D-Bus
	#    activation file, and the default dunstrc.
	mkdir -p $(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	install -m755 $(BUILD_WORK)/dunst/dunst $(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dunst
	install -m755 $(BUILD_WORK)/dunst/dunstctl $(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dunstctl
	mkdir -p $(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/dbus-1/services
	install -m644 $(BUILD_WORK)/dunst/org.knopwob.dunst.service \
		$(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/dbus-1/services/org.knopwob.dunst.service
	mkdir -p $(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/xdg/dunst
	install -m644 $(BUILD_WORK)/dunst/dunstrc \
		$(BUILD_STAGE)/dunst$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc/xdg/dunst/dunstrc
	$(call AFTER_BUILD,copy)
endif

dunst-package: dunst-stage
	rm -rf $(BUILD_DIST)/dunst
	mkdir -p $(BUILD_DIST)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/dunst/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,dunst,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,dunst,DEB_DUNST_V)
	rm -rf $(BUILD_DIST)/dunst

.PHONY: dunst dunst-package
