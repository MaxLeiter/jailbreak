ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mutter 46 requires libcolord unconditionally (meson.build:129). We build only the client lib
# (-Ddaemon=false, drops gusb/polkit/seat deps). Its one Linux coupling is cd-edid.c's monitor-
# vendor lookup via udev's hwdb; -Dpnp_ids=<file> makes it read a flat pnp.ids file instead
# (NULL if absent), which drops the udev/usb dependency entirely.

SUBPROJECTS    += colord
COLORD_VERSION := 1.4.7
DEB_COLORD_V   ?= $(COLORD_VERSION)+ios1

colord-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.freedesktop.org/software/colord/releases/colord-$(COLORD_VERSION).tar.xz)
	$(call EXTRACT_TAR,colord-$(COLORD_VERSION).tar.xz,colord-$(COLORD_VERSION),colord)
	$(call DO_PATCH,colord,colord,-p1)
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
	rm -rf $(BUILD_DIST)/libcolord2 $(BUILD_DIST)/libcolord-dev
	mkdir -p $(BUILD_DIST)/libcolord2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libcolord-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}

	cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libcolord.2.dylib $(BUILD_DIST)/libcolord2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || \
		cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libcolord*.dylib $(BUILD_DIST)/libcolord2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libcolord-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/colord/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libcolord-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	$(call SIGN,libcolord2,general.xml)

	$(call PACK,libcolord2,DEB_COLORD_V)
	$(call PACK,libcolord-dev,DEB_COLORD_V)

	rm -rf $(BUILD_DIST)/libcolord2 $(BUILD_DIST)/libcolord-dev

.PHONY: colord colord-package
