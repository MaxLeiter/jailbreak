ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# dunst instead of mako: mako hard-requires an sd-bus provider (libsystemd | basu), and basu
# does not cross-compile to Darwin (see recipes/basu.mk). dunst speaks D-Bus via GDBus (part of
# GLib) instead — no libdbus, no sd-bus at all; just needs a session bus at runtime.
#
# Needs wayland-protocols >=1.32 for cursor-shape (our tree ships 1.38). Protocol headers are
# generated at build time by the host wayland-scanner over the cross-staged protocol XML.
#
# Plain Makefile build (config.mk knobs, not meson/cmake). WAYLAND=1 X11=0 drops the whole
# libx11/xrandr/xinerama closure; DUNSTIFY=0 skips the libnotify helper so we avoid that dep.
# VERSION is pinned because the release tarball has no git.
#
# Portability fixes:
#  - config.mk's DEFAULT_LDFLAGS carries -lrt (no librt on iOS; clock_gettime is in libc) —
#    sed'd out in the setup rule.
#  - st_mtim aliased to Darwin's st_mtimespec; wordexp()/wordfree() (unavailable on iOS)
#    replaced with a GLib config-path expansion helper.
#  - src/input.c and the wayland source files include <linux/input-event-codes.h> for BTN_*
#    codes — the driver drops in the same shim foot/imv/slurp use.
#  - CLOCK_BOOTTIME is already #ifdef __linux__ guarded (falls back to CLOCK_MONOTONIC).

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
	# Native wayland-scanner (via WAYLAND_NATIVE_ROOT on PATH), since the cross-built binary
	# can't run on the host. cross-pkg-config's pkgdatadir returns the logical /var/jb path,
	# not the real on-disk build_base path, so point DATA_DIR_WAYLAND_PROTOCOLS there directly.
	cd $(BUILD_WORK)/dunst && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" $(MAKE) wayland-protocols \
			WAYLAND=1 X11=0 \
			PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config \
			DATA_DIR_WAYLAND_PROTOCOLS=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/wayland-protocols
	# CC is the cross wrapper (cc-nounused, from build-wayland-utils.sh); cross-pkg-config
	# resolves gio/pango/cairo/wayland from build_base.
	cd $(BUILD_WORK)/dunst && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" $(MAKE) dunst service-dbus \
			WAYLAND=1 X11=0 DUNSTIFY=0 SYSTEMD=0 COMPLETIONS=0 \
			VERSION=$(DUNST_VERSION) \
			CC="$(CC)" \
			EXTRA_CFLAGS="-Wno-error" \
			PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config \
			BINDIR=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
			DATA_DIR_WAYLAND_PROTOCOLS=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/wayland-protocols
	# pango's .pc adds -lintl, which the linker resolves to the unversioned libintl.dylib
	# symlink (a -dev-only artifact) — that install_name doesn't exist at runtime (libintl8
	# ships only libintl.8.dylib). Retarget before SIGN (install_name_tool invalidates the
	# ad-hoc signature; SIGN re-covers it).
	$(I_N_T) -change @rpath/libintl.dylib @rpath/libintl.8.dylib $(BUILD_WORK)/dunst/dunst
	# Stage by hand rather than `make install`, whose install-dunst pulls in the pod2man doc chain.
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
