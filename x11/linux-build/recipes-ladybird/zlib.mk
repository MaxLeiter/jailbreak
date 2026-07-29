ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Ladybird requires classic zlib, not Procursus's zlib-ng — do not substitute.

SUBPROJECTS   += zlib
ZLIB_VERSION  := 1.3.1
DEB_ZLIB_V    ?= $(ZLIB_VERSION)+ios1

zlib-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/madler/zlib/releases/download/v$(ZLIB_VERSION)/zlib-$(ZLIB_VERSION).tar.gz)
	$(call EXTRACT_TAR,zlib-$(ZLIB_VERSION).tar.gz,zlib-$(ZLIB_VERSION),zlib)

ifneq ($(wildcard $(BUILD_WORK)/zlib/.build_complete),)
zlib:
	@echo "Using previously built zlib."
else
zlib: zlib-setup
	cd $(BUILD_WORK)/zlib && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DZLIB_BUILD_EXAMPLES=OFF
	+$(MAKE) -C $(BUILD_WORK)/zlib
	+$(MAKE) -C $(BUILD_WORK)/zlib install \
		DESTDIR=$(BUILD_STAGE)/zlib
	$(call AFTER_BUILD,copy)
endif

zlib-package: .SHELLFLAGS=-O extglob -c
zlib-package: zlib-stage
	# zlib.mk Package Structure
	rm -rf $(BUILD_DIST)/libz1 $(BUILD_DIST)/zlib-dev
	mkdir -p $(BUILD_DIST)/libz1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/zlib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# zlib.mk Prep libz1 (runtime: versioned dylib only)
	cp -a $(BUILD_STAGE)/zlib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libz.[0-9]*.dylib $(BUILD_DIST)/libz1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# zlib.mk Prep zlib-dev (headers, static, unversioned symlink, pkgconfig)
	# zlib's CMake installs zlib.pc under share/pkgconfig; normalize it into lib/pkgconfig.
	mkdir -p $(BUILD_DIST)/zlib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/zlib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/zlib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/zlib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libz.dylib $(BUILD_DIST)/zlib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/zlib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libz.a $(BUILD_DIST)/zlib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/zlib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/pkgconfig/zlib.pc $(BUILD_DIST)/zlib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# zlib.mk Sign
	$(call SIGN,libz1,general.xml)

	# zlib.mk Make .debs
	$(call PACK,libz1,DEB_ZLIB_V)
	$(call PACK,zlib-dev,DEB_ZLIB_V)

	# zlib.mk Build cleanup
	rm -rf $(BUILD_DIST)/libz1 $(BUILD_DIST)/zlib-dev

.PHONY: zlib zlib-package
