ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# PGP/S/MIME and IDN disabled: those pull in GpgME/libidn dependency chains not needed
# for the pkg-config/header surface Geary requires.

SUBPROJECTS   += gmime
GMIME_MAJOR_V := 3.2
GMIME_VERSION := $(GMIME_MAJOR_V).7
DEB_GMIME_V   ?= $(GMIME_VERSION)+ios1

gmime-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gmime/$(GMIME_MAJOR_V)/gmime-$(GMIME_VERSION).tar.xz)
	$(call EXTRACT_TAR,gmime-$(GMIME_VERSION).tar.xz,gmime-$(GMIME_VERSION),gmime)
	printf '#define ICONV_ISO_INT_FORMAT "iso-%%u-%%u"\n#define ICONV_ISO_STR_FORMAT "iso-%%u-%%s"\n#define ICONV_SHIFT_JIS "shift-jis"\n#define ICONV_10646 "UCS-4BE"\n' \
		> $(BUILD_WORK)/gmime/iconv-detect.h

ifneq ($(wildcard $(BUILD_WORK)/gmime/.build_complete),)
gmime:
	@echo "Using previously built gmime."
else
gmime: gmime-setup glib2.0
	cd $(BUILD_WORK)/gmime && ac_cv_have_iconv_detect_h=yes ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-crypto \
		--without-libidn \
		--disable-introspection \
		--enable-vala=no \
		--with-libiconv=native
	+$(MAKE) -C $(BUILD_WORK)/gmime
	+$(MAKE) -C $(BUILD_WORK)/gmime install DESTDIR=$(BUILD_STAGE)/gmime
	$(call AFTER_BUILD,copy)
endif

gmime-package: gmime-stage
	rm -rf $(BUILD_DIST)/libgmime-3.0-0 $(BUILD_DIST)/libgmime-3.0-dev
	mkdir -p $(BUILD_DIST)/libgmime-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgmime-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gmime/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgmime-3.0.*.dylib \
		$(BUILD_DIST)/libgmime-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/gmime/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libgmime-3.0.*.dylib) \
		$(BUILD_DIST)/libgmime-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gmime/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgmime-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libgmime-3.0-0,general.xml)
	$(call PACK,libgmime-3.0-0,DEB_GMIME_V)
	$(call PACK,libgmime-3.0-dev,DEB_GMIME_V)
	rm -rf $(BUILD_DIST)/libgmime-3.0-0 $(BUILD_DIST)/libgmime-3.0-dev

.PHONY: gmime gmime-package
