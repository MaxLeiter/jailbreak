ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kquickcharts.mk — org.kde.quickcharts QML module for Plasma notification UI.

SUBPROJECTS += kquickcharts
KQUICKCHARTS_VERSION = $(KF6_VERSION)
DEB_KQUICKCHARTS_V ?= $(KQUICKCHARTS_VERSION)+ios1

kquickcharts-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,kquickcharts))
	$(call EXTRACT_TAR,kquickcharts-$(KF6_VERSION).tar.xz,kquickcharts-$(KF6_VERSION),kquickcharts)
	sed -i '/ecm_install_po_files_as_qm/s/^/# ios: skip translations for first-light build /' $(BUILD_WORK)/kquickcharts/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kquickcharts/.build_complete),)
kquickcharts:
	@echo "Using previously built kquickcharts."
else
kquickcharts: kquickcharts-setup
	rm -rf $(BUILD_WORK)/kquickcharts/build
	mkdir -p $(BUILD_WORK)/kquickcharts/build
	cd $(BUILD_WORK)/kquickcharts/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF
	+ninja -C $(BUILD_WORK)/kquickcharts/build
	+DESTDIR="$(BUILD_STAGE)/kquickcharts" ninja -C $(BUILD_WORK)/kquickcharts/build install
	$(call AFTER_BUILD,copy)
endif

kquickcharts-package: kquickcharts-stage
	rm -rf $(BUILD_DIST)/kf6-kquickcharts $(BUILD_DIST)/kf6-kquickcharts-dev
	$(call KF6_COPY_RUNTIME,kquickcharts,kf6-kquickcharts)
	$(call KF6_COPY_DEV,kquickcharts,kf6-kquickcharts)
	$(call SIGN,kf6-kquickcharts,general.xml)
	$(call SIGN,kf6-kquickcharts-dev,general.xml)
	$(call PACK,kf6-kquickcharts,DEB_KQUICKCHARTS_V)
	$(call PACK,kf6-kquickcharts-dev,DEB_KQUICKCHARTS_V)
	rm -rf $(BUILD_DIST)/kf6-kquickcharts $(BUILD_DIST)/kf6-kquickcharts-dev

.PHONY: kquickcharts kquickcharts-package
