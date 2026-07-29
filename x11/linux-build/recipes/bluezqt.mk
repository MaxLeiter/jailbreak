ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# KF6 BluezQt library/QML import used by Plasma Mobile.

SUBPROJECTS += bluezqt
BLUEZQT_VERSION = $(KF6_VERSION)
DEB_BLUEZQT_V ?= $(BLUEZQT_VERSION)+ios1

bluezqt-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,bluez-qt))
	$(call EXTRACT_TAR,bluez-qt-$(KF6_VERSION).tar.xz,bluez-qt-$(KF6_VERSION),bluezqt)
	bash /work/recipes/bluezqt-ios-fixes.sh $(BUILD_WORK)/bluezqt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/bluezqt/.build_complete),)
bluezqt:
	@echo "Using previously built bluezqt."
else
bluezqt: bluezqt-setup
	rm -rf $(BUILD_WORK)/bluezqt/build
	mkdir -p $(BUILD_WORK)/bluezqt/build
	cd $(BUILD_WORK)/bluezqt/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF
	+ninja -C $(BUILD_WORK)/bluezqt/build
	+DESTDIR="$(BUILD_STAGE)/bluezqt" ninja -C $(BUILD_WORK)/bluezqt/build install
	$(call AFTER_BUILD,copy)
endif

bluezqt-package: bluezqt-stage
	rm -rf $(BUILD_DIST)/kf6-bluezqt $(BUILD_DIST)/kf6-bluezqt-dev
	$(call KF6_COPY_RUNTIME,bluezqt,kf6-bluezqt)
	$(call KF6_COPY_DEV,bluezqt,kf6-bluezqt)
	$(call SIGN,kf6-bluezqt,general.xml)
	$(call SIGN,kf6-bluezqt-dev,general.xml)
	$(call PACK,kf6-bluezqt,DEB_BLUEZQT_V)
	$(call PACK,kf6-bluezqt-dev,DEB_BLUEZQT_V)
	rm -rf $(BUILD_DIST)/kf6-bluezqt $(BUILD_DIST)/kf6-bluezqt-dev

.PHONY: bluezqt bluezqt-package
