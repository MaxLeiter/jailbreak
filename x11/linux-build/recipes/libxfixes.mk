ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Bumped to 6.0.1 for mutter 46, which needs xfixes >= 6 (mainline ships 5.0.3).
# ABI-compatible soname, so existing consumers keep working.

SUBPROJECTS       += libxfixes
LIBXFIXES_VERSION := 6.0.1
DEB_LIBXFIXES_V   ?= $(LIBXFIXES_VERSION)+ios1

libxfixes-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://www.x.org/releases/individual/lib/libXfixes-$(LIBXFIXES_VERSION).tar.xz)
	$(call EXTRACT_TAR,libXfixes-$(LIBXFIXES_VERSION).tar.xz,libXfixes-$(LIBXFIXES_VERSION),libxfixes)

ifneq ($(wildcard $(BUILD_WORK)/libxfixes/.build_complete),)
libxfixes:
	@echo "Using previously built libxfixes."
else
libxfixes: libxfixes-setup libx11 xorgproto
	cd $(BUILD_WORK)/libxfixes && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS)
	+$(MAKE) -C $(BUILD_WORK)/libxfixes
	+$(MAKE) -C $(BUILD_WORK)/libxfixes install \
		DESTDIR=$(BUILD_STAGE)/libxfixes
	$(call AFTER_BUILD,copy)
endif

libxfixes-package: libxfixes-stage
	rm -rf $(BUILD_DIST)/libxfixes3 $(BUILD_DIST)/libxfixes-dev
	mkdir -p $(BUILD_DIST)/libxfixes3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxfixes-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}
	cp -a $(BUILD_STAGE)/libxfixes/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libXfixes.3.dylib $(BUILD_DIST)/libxfixes3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/libxfixes/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libXfixes.3.dylib) $(BUILD_DIST)/libxfixes-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/libxfixes/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxfixes-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	$(call SIGN,libxfixes3,general.xml)
	$(call PACK,libxfixes3,DEB_LIBXFIXES_V)
	$(call PACK,libxfixes-dev,DEB_LIBXFIXES_V)
	rm -rf $(BUILD_DIST)/libxfixes3 $(BUILD_DIST)/libxfixes-dev

.PHONY: libxfixes libxfixes-package
