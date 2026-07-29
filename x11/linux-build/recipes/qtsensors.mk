ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# KWin probes Qt6Sensors in its W-layer configure. Native sensor backends can be
# refined later after first compositor bring-up.

SUBPROJECTS       += qtsensors
QTSENSORS_VERSION := 6.6.3
DEB_QTSENSORS_V   ?= $(QTSENSORS_VERSION)+ios1

qtsensors-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtsensors))
	$(call EXTRACT_TAR,qtsensors-everywhere-src-$(QTSENSORS_VERSION).tar.xz,qtsensors-everywhere-src-$(QTSENSORS_VERSION),qtsensors)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtsensors)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qtsensors/.build_complete),)
qtsensors:
	@echo "Using previously built qtsensors."
else
qtsensors: qtsensors-setup
	mkdir -p $(BUILD_WORK)/qtsensors/build
	cd $(BUILD_WORK)/qtsensors/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/qtsensors/build
	+DESTDIR="$(BUILD_STAGE)/qtsensors" ninja -C $(BUILD_WORK)/qtsensors/build install
	$(call AFTER_BUILD,copy)
endif

qtsensors-package: qtsensors-stage
	rm -rf $(BUILD_DIST)/qt6-sensors $(BUILD_DIST)/qt6-sensors-dev
	mkdir -p $(BUILD_DIST)/qt6-sensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-sensors-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: Sensors dylibs + sensors plugins + optional QtSensors QML module.
	cp -a $(BUILD_STAGE)/qtsensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-sensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	for d in lib/qt6/plugins lib/qt6/qml; do \
		if [ -d "$(BUILD_STAGE)/qtsensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-sensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtsensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-sensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue.
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules; do \
		if [ -e "$(BUILD_STAGE)/qtsensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-sensors-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtsensors/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-sensors-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-sensors,general.xml)
	$(call PACK,qt6-sensors,DEB_QTSENSORS_V)
	$(call PACK,qt6-sensors-dev,DEB_QTSENSORS_V)
	rm -rf $(BUILD_DIST)/qt6-sensors $(BUILD_DIST)/qt6-sensors-dev

.PHONY: qtsensors qtsensors-package
