ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS += quazip-qt6
QUAZIP_QT6_VERSION := 1.4
DEB_QUAZIP_QT6_V ?= $(QUAZIP_QT6_VERSION)+ios1

quazip-qt6-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/stachenov/quazip/archive/refs/tags/v$(QUAZIP_QT6_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(QUAZIP_QT6_VERSION).tar.gz,quazip-$(QUAZIP_QT6_VERSION),quazip-qt6)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/quazip-qt6/.build_complete),)
quazip-qt6:
	@echo "Using previously built QuaZip Qt 6."
else
quazip-qt6: quazip-qt6-setup
	rm -rf $(BUILD_WORK)/quazip-qt6/build
	mkdir -p $(BUILD_WORK)/quazip-qt6/build
	cd $(BUILD_WORK)/quazip-qt6/build && cmake .. -G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DQUAZIP_QT_MAJOR_VERSION=6 \
		-DQUAZIP_ENABLE_TESTS=OFF \
		-DQUAZIP_USE_QT_ZLIB=OFF
	+ninja -C $(BUILD_WORK)/quazip-qt6/build
	+DESTDIR="$(BUILD_STAGE)/quazip-qt6" ninja -C $(BUILD_WORK)/quazip-qt6/build install
	$(call AFTER_BUILD,copy)
endif

quazip-qt6-package: quazip-qt6-stage
	rm -rf $(BUILD_DIST)/libquazip1-qt6 $(BUILD_DIST)/libquazip1-qt6-dev
	mkdir -p $(BUILD_DIST)/libquazip1-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libquazip1-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/quazip-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libquazip1-qt6.*.dylib \
		$(BUILD_DIST)/libquazip1-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/quazip-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libquazip1-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	mkdir -p $(BUILD_DIST)/libquazip1-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/quazip-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libquazip1-qt6.*.dylib) \
		$(BUILD_DIST)/libquazip1-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	$(call SIGN,libquazip1-qt6,general.xml)
	$(call PACK,libquazip1-qt6,DEB_QUAZIP_QT6_V)
	$(call PACK,libquazip1-qt6-dev,DEB_QUAZIP_QT6_V)
	rm -rf $(BUILD_DIST)/libquazip1-qt6 $(BUILD_DIST)/libquazip1-qt6-dev

.PHONY: quazip-qt6 quazip-qt6-package
