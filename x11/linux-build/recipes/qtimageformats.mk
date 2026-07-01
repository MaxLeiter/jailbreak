ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qtimageformats.mk — extra QImage format plugins (tiff, webp, tga, icns, wbmp) for
# rootless iOS. Icon/wallpaper loading coverage for Plasma theming; single runtime deb,
# no public headers. tiff + webp use Qt's BUNDLED 3rdparty copies (system_* OFF) so the
# package is self-contained — the alternative would grow our repo a libtiff/libwebp deb
# family for one plugin each, and hand-written control deps have bitten before
# (x11-procursus-libsqlite3-naming). mng/jasper have no bundled copy: OFF.
# Shared Apple/Darwin flags + MACOS-condition fix: qt6-common.mk (rationale in qtbase.mk).

SUBPROJECTS            += qtimageformats
QTIMAGEFORMATS_VERSION := 6.6.3
DEB_QTIMAGEFORMATS_V   ?= $(QTIMAGEFORMATS_VERSION)

qtimageformats-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtimageformats))
	$(call EXTRACT_TAR,qtimageformats-everywhere-src-$(QTIMAGEFORMATS_VERSION).tar.xz,qtimageformats-everywhere-src-$(QTIMAGEFORMATS_VERSION),qtimageformats)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtimageformats)

ifneq ($(wildcard $(BUILD_WORK)/qtimageformats/.build_complete),)
qtimageformats:
	@echo "Using previously built qtimageformats."
else
# No prereq on qtbase (staged in build_base already; mutter.mk precedent).
# No `rm -rf build` (incremental iteration, qtbase.mk).
qtimageformats: qtimageformats-setup
	mkdir -p $(BUILD_WORK)/qtimageformats/build
	cd $(BUILD_WORK)/qtimageformats/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DFEATURE_tiff=ON \
		-DFEATURE_system_tiff=OFF \
		-DFEATURE_webp=ON \
		-DFEATURE_system_webp=OFF \
		-DFEATURE_mng=OFF \
		-DFEATURE_jasper=OFF
	+ninja -C $(BUILD_WORK)/qtimageformats/build
	+DESTDIR="$(BUILD_STAGE)/qtimageformats" ninja -C $(BUILD_WORK)/qtimageformats/build install
	$(call AFTER_BUILD,copy)
endif

qtimageformats-package: qtimageformats-stage
	rm -rf $(BUILD_DIST)/qt6-image-formats
	mkdir -p $(BUILD_DIST)/qt6-image-formats/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6

	# plugins only; plus the cmake plugin-target files (tiny, land under lib/cmake/Qt6Gui)
	cp -a $(BUILD_STAGE)/qtimageformats/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins \
		$(BUILD_DIST)/qt6-image-formats/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins
	if [ -d "$(BUILD_STAGE)/qtimageformats/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake" ]; then \
		cp -a $(BUILD_STAGE)/qtimageformats/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake \
			$(BUILD_DIST)/qt6-image-formats/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake; \
	fi

	$(call SIGN,qt6-image-formats,general.xml)
	$(call PACK,qt6-image-formats,DEB_QTIMAGEFORMATS_V)
	rm -rf $(BUILD_DIST)/qt6-image-formats

.PHONY: qtimageformats qtimageformats-package
