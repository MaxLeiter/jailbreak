ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libdisplay-info 0.2.0, the REAL EDID/DisplayID parser (KWin 6.7 requires >= 0.2.0 and uses di_info_get_hdr_static_metadata,
# di_edid_get_*, di_displayid_* ...). Replaces the 0.1.1 link-only shim (kept as libdisplay-info.mk.shim-0.1.1.txt) now that
# the API surface it would have to stub is large. Pure C, meson, no required dependencies.

# ios2: libdisplay-info-dev Replaces libdisplay-info1 (<< 0.2.0). The 0.1.1 shim (libdisplay-info1) shipped the
# unversioned libdisplay-info.dylib itself; the dev symlink now lives here, in -dev, where it belongs, and dpkg refused to
# unpack it over the still-installed libdisplay-info1 0.1.1+ios1 during the KDE 6.7 upgrade.
SUBPROJECTS += libdisplay-info
LIBDISPLAYINFO_VERSION := 0.2.0
DEB_LIBDISPLAYINFO_V   ?= $(LIBDISPLAYINFO_VERSION)+ios2

libdisplay-info-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/emersion/libdisplay-info/-/archive/$(LIBDISPLAYINFO_VERSION)/libdisplay-info-$(LIBDISPLAYINFO_VERSION).tar.bz2)
	$(call EXTRACT_TAR,libdisplay-info-$(LIBDISPLAYINFO_VERSION).tar.bz2,libdisplay-info-$(LIBDISPLAYINFO_VERSION),libdisplay-info)
	# ld64 has no --version-script: drop the ELF-only symbol map link args (the library exports its public API by default).
	sed -i '/link_args: symbols_flag,/d;/link_depends: symbols_file,/d' $(BUILD_WORK)/libdisplay-info/meson.build
	mkdir -p $(BUILD_WORK)/libdisplay-info/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libdisplay-info/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libdisplay-info/.build_complete),)
libdisplay-info:
	@echo "Using previously built libdisplay-info."
else
libdisplay-info: libdisplay-info-setup
	cd $(BUILD_WORK)/libdisplay-info/build && meson \
		--cross-file cross.txt \
		-Ddefault_library=shared \
		..
	+ninja -C $(BUILD_WORK)/libdisplay-info/build
	+DESTDIR="$(BUILD_STAGE)/libdisplay-info" ninja -C $(BUILD_WORK)/libdisplay-info/build install
	$(call AFTER_BUILD,copy)
endif

libdisplay-info-package: libdisplay-info-stage
	rm -rf $(BUILD_DIST)/libdisplay-info2 $(BUILD_DIST)/libdisplay-info-dev
	mkdir -p $(BUILD_DIST)/libdisplay-info2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libdisplay-info-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdisplay-info.*.dylib \
		$(BUILD_DIST)/libdisplay-info2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libdisplay-info-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdisplay-info.dylib \
		$(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libdisplay-info-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	$(call SIGN,libdisplay-info2,general.xml)
	$(call SIGN,libdisplay-info-dev,general.xml)
	$(call PACK,libdisplay-info2,DEB_LIBDISPLAYINFO_V)
	$(call PACK,libdisplay-info-dev,DEB_LIBDISPLAYINFO_V)
	rm -rf $(BUILD_DIST)/libdisplay-info2 $(BUILD_DIST)/libdisplay-info-dev

.PHONY: libdisplay-info libdisplay-info-package
