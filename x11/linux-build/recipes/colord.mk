ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# colord.mk — color management. mutter 46 requires libcolord unconditionally (meson.build:129).
# We build the REAL CLIENT library (CdClient D-Bus API + EDID parser + lcms2), NOT the daemon
# (-Ddaemon=false drops the gusb/polkit/seat deps). The only Linux coupling in the client lib is
# cd-edid.c's monitor-vendor-name lookup via udev's hwdb — colord supports a non-udev path for
# exactly this (`-Dpnp_ids=<file>` defines PNP_IDS so cd-edid.c reads a pnp.ids data file instead,
# returning NULL gracefully if absent; the path other non-Linux platforms use). With that, the
# client lib has NO udev/usb dependency and is fully functional on iOS (CdClient connects to a
# colord daemon if present, degrades gracefully if not — mutter handles both). Introspection off.

SUBPROJECTS    += colord
COLORD_VERSION := 1.4.7
DEB_COLORD_V   ?= $(COLORD_VERSION)+ios1

colord-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/colord/releases/colord-$(COLORD_VERSION).tar.xz)
	$(call EXTRACT_TAR,colord-$(COLORD_VERSION).tar.xz,colord-$(COLORD_VERSION),colord)
	# gusb (USB) + gudev (Linux udev) are daemon-only; the client libcolord (all mutter needs)
	# doesn't use them. Both are Linux-centric and pointless on iOS. Make them non-required so
	# the lib-only build (-Ddaemon=false) configures without the USB/udev dependency chain.
	sed -i "s/dependency('gusb', version : '>= 0.2.7')/dependency('gusb', version : '>= 0.2.7', required: false)/" $(BUILD_WORK)/colord/meson.build
	sed -i "s/dependency('gudev-1.0')/dependency('gudev-1.0', required: false)/" $(BUILD_WORK)/colord/meson.build
	sed -i "s/dependency('libudev')/dependency('libudev', required: false)/" $(BUILD_WORK)/colord/meson.build
	# cd-edid.c guards its udev *usage* with #ifndef PNP_IDS but leaves the #include <libudev.h>
	# unguarded (upstream oversight) — guard it to match, so the PNP_IDS (file) path needs no udev.
	sed -i 's|^#include <libudev.h>|#ifndef PNP_IDS\n#include <libudev.h>\n#endif|' $(BUILD_WORK)/colord/lib/colord/cd-edid.c
	# lib/colorhug is the ColorHug USB colorimeter driver (needs gusb); built unconditionally but
	# irrelevant on iOS and not used by the libcolord client lib mutter needs. Drop the subdir.
	sed -i "s/subdir('colorhug')/# colorhug (USB colorimeter) dropped on iOS: needs gusb, unused by libcolord/" $(BUILD_WORK)/colord/lib/meson.build
	# ld64 (Apple) rejects GNU ld's --version-script symbol-versioning. Drop it — exporting all
	# symbols is a harmless superset (mutter still resolves the public cd_* it links).
	sed -i "s|^vflag = .*|vflag = []|" $(BUILD_WORK)/colord/lib/colord/meson.build
	# The whole data/ subdir (cmf/illuminant/profiles/ref/ti1) generates color-science reference
	# files by RUNNING just-built target tools (cd-it8/cd-create-profile) — impossible cross. It's
	# daemon-side data; lib/colord (the client lib mutter needs) doesn't reference any of it. Drop it.
	sed -i "s/^subdir('data')/# data\/ dropped on iOS: generation runs target tools; unused by libcolord client/" $(BUILD_WORK)/colord/meson.build
	rm -rf $(BUILD_WORK)/colord/build && mkdir -p $(BUILD_WORK)/colord/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n \
	exe_wrapper = '/bin/true'\n" > $(BUILD_WORK)/colord/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/colord/.build_complete),)
colord:
	@echo "Using previously built colord."
else
colord: colord-setup glib2.0 lcms2
	cd $(BUILD_WORK)/colord/build && meson \
		--cross-file cross.txt \
		-Ddaemon=false \
		-Dpnp_ids=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/hwdata/pnp.ids \
		-Dsystemd=false \
		-Dudev_rules=false \
		-Dtests=false \
		-Dargyllcms_sensor=false \
		-Dbash_completion=false \
		-Dman=false \
		-Ddocs=false \
		-Dintrospection=false \
		-Dvapi=false \
		-Dsane=false \
		-Dlibcolordcompat=false \
		.. ; \
		DESTDIR="$(BUILD_STAGE)/colord" ninja install
	$(call AFTER_BUILD,copy)
endif

colord-package: colord-stage
	# colord.mk Package Structure (client library only)
	rm -rf $(BUILD_DIST)/libcolord2 $(BUILD_DIST)/libcolord-dev
	mkdir -p $(BUILD_DIST)/libcolord2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libcolord-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}

	# colord.mk Prep libcolord2 (runtime dylib)
	cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libcolord.2.dylib $(BUILD_DIST)/libcolord2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || \
		cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libcolord*.dylib $(BUILD_DIST)/libcolord2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# colord.mk Prep libcolord-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libcolord-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libcolord-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# colord.mk Sign
	$(call SIGN,libcolord2,general.xml)

	# colord.mk Make .debs
	$(call PACK,libcolord2,DEB_COLORD_V)
	$(call PACK,libcolord-dev,DEB_COLORD_V)

	# colord.mk Build cleanup
	rm -rf $(BUILD_DIST)/libcolord2 $(BUILD_DIST)/libcolord-dev

.PHONY: colord colord-package
