ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# at-spi2-core.mk — the AT-SPI accessibility stack: libatspi + the a11y bus (launcher +
# registryd) + the ATK bridge (at-spi2-atk was merged into this tree at 2.46, so ONE build
# yields both atspi-2 and atk-bridge-2.0). gnome-shell links atk-bridge-2.0 unconditionally.
# X11 support OFF — the shell target is the Wayland/iosc session, and this avoids the
# XTst/XEvIE keygrab surface. Mirrors recipes/gnome-desktop.mk (meson cross).

SUBPROJECTS    += at-spi2-core
ATSPI2_MAJOR_V := 2.52
ATSPI2_VERSION := $(ATSPI2_MAJOR_V).0
DEB_ATSPI2_V   ?= $(ATSPI2_VERSION)+ios2

at-spi2-core-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/at-spi2-core/$(ATSPI2_MAJOR_V)/at-spi2-core-$(ATSPI2_VERSION).tar.xz)
	$(call EXTRACT_TAR,at-spi2-core-$(ATSPI2_VERSION).tar.xz,at-spi2-core-$(ATSPI2_VERSION),at-spi2-core)
	mkdir -p $(BUILD_WORK)/at-spi2-core/build
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
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/at-spi2-core/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/at-spi2-core/.build_complete),)
at-spi2-core:
	@echo "Using previously built at-spi2-core."
else
at-spi2-core: at-spi2-core-setup dbus atk glib2.0
	cd $(BUILD_WORK)/at-spi2-core/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Ddocs=false \
		-Dx11=disabled \
		-Duse_systemd=false \
		-Dgtk2_atk_adaptor=false \
		-Ddefault_bus=dbus-daemon \
		-Ddbus_daemon=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dbus-daemon \
		..
	+ninja -C $(BUILD_WORK)/at-spi2-core/build
	+DESTDIR="$(BUILD_STAGE)/at-spi2-core" ninja -C $(BUILD_WORK)/at-spi2-core/build install
	$(call AFTER_BUILD,copy)
endif

at-spi2-core-package: at-spi2-core-stage
	rm -rf $(BUILD_DIST)/at-spi2-core $(BUILD_DIST)/libatspi2.0-0 \
		$(BUILD_DIST)/libatk-bridge2.0-0 $(BUILD_DIST)/at-spi2-core-dev \
		$(BUILD_DIST)/libatk1.0-0 $(BUILD_DIST)/libatk1.0-dev
	mkdir -p $(BUILD_DIST)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libatspi2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libatk-bridge2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/at-spi2-core-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libatk1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libatspi2.0-0 — the AT-SPI client library (versioned dylib only)
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatspi.*.dylib \
		$(BUILD_DIST)/libatspi2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libatk-bridge2.0-0 — the ATK->AT-SPI bridge gnome-shell/GTK3 load
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatk-bridge-2.0.*.dylib \
		$(BUILD_DIST)/libatk-bridge2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libatk1.0-0 — ATK was merged INTO at-spi2-core at 2.51/2.52, so this tree builds
	# libatk-1.0 2.52 (with atk_document_get_text_selections, the symbol the 2.52 bridge
	# needs). Ship it FROM HERE so ATK and the bridge are always ABI-consistent (the old
	# standalone atk.mk 2.38 deb lacked that symbol -> atk-bridge dyld-abort skew). The
	# 2.52.0+ios2 version supersedes the 2.38 standalone deb on upgrade.
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatk-1.0.0.dylib \
		$(BUILD_DIST)/libatk1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libatk1.0-dev — ATK headers + atk.pc + unversioned symlink (needed by the on-device
	# g-ir-scanner Atk-1.0 regen and GTK app builds). Owns atk-1.0/ headers + atk.pc so they
	# do NOT overlap at-spi2-core-dev (which strips them below; Breaks/Replaces in the control).
	mkdir -p $(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/atk-1.0 \
		$(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatk-1.0.dylib \
		$(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	mkdir -p $(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/atk.pc \
		$(BUILD_DIST)/libatk1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# at-spi2-core — the a11y bus: launcher + registryd + D-Bus/session data + schemas
	if [ -d "$(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec" ]; then \
		cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec $(BUILD_DIST)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)/etc" ]; then \
		cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)/etc $(BUILD_DIST)/at-spi2-core/$(MEMO_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc

	# at-spi2-core-dev — headers + .pc + unversioned symlinks (needed by the on-device
	# gnome-shell introspection build)
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/at-spi2-core-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/at-spi2-core-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatspi.dylib \
		$(BUILD_STAGE)/at-spi2-core/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libatk-bridge-2.0.dylib \
		$(BUILD_DIST)/at-spi2-core-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# at-spi2-core-dev no longer owns the ATK headers/atk.pc — those moved to libatk1.0-dev
	# (which it Depends on). Strip them from the -dev copy to avoid the dpkg file-overlap.
	rm -rf $(BUILD_DIST)/at-spi2-core-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/atk-1.0 \
		$(BUILD_DIST)/at-spi2-core-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/atk.pc

	$(call SIGN,at-spi2-core,general.xml)
	$(call SIGN,libatspi2.0-0,general.xml)
	$(call SIGN,libatk-bridge2.0-0,general.xml)
	$(call SIGN,libatk1.0-0,general.xml)
	$(call PACK,at-spi2-core,DEB_ATSPI2_V)
	$(call PACK,libatspi2.0-0,DEB_ATSPI2_V)
	$(call PACK,libatk-bridge2.0-0,DEB_ATSPI2_V)
	$(call PACK,at-spi2-core-dev,DEB_ATSPI2_V)
	$(call PACK,libatk1.0-0,DEB_ATSPI2_V)
	$(call PACK,libatk1.0-dev,DEB_ATSPI2_V)
	rm -rf $(BUILD_DIST)/at-spi2-core $(BUILD_DIST)/libatspi2.0-0 \
		$(BUILD_DIST)/libatk-bridge2.0-0 $(BUILD_DIST)/at-spi2-core-dev \
		$(BUILD_DIST)/libatk1.0-0 $(BUILD_DIST)/libatk1.0-dev

.PHONY: at-spi2-core at-spi2-core-package
