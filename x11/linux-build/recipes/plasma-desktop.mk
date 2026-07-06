ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# plasma-desktop.mk — desktop containment/applets package for Xios.
# This intentionally packages the Plasma desktop surface above plasmashell, not a
# full Linux desktop settings stack. The source-fix script keeps containment,
# panel/layout data, lightweight applet packages, and KRunner helpers while
# trimming KCMs, X11/XCB, SDDM, automounter, kaccess, and account integrations.

SUBPROJECTS += plasma-desktop
PLASMADESKTOP_VERSION = $(PLASMA_VERSION)
DEB_PLASMADESKTOP_V ?= $(PLASMADESKTOP_VERSION)+ios5

plasma-desktop-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-desktop))
	$(call EXTRACT_TAR,plasma-desktop-$(PLASMA_VERSION).tar.xz,plasma-desktop-$(PLASMA_VERSION),plasma-desktop)
	bash /work/recipes/plasma-desktop-ios-fixes.sh $(BUILD_WORK)/plasma-desktop
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-desktop/.build_complete),)
plasma-desktop:
	@echo "Using previously built plasma-desktop."
else
plasma-desktop: plasma-desktop-setup
	rm -rf $(BUILD_WORK)/plasma-desktop/build
	mkdir -p $(BUILD_WORK)/plasma-desktop/build
	cd $(BUILD_WORK)/plasma-desktop/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DBUILD_KCM_MOUSE_X11=OFF \
		-DBUILD_KCM_TOUCHPAD_X11=OFF \
		-DINSTALL_SDDM_THEME=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_PackageKitQt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_AccountsQt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KAccounts6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_SDL2=TRUE
	+ninja -C $(BUILD_WORK)/plasma-desktop/build
	+DESTDIR="$(BUILD_STAGE)/plasma-desktop" ninja -C $(BUILD_WORK)/plasma-desktop/build install
	$(call AFTER_BUILD,copy)
endif

plasma-desktop-package: plasma-desktop-stage
	rm -rf $(BUILD_DIST)/plasma-desktop $(BUILD_DIST)/plasma-desktop-dev
	$(call KF6_COPY_RUNTIME,plasma-desktop,plasma-desktop)
	$(call KF6_COPY_DEV,plasma-desktop,plasma-desktop)
	bash /work/recipes/plasma-desktop-ios-qml-fixes.sh $(BUILD_DIST)/plasma-desktop
	$(call SIGN,plasma-desktop,general.xml)
	$(call SIGN,plasma-desktop-dev,general.xml)
	$(call PACK,plasma-desktop,DEB_PLASMADESKTOP_V)
	$(call PACK,plasma-desktop-dev,DEB_PLASMADESKTOP_V)
	rm -rf $(BUILD_DIST)/plasma-desktop $(BUILD_DIST)/plasma-desktop-dev

.PHONY: plasma-desktop plasma-desktop-package
