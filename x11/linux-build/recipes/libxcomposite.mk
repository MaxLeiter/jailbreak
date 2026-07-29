ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Needed by mutter 46: have_x11=true is hardcoded there, so the X11 client path always
# links -lXcomposite. Depends on libxfixes because Composite uses Region.

SUBPROJECTS          += libxcomposite
LIBXCOMPOSITE_VERSION := 0.4.6
DEB_LIBXCOMPOSITE_V   ?= $(LIBXCOMPOSITE_VERSION)+ios1

libxcomposite-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xorg.freedesktop.org/archive/individual/lib/libXcomposite-$(LIBXCOMPOSITE_VERSION).tar.gz{$(comma).sig})
	$(call PGP_VERIFY,libXcomposite-$(LIBXCOMPOSITE_VERSION).tar.gz)
	$(call EXTRACT_TAR,libXcomposite-$(LIBXCOMPOSITE_VERSION).tar.gz,libXcomposite-$(LIBXCOMPOSITE_VERSION),libxcomposite)

ifneq ($(wildcard $(BUILD_WORK)/libxcomposite/.build_complete),)
libxcomposite:
	@echo "Using previously built libxcomposite."
else
libxcomposite: libxcomposite-setup libx11 xorgproto libxfixes
	cd $(BUILD_WORK)/libxcomposite && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS)
	+$(MAKE) -C $(BUILD_WORK)/libxcomposite
	+$(MAKE) -C $(BUILD_WORK)/libxcomposite install \
		DESTDIR=$(BUILD_STAGE)/libxcomposite
	$(call AFTER_BUILD,copy)
endif

libxcomposite-package: libxcomposite-stage
	rm -rf $(BUILD_DIST)/libxcomposite{1,-dev}
	mkdir -p $(BUILD_DIST)/libxcomposite1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxcomposite-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}

	cp -a $(BUILD_STAGE)/libxcomposite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libXcomposite.1.dylib $(BUILD_DIST)/libxcomposite1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxcomposite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libXcomposite.1.dylib) $(BUILD_DIST)/libxcomposite-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxcomposite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxcomposite-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libxcomposite1,general.xml)

	$(call PACK,libxcomposite1,DEB_LIBXCOMPOSITE_V)
	$(call PACK,libxcomposite-dev,DEB_LIBXCOMPOSITE_V)

	rm -rf $(BUILD_DIST)/libxcomposite{1,-dev}

.PHONY: libxcomposite libxcomposite-package
