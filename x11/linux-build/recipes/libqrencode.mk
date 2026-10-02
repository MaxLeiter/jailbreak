ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libqrencode.mk - QR code encoder, REQUIRED by KF6 Prison 6.30 (Prison's QR generator is its core feature; the 6.3
# lane built without it only because Prison was not in the subset). Library only: no tools (libpng), no tests.

SUBPROJECTS += libqrencode
LIBQRENCODE_VERSION = 4.1.1
DEB_LIBQRENCODE_V ?= $(LIBQRENCODE_VERSION)+ios1

libqrencode-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/fukuchi/libqrencode/archive/refs/tags/v$(LIBQRENCODE_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(LIBQRENCODE_VERSION).tar.gz,libqrencode-$(LIBQRENCODE_VERSION),libqrencode)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/libqrencode/.build_complete),)
libqrencode:
	@echo "Using previously built libqrencode."
else
libqrencode: libqrencode-setup
	rm -rf $(BUILD_WORK)/libqrencode/build
	mkdir -p $(BUILD_WORK)/libqrencode/build
	cd $(BUILD_WORK)/libqrencode/build && cmake .. \
		-G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DWITH_TOOLS=NO \
		-DWITH_TESTS=NO \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5
	+ninja -C $(BUILD_WORK)/libqrencode/build
	+DESTDIR="$(BUILD_STAGE)/libqrencode" ninja -C $(BUILD_WORK)/libqrencode/build install
	$(call AFTER_BUILD,copy)
endif

libqrencode-package: libqrencode-stage
	rm -rf $(BUILD_DIST)/libqrencode4 $(BUILD_DIST)/libqrencode-dev
	mkdir -p $(BUILD_DIST)/libqrencode4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libqrencode-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libqrencode/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libqrencode.*.dylib \
		$(BUILD_DIST)/libqrencode4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libqrencode/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libqrencode-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libqrencode/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libqrencode.dylib $(BUILD_DIST)/libqrencode-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libqrencode/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libqrencode-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/libqrencode/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake" ]; then \
		cp -a $(BUILD_STAGE)/libqrencode/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake $(BUILD_DIST)/libqrencode-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; fi
	$(call SIGN,libqrencode4,general.xml)
	$(call SIGN,libqrencode-dev,general.xml)
	$(call PACK,libqrencode4,DEB_LIBQRENCODE_V)
	$(call PACK,libqrencode-dev,DEB_LIBQRENCODE_V)
	rm -rf $(BUILD_DIST)/libqrencode4 $(BUILD_DIST)/libqrencode-dev

.PHONY: libqrencode libqrencode-package
