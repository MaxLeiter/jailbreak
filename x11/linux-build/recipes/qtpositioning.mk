ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# New Qt module for the 6.10 lane: QtPositioning (C++ and QML) with NMEA position sources. Required by plasma-workspace (libcolorcorrect) and the Ladybird Qt frontend.

SUBPROJECTS       += qtpositioning
QTPOSITIONING_VERSION := 6.10.3
DEB_QTPOSITIONING_V   ?= $(QTPOSITIONING_VERSION)+ios1

qtpositioning-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtpositioning))
	$(call EXTRACT_TAR,qtpositioning-everywhere-src-$(QTPOSITIONING_VERSION).tar.xz,qtpositioning-everywhere-src-$(QTPOSITIONING_VERSION),qtpositioning)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtpositioning)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)
	$(call QT6_APPLY_CVE,qtpositioning)

ifneq ($(wildcard $(BUILD_WORK)/qtpositioning/.build_complete),)
qtpositioning:
	@echo "Using previously built qtpositioning."
else
qtpositioning: qtpositioning-setup
	mkdir -p $(BUILD_WORK)/qtpositioning/build
	cd $(BUILD_WORK)/qtpositioning/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS)
	+ninja -j12 -C $(BUILD_WORK)/qtpositioning/build
	+DESTDIR="$(BUILD_STAGE)/qtpositioning" ninja -j12 -C $(BUILD_WORK)/qtpositioning/build install
	$(call AFTER_BUILD,copy)
endif

qtpositioning-package: qtpositioning-stage
	rm -rf $(BUILD_DIST)/qt6-positioning $(BUILD_DIST)/qt6-positioning-dev
	mkdir -p $(BUILD_DIST)/qt6-positioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-positioning-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: Positioning dylibs + plugins + QML module.
	cp -a $(BUILD_STAGE)/qtpositioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-positioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	for d in lib/qt6/plugins lib/qt6/qml; do \
		if [ -d "$(BUILD_STAGE)/qtpositioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-positioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtpositioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-positioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue.
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules; do \
		if [ -e "$(BUILD_STAGE)/qtpositioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-positioning-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtpositioning/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-positioning-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-positioning,general.xml)
	$(call PACK,qt6-positioning,DEB_QTPOSITIONING_V)
	$(call PACK,qt6-positioning-dev,DEB_QTPOSITIONING_V)
	rm -rf $(BUILD_DIST)/qt6-positioning $(BUILD_DIST)/qt6-positioning-dev

.PHONY: qtpositioning qtpositioning-package
