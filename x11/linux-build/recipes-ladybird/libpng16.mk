ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS      += libpng16
LIBPNG16_VERSION := 1.6.50
DEB_LIBPNG16_V   ?= $(LIBPNG16_VERSION)+ios1

libpng16-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://downloads.sourceforge.net/libpng/libpng-$(LIBPNG16_VERSION).tar.xz)
	# Stale-tree guard (ICU/libxml2 lesson): wipe a mismatched (gtk-era 1.6.37) source tree so the
	# 1.6.50 source actually extracts instead of EXTRACT_TAR no-op'ing over the old one.
	if [ -d $(BUILD_WORK)/libpng16 ] && ! grep -q "PNG_LIBPNG_VER_STRING \"$(LIBPNG16_VERSION)\"" $(BUILD_WORK)/libpng16/png.h 2>/dev/null; then \
		echo "libpng16: stale source tree (not $(LIBPNG16_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/libpng16 $(BUILD_STAGE)/libpng16; \
	fi
	$(call EXTRACT_TAR,libpng-$(LIBPNG16_VERSION).tar.xz,libpng-$(LIBPNG16_VERSION),libpng16)
	# Ladybird's LibImageDecoders FATAL_ERRORs without APNG support (png_get_acTL/
	# png_get_next_frame_fcTL); stock libpng doesn't have it, so apply the libpng-apng patch.
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://downloads.sourceforge.net/project/libpng-apng/libpng16/$(LIBPNG16_VERSION)/libpng-$(LIBPNG16_VERSION)-apng.patch.gz)
	if [ ! -f $(BUILD_WORK)/libpng16/.apng_applied ]; then \
		gunzip -c $(BUILD_SOURCE)/libpng-$(LIBPNG16_VERSION)-apng.patch.gz | patch -d $(BUILD_WORK)/libpng16 -p1 && \
		touch $(BUILD_WORK)/libpng16/.apng_applied ; \
	fi

ifneq ($(wildcard $(BUILD_WORK)/libpng16/.build_complete),)
libpng16:
	@echo "Using previously built libpng16."
else
libpng16: libpng16-setup zlib
	cd $(BUILD_WORK)/libpng16 && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS)
	+$(MAKE) -C $(BUILD_WORK)/libpng16
	+$(MAKE) -C $(BUILD_WORK)/libpng16 install \
		DESTDIR=$(BUILD_STAGE)/libpng16
	$(call AFTER_BUILD,copy)
endif

libpng16-package: .SHELLFLAGS=-O extglob -c
libpng16-package: libpng16-stage
	# libpng16.mk Package Structure
	rm -rf $(BUILD_DIST)/libpng16-{16,dev,tools}
	mkdir -p $(BUILD_DIST)/libpng16-16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpng16-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,lib} \
		$(BUILD_DIST)/libpng16-tools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# libpng16.mk Prep libpng16-16
	cp -a $(BUILD_STAGE)/libpng16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpng16.16.dylib $(BUILD_DIST)/libpng16-16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libpng16.mk Prep libpng16-dev
	cp -a $(BUILD_STAGE)/libpng16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/*-config $(BUILD_DIST)/libpng16-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/libpng16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libpng16.16.dylib) $(BUILD_DIST)/libpng16-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libpng16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libpng16-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libpng16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libpng16-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# libpng16.mk Prep libpng16-tools
	cp -a $(BUILD_STAGE)/libpng16/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/!(*-config) $(BUILD_DIST)/libpng16-tools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# libpng16.mk Sign
	$(call SIGN,libpng16-16,general.xml)
	$(call SIGN,libpng16-tools,general.xml)

	# libpng16.mk Make .debs
	$(call PACK,libpng16-16,DEB_LIBPNG16_V)
	$(call PACK,libpng16-dev,DEB_LIBPNG16_V)
	$(call PACK,libpng16-tools,DEB_LIBPNG16_V)

	# libpng16.mk Build cleanup
	rm -rf $(BUILD_DIST)/libpng16-{16,dev,tools}

.PHONY: libpng16 libpng16-package
