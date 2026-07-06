ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# poppler-qt6.mk — Qt6 frontend split for Okular. This builds Poppler from the
# same upstream version as poppler.mk but packages only the Qt6 binding and its
# development files. The core libpoppler140 package remains owned by poppler.mk.

SUBPROJECTS           += poppler-qt6
POPPLER_QT6_VERSION   := 24.08.0
POPPLER_QT6_SOV       := 3
DEB_POPPLER_QT6_V     ?= $(POPPLER_QT6_VERSION)+qt6ios1+ios1

poppler-qt6-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://poppler.freedesktop.org/poppler-$(POPPLER_QT6_VERSION).tar.xz)
	$(call EXTRACT_TAR,poppler-$(POPPLER_QT6_VERSION).tar.xz,poppler-$(POPPLER_QT6_VERSION),poppler-qt6)
	sed -i '/find_soft_mandatory_package(ENABLE_QT6 Qt6Test/d' $(BUILD_WORK)/poppler-qt6/CMakeLists.txt
	sed -i '/add_subdirectory(tests)/s/^/# ios-no-qt6-tests: /' $(BUILD_WORK)/poppler-qt6/qt6/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/poppler-qt6/.build_complete),)
poppler-qt6:
	@echo "Using previously built poppler-qt6."
else
poppler-qt6: poppler-qt6-setup
	rm -rf $(BUILD_WORK)/poppler-qt6/build
	cd $(BUILD_WORK)/poppler-qt6 && cmake -G Ninja -B build \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DBUILD_SHARED_LIBS=ON \
		-DENABLE_QT6=ON \
		-DENABLE_GLIB=OFF \
		-DENABLE_GOBJECT_INTROSPECTION=OFF \
		-DENABLE_QT5=OFF \
		-DENABLE_CPP=OFF \
		-DENABLE_UTILS=OFF \
		-DBUILD_GTK_TESTS=OFF \
		-DBUILD_QT5_TESTS=OFF \
		-DBUILD_QT6_TESTS=OFF \
		-DBUILD_CPP_TESTS=OFF \
		-DBUILD_MANUAL_TESTS=OFF \
		-DENABLE_BOOST=OFF \
		-DENABLE_NSS3=OFF \
		-DENABLE_GPGME=OFF \
		-DENABLE_LIBCURL=OFF \
		-DENABLE_LCMS=OFF \
		-DENABLE_LIBTIFF=OFF \
		-DENABLE_LIBOPENJPEG=none \
		-DENABLE_DCTDECODER=libjpeg \
		-DENABLE_ZLIB_UNCOMPRESS=OFF
	+ninja -C $(BUILD_WORK)/poppler-qt6/build
	+DESTDIR="$(BUILD_STAGE)/poppler-qt6" ninja -C $(BUILD_WORK)/poppler-qt6/build install
	$(call AFTER_BUILD,copy)
endif

poppler-qt6-package: poppler-qt6-stage
	rm -rf $(BUILD_DIST)/libpoppler-qt6-$(POPPLER_QT6_SOV) $(BUILD_DIST)/libpoppler-qt6-dev
	mkdir -p $(BUILD_DIST)/libpoppler-qt6-$(POPPLER_QT6_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpoppler-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/poppler-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpoppler-qt6.*.dylib \
		$(BUILD_DIST)/libpoppler-qt6-$(POPPLER_QT6_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/poppler-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libpoppler-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in lib/cmake lib/pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/poppler-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/libpoppler-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
			cp -a "$(BUILD_STAGE)/poppler-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"/*Poppler* \
				"$(BUILD_DIST)/libpoppler-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"/ 2>/dev/null || true; \
		fi; \
	done
	cp -a $(BUILD_STAGE)/poppler-qt6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpoppler-qt6.dylib \
		$(BUILD_DIST)/libpoppler-qt6-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	$(call SIGN,libpoppler-qt6-$(POPPLER_QT6_SOV),general.xml)
	$(call SIGN,libpoppler-qt6-dev,general.xml)
	$(call PACK,libpoppler-qt6-$(POPPLER_QT6_SOV),DEB_POPPLER_QT6_V)
	$(call PACK,libpoppler-qt6-dev,DEB_POPPLER_QT6_V)
	rm -rf $(BUILD_DIST)/libpoppler-qt6-$(POPPLER_QT6_SOV) $(BUILD_DIST)/libpoppler-qt6-dev

.PHONY: poppler-qt6 poppler-qt6-package
