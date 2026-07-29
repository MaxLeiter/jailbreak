ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Plasma Desktop's Kickoff and several Mobile settings views import these
# QML modules; package them separately instead of letting shell packages own
# local stubs.

SUBPROJECTS += kirigami-addons
KIRIGAMIADDONS_VERSION = 1.3.0
DEB_KIRIGAMIADDONS_V ?= $(KIRIGAMIADDONS_VERSION)+ios1

kirigami-addons-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/kirigami-addons/kirigami-addons-$(KIRIGAMIADDONS_VERSION).tar.xz)
	$(call EXTRACT_TAR,kirigami-addons-$(KIRIGAMIADDONS_VERSION).tar.xz,kirigami-addons-$(KIRIGAMIADDONS_VERSION),kirigami-addons)
	sed -i '/ecm_install_po_files_as_qm/s/^/# ios: skip translations for first-light build /' $(BUILD_WORK)/kirigami-addons/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kirigami-addons/.build_complete),)
kirigami-addons:
	@echo "Using previously built kirigami-addons."
else
kirigami-addons: kirigami-addons-setup
	rm -rf $(BUILD_WORK)/kirigami-addons/build
	mkdir -p $(BUILD_WORK)/kirigami-addons/build
	cd $(BUILD_WORK)/kirigami-addons/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF
	+ninja -C $(BUILD_WORK)/kirigami-addons/build
	+DESTDIR="$(BUILD_STAGE)/kirigami-addons" ninja -C $(BUILD_WORK)/kirigami-addons/build install
	$(call AFTER_BUILD,copy)
endif

kirigami-addons-package: kirigami-addons-stage
	rm -rf $(BUILD_DIST)/kf6-kirigami-addons $(BUILD_DIST)/kf6-kirigami-addons-dev
	$(call KF6_COPY_RUNTIME,kirigami-addons,kf6-kirigami-addons)
	$(call KF6_COPY_DEV,kirigami-addons,kf6-kirigami-addons)
	$(call SIGN,kf6-kirigami-addons,general.xml)
	$(call SIGN,kf6-kirigami-addons-dev,general.xml)
	$(call PACK,kf6-kirigami-addons,DEB_KIRIGAMIADDONS_V)
	$(call PACK,kf6-kirigami-addons-dev,DEB_KIRIGAMIADDONS_V)
	rm -rf $(BUILD_DIST)/kf6-kirigami-addons $(BUILD_DIST)/kf6-kirigami-addons-dev

.PHONY: kirigami-addons kirigami-addons-package
