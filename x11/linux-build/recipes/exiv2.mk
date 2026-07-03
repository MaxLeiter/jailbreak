ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# exiv2.mk - image metadata library for Gwenview.

SUBPROJECTS += exiv2
EXIV2_VERSION = 0.28.3
DEB_EXIV2_V ?= $(EXIV2_VERSION)+ios2

exiv2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/Exiv2/exiv2/archive/refs/tags/v$(EXIV2_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(EXIV2_VERSION).tar.gz,exiv2-$(EXIV2_VERSION),exiv2)

ifneq ($(wildcard $(BUILD_WORK)/exiv2/.build_complete),)
exiv2:
	@echo "Using previously built exiv2."
else
exiv2: exiv2-setup
	mkdir -p $(BUILD_WORK)/exiv2/build
	cd $(BUILD_WORK)/exiv2/build && cmake .. \
		-G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DEXIV2_BUILD_EXIV2_COMMAND=OFF \
		-DEXIV2_BUILD_SAMPLES=OFF \
		-DEXIV2_BUILD_UNIT_TESTS=OFF \
		-DEXIV2_BUILD_FUZZ_TESTS=OFF \
		-DEXIV2_BUILD_DOC=OFF \
		-DEXIV2_ENABLE_NLS=OFF \
		-DEXIV2_ENABLE_XMP=OFF \
		-DEXIV2_ENABLE_EXTERNAL_XMP=OFF \
		-DEXIV2_ENABLE_PNG=ON \
		-DEXIV2_ENABLE_BMFF=ON \
		-DEXIV2_ENABLE_BROTLI=OFF \
		-DEXIV2_ENABLE_VIDEO=OFF \
		-DEXIV2_ENABLE_INIH=OFF \
		-DEXIV2_ENABLE_WEBREADY=OFF
	+ninja -C $(BUILD_WORK)/exiv2/build
	+DESTDIR="$(BUILD_STAGE)/exiv2" ninja -C $(BUILD_WORK)/exiv2/build install
	$(call AFTER_BUILD,copy)
endif

exiv2-package: exiv2-stage
	rm -rf $(BUILD_DIST)/libexiv2-28 $(BUILD_DIST)/libexiv2-dev
	mkdir -p $(BUILD_DIST)/libexiv2-28/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libexiv2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/exiv2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexiv2.[0-9]*.dylib \
		$(BUILD_DIST)/libexiv2-28/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	for d in include lib/cmake lib/pkgconfig; do \
		if [ -e "$(BUILD_STAGE)/exiv2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/libexiv2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/exiv2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/libexiv2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	cp -a $(BUILD_STAGE)/exiv2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexiv2.dylib \
		$(BUILD_DIST)/libexiv2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	rm -rf $(BUILD_DIST)/libexiv2-28/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/libexiv2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share
	$(call SIGN,libexiv2-28,general.xml)
	$(call PACK,libexiv2-28,DEB_EXIV2_V)
	$(call PACK,libexiv2-dev,DEB_EXIV2_V)
	rm -rf $(BUILD_DIST)/libexiv2-28 $(BUILD_DIST)/libexiv2-dev

.PHONY: exiv2 exiv2-package
