ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# fontconfig.mk — Ladybird leaf closure. BUMP 2.14.0 -> 2.17.1 (Ladybird pin). 2.17.1 STILL ships a
# pregenerated autotools configure (the gitlab release tarball), so we stay on configure — lower
# risk than the meson path and avoids the new Rust `fc-fontations` backend (meson-only). Needs
# freetype (Wave 2) + host gperf + SYSTEM expat (CFVER>=1700 ships libexpat; configure auto-detects
# -lexpat from the SDK sysroot, so we do NOT build expat). Drops the uuid dep (fontconfig no longer
# uses libuuid). Ships the runtime /var/jb/etc/fonts config data (fonts.conf + conf.d) in
# fontconfig-config so text renders with a real font path on-device. The driver wipes the staged
# gtk-era 2.14.0 shadow first. +ios1 marker.

SUBPROJECTS        += fontconfig
FONTCONFIG_VERSION := 2.17.1
DEB_FONTCONFIG_V   ?= $(FONTCONFIG_VERSION)+ios1

fontconfig-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/$(FONTCONFIG_VERSION)/fontconfig-$(FONTCONFIG_VERSION).tar.xz)
	# Stale-tree guard: wipe a mismatched (gtk-era 2.14.0) tree so 2.17.1 extracts.
	if [ -d $(BUILD_WORK)/fontconfig ] && ! grep -q "PACKAGE_VERSION='$(FONTCONFIG_VERSION)'" $(BUILD_WORK)/fontconfig/configure 2>/dev/null; then \
		echo "fontconfig: stale source tree (not $(FONTCONFIG_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/fontconfig $(BUILD_STAGE)/fontconfig; \
	fi
	$(call EXTRACT_TAR,fontconfig-$(FONTCONFIG_VERSION).tar.xz,fontconfig-$(FONTCONFIG_VERSION),fontconfig)

ifneq ($(wildcard $(BUILD_WORK)/fontconfig/.build_complete),)
fontconfig:
	@echo "Using previously built fontconfig."
else
fontconfig: fontconfig-setup gettext freetype
	cd $(BUILD_WORK)/fontconfig && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-docs \
		--disable-nls \
		--with-add-fonts="/System/Library/Fonts,/var/jb/share/fonts,~/Library/Fonts"
	+$(MAKE) -C $(BUILD_WORK)/fontconfig
	+$(MAKE) -C $(BUILD_WORK)/fontconfig install \
		DESTDIR=$(BUILD_STAGE)/fontconfig
	$(call AFTER_BUILD,copy)
endif

fontconfig-package: fontconfig-stage
	# fontconfig.mk Package Structure
	rm -rf $(BUILD_DIST)/fontconfig{,-config} \
		$(BUILD_DIST)/libfontconfig{1,-dev}
	mkdir -p $(BUILD_DIST)/fontconfig{,-config}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man \
		$(BUILD_DIST)/libfontconfig{1,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# fontconfig.mk Prep fontconfig (fc-* tools)
	cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	-cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1 $(BUILD_DIST)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	# fontconfig.mk Prep fontconfig-config (RUNTIME config data: /var/jb/etc/fonts + share/fontconfig)
	cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/{fontconfig,xml} $(BUILD_DIST)/fontconfig-config/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share
	cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)/etc $(BUILD_DIST)/fontconfig-config/$(MEMO_PREFIX)
	-cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man5 $(BUILD_DIST)/fontconfig-config/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	# fontconfig.mk Prep libfontconfig1
	cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfontconfig.1.dylib $(BUILD_DIST)/libfontconfig1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# fontconfig.mk Prep libfontconfig-dev
	cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{libfontconfig.dylib,pkgconfig} $(BUILD_DIST)/libfontconfig-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/fontconfig/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libfontconfig-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# fontconfig.mk Sign
	$(call SIGN,fontconfig,general.xml)
	$(call SIGN,libfontconfig1,general.xml)

	# fontconfig.mk Make .debs
	$(call PACK,fontconfig,DEB_FONTCONFIG_V)
	$(call PACK,fontconfig-config,DEB_FONTCONFIG_V)
	$(call PACK,libfontconfig1,DEB_FONTCONFIG_V)
	$(call PACK,libfontconfig-dev,DEB_FONTCONFIG_V)

	# fontconfig.mk Build cleanup
	rm -rf $(BUILD_DIST)/fontconfig{,-config} \
		$(BUILD_DIST)/libfontconfig{1,-dev}

.PHONY: fontconfig fontconfig-package
