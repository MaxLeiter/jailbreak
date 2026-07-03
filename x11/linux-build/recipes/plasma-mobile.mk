ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# plasma-mobile.mk — first-light Plasma Mobile data/shell package for Xios.
# This wave packages the mobile shell/look-and-feel, containment package data,
# quicksetting package data, the taskpanel applet plugin, and session launcher
# files. Hardware settings, KCMs, KWin effects, and the broader C++ mobile shell
# plugin wave are deferred until their support libraries and iOS service bridges
# are ready.

SUBPROJECTS += plasma-mobile
PLASMAMOBILE_VERSION = $(PLASMA_VERSION)
DEB_PLASMAMOBILE_V ?= $(PLASMAMOBILE_VERSION)+ios1

plasma-mobile-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-mobile))
	$(call EXTRACT_TAR,plasma-mobile-$(PLASMA_VERSION).tar.xz,plasma-mobile-$(PLASMA_VERSION),plasma-mobile)
	bash /work/recipes/plasma-mobile-ios-fixes.sh $(BUILD_WORK)/plasma-mobile
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-mobile/.build_complete),)
plasma-mobile:
	@echo "Using previously built plasma-mobile."
else
plasma-mobile: plasma-mobile-setup
	rm -rf $(BUILD_WORK)/plasma-mobile/build
	mkdir -p $(BUILD_WORK)/plasma-mobile/build
	cd $(BUILD_WORK)/plasma-mobile/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/plasma-mobile/build
	+DESTDIR="$(BUILD_STAGE)/plasma-mobile" ninja -C $(BUILD_WORK)/plasma-mobile/build install
	$(call AFTER_BUILD,copy)
endif

plasma-mobile-package: plasma-mobile-stage
	rm -rf $(BUILD_DIST)/plasma-mobile $(BUILD_DIST)/plasma-mobile-dev
	$(call KF6_COPY_RUNTIME,plasma-mobile,plasma-mobile)
	$(call KF6_COPY_DEV,plasma-mobile,plasma-mobile)
	bash /work/recipes/plasma-mobile-ios-qml-stubs.sh $(BUILD_DIST)/plasma-mobile$(MEMO_PREFIX)/usr/lib/qt6/qml
	$(call SIGN,plasma-mobile,general.xml)
	$(call SIGN,plasma-mobile-dev,general.xml)
	$(call PACK,plasma-mobile,DEB_PLASMAMOBILE_V)
	$(call PACK,plasma-mobile-dev,DEB_PLASMAMOBILE_V)
	rm -rf $(BUILD_DIST)/plasma-mobile $(BUILD_DIST)/plasma-mobile-dev

.PHONY: plasma-mobile plasma-mobile-package
