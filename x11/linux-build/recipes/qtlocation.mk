ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# New Qt module for the 6.10 lane: QtLocation map QML module and geoservice plugins. Required by plasma-workspace 6.7 (timezone selector map).

SUBPROJECTS       += qtlocation
QTLOCATION_VERSION := 6.10.3
DEB_QTLOCATION_V   ?= $(QTLOCATION_VERSION)+ios1

qtlocation-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtlocation))
	$(call EXTRACT_TAR,qtlocation-everywhere-src-$(QTLOCATION_VERSION).tar.xz,qtlocation-everywhere-src-$(QTLOCATION_VERSION),qtlocation)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtlocation)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)
	$(call QT6_APPLY_CVE,qtlocation)
	# qtlocation's top-level CMake lists Test/QuickTest among the targets it hard-asserts (tests only); our Qt has
	# FEATURE_testlib=OFF, so the module would otherwise be skipped silently ("TARGET Qt::Test is not met").
	sed -i 's/ Test QuickTest / /' $(BUILD_WORK)/qtlocation/CMakeLists.txt
	grep -q "Qml Quick Network Positioning" $(BUILD_WORK)/qtlocation/CMakeLists.txt

ifneq ($(wildcard $(BUILD_WORK)/qtlocation/.build_complete),)
qtlocation:
	@echo "Using previously built qtlocation."
else
qtlocation: qtlocation-setup
	mkdir -p $(BUILD_WORK)/qtlocation/build
	cd $(BUILD_WORK)/qtlocation/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS)
	+ninja -j12 -C $(BUILD_WORK)/qtlocation/build
	+DESTDIR="$(BUILD_STAGE)/qtlocation" ninja -j12 -C $(BUILD_WORK)/qtlocation/build install
	$(call AFTER_BUILD,copy)
endif

qtlocation-package: qtlocation-stage
	rm -rf $(BUILD_DIST)/qt6-location $(BUILD_DIST)/qt6-location-dev
	mkdir -p $(BUILD_DIST)/qt6-location/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-location-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: Location dylibs + plugins + QML module.
	cp -a $(BUILD_STAGE)/qtlocation/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-location/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	for d in lib/qt6/plugins lib/qt6/qml; do \
		if [ -d "$(BUILD_STAGE)/qtlocation/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-location/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtlocation/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-location/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue.
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules; do \
		if [ -e "$(BUILD_STAGE)/qtlocation/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-location-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtlocation/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-location-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-location,general.xml)
	$(call PACK,qt6-location,DEB_QTLOCATION_V)
	$(call PACK,qt6-location-dev,DEB_QTLOCATION_V)
	rm -rf $(BUILD_DIST)/qt6-location $(BUILD_DIST)/qt6-location-dev

.PHONY: qtlocation qtlocation-package
