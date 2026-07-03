ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qttools.mk — minimal Qt Tools slice for rootless iOS. KWin's W-layer configure wants
# Qt6UiTools, but the rest of qttools is mostly target desktop apps and host-ish tooling
# (Designer, Linguist, QDoc, Assistant). Build only UiPlugin/UiTools plus CMake metadata.
# Shared Apple/Darwin flags + MACOS-condition fix: qt6-common.mk.

SUBPROJECTS      += qttools
QTTOOLS_VERSION  := 6.6.3
DEB_QTTOOLS_V    ?= $(QTTOOLS_VERSION)+ios1

qttools-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qttools))
	$(call EXTRACT_TAR,qttools-everywhere-src-$(QTTOOLS_VERSION).tar.xz,qttools-everywhere-src-$(QTTOOLS_VERSION),qttools)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qttools)
	sed -i 's/add_subdirectory(qdoc)/# ios-bringup-no-qdoc: add_subdirectory(qdoc)/' $(BUILD_WORK)/qttools/src/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qttools/.build_complete),)
qttools:
	@echo "Using previously built qttools."
else
qttools: qttools-setup
	mkdir -p $(BUILD_WORK)/qttools/build
	cd $(BUILD_WORK)/qttools/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DFEATURE_assistant=OFF \
		-DFEATURE_designer=OFF \
		-DFEATURE_distancefieldgenerator=OFF \
		-DFEATURE_linguist=OFF \
		-DFEATURE_pixeltool=OFF \
		-DFEATURE_qdbus=OFF \
		-DFEATURE_qdoc=OFF \
		-DFEATURE_qtattributionsscanner=OFF \
		-DFEATURE_qtdiag=OFF \
		-DFEATURE_qtplugininfo=OFF
	+ninja -C $(BUILD_WORK)/qttools/build
	+DESTDIR="$(BUILD_STAGE)/qttools" ninja -C $(BUILD_WORK)/qttools/build install
	$(call AFTER_BUILD,copy)
endif

qttools-package: qttools-stage
	rm -rf $(BUILD_DIST)/qt6-tools $(BUILD_DIST)/qt6-tools-dev
	mkdir -p $(BUILD_DIST)/qt6-tools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-tools-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: UiTools dylib if this Qt build produces one.
	cp -a $(BUILD_STAGE)/qttools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-tools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# dev: headers + CMake/pkgconfig/metatypes/mkspecs; KWin only needs find_package(Qt6UiTools).
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules; do \
		if [ -e "$(BUILD_STAGE)/qttools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-tools-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qttools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-tools-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-tools,general.xml)
	$(call PACK,qt6-tools,DEB_QTTOOLS_V)
	$(call PACK,qt6-tools-dev,DEB_QTTOOLS_V)
	rm -rf $(BUILD_DIST)/qt6-tools $(BUILD_DIST)/qt6-tools-dev

.PHONY: qttools qttools-package
