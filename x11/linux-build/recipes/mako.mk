ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mako.mk — mako, a lightweight Wayland notification daemon (github.com/emersion/mako) that
# implements org.freedesktop.Notifications and draws notifications with pangocairo into wl_shm
# buffers mapped as zwlr_layer_surface_v1 (top/overlay layer). Pairs with the iosc compositor.
#
# STATUS: BLOCKED — mako's meson hard-requires an sd-bus provider (libsystemd | libelogind |
# basu). None exists on iOS, and basu (the standalone sd-bus fork) does NOT cross-compile to
# Darwin: its sd-bus source is architecturally Linux-bound (glibc <endian.h>, ELF-section error-
# map registration via __start_/__stop_ symbols, struct ucred / SCM_CREDENTIALS peer creds, kdbus,
# accept4/memfd_create, Linux capabilities, /proc). See recipes/basu.mk for the full, tested
# blocker catalogue. This recipe is kept as the intended integration for a future attempt (e.g. an
# elogind port, or a Mach-O rewrite of basu's error-map + a Darwin creds/endian/socket shim layer).
#
# Everything ELSE mako needs is already satisfied on procursus-vol-gtk-calc:
#   * cairo / pango / pangocairo / glib-2.0 / gobject-2.0 / gdk-pixbuf-2.0 (GTK4 stack)
#   * wayland(-client/-cursor) + wayland-protocols (1.38; mako needs >=1.32) for xdg-shell,
#     cursor-shape-v1, xdg-activation-v1, tablet-unstable-v2, and its bundled wlr-layer-shell.
#   * epoll-shim (iOS lacks timerfd_create/signalfd, so mako's meson pulls dependency('epoll-shim');
#     the shim ships the timerfd/signalfd/eventfd headers mako's event loop uses).
#   * `cc.find_library('rt')` — no librt on iOS (the -setup sed makes it non-required).
# The only missing piece is the sd-bus provider, hence the BLOCKED status.

SUBPROJECTS  += mako
MAKO_VERSION := 1.9.0
DEB_MAKO_V   ?= $(MAKO_VERSION)+ios1

mako-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/emersion/mako/releases/download/v$(MAKO_VERSION)/mako-$(MAKO_VERSION).tar.gz)
	$(call EXTRACT_TAR,mako-$(MAKO_VERSION).tar.gz,mako-$(MAKO_VERSION),mako)
	# iOS has no librt (clock_gettime is in libc); keep the Meson edit in the patch stack.
	$(call DO_PATCH,mako,mako,-p1)
	rm -rf $(BUILD_WORK)/mako/build && mkdir -p $(BUILD_WORK)/mako/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	c_args = ['-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/mako/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/mako/.build_complete),)
mako:
	@echo "Using previously built mako."
else
mako: mako-setup wayland wayland-protocols cairo pango gdk-pixbuf epoll-shim basu
	# protocol/meson.build resolves the native wayland-scanner via pkg-config (WAYLAND_NATIVE_ROOT),
	# same trick as slurp/foot/imv. sd-bus provider is pinned to basu; icons on (gdk-pixbuf present);
	# man pages off (no scdoc host tool); shell completions off.
	cd $(BUILD_WORK)/mako/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dsd-bus-provider=basu \
		-Dicons=enabled \
		-Dman-pages=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/mako/build
	+DESTDIR="$(BUILD_STAGE)/mako" ninja -C $(BUILD_WORK)/mako/build install
	$(call AFTER_BUILD,copy)
endif

mako-package: mako-stage
	rm -rf $(BUILD_DIST)/mako
	mkdir -p $(BUILD_DIST)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,mako,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,mako,DEB_MAKO_V)
	rm -rf $(BUILD_DIST)/mako

.PHONY: mako mako-package
