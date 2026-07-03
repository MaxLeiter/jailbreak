ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qqc2-desktop-style.mk — kf6-qqc2-desktop-style for rootless iOS.
# Provides the org.kde.desktop QML module used by Plasma Desktop shell QML.

SUBPROJECTS += qqc2-desktop-style
QQC2DESKTOPSTYLE_VERSION = $(KF6_VERSION)
DEB_QQC2DESKTOPSTYLE_V ?= $(QQC2DESKTOPSTYLE_VERSION)+ios1

qqc2-desktop-style-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,qqc2-desktop-style))
	$(call EXTRACT_TAR,qqc2-desktop-style-$(KF6_VERSION).tar.xz,qqc2-desktop-style-$(KF6_VERSION),qqc2-desktop-style)
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/qqc2-desktop-style/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qqc2-desktop-style/.build_complete),)
qqc2-desktop-style:
	@echo "Using previously built qqc2-desktop-style."
else
qqc2-desktop-style: qqc2-desktop-style-setup
	mkdir -p $(BUILD_WORK)/qqc2-desktop-style/build
	cd $(BUILD_WORK)/qqc2-desktop-style/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/qqc2-desktop-style/build
	+DESTDIR="$(BUILD_STAGE)/qqc2-desktop-style" ninja -C $(BUILD_WORK)/qqc2-desktop-style/build install
	$(call AFTER_BUILD,copy)
endif

qqc2-desktop-style-package: qqc2-desktop-style-stage
	rm -rf $(BUILD_DIST)/kf6-qqc2-desktop-style $(BUILD_DIST)/kf6-qqc2-desktop-style-dev
	$(call KF6_COPY_RUNTIME,qqc2-desktop-style,kf6-qqc2-desktop-style)
	bash /work/recipes/qqc2-desktop-style-ios-qml-stubs.sh $(BUILD_DIST)/kf6-qqc2-desktop-style
	$(call KF6_COPY_DEV,qqc2-desktop-style,kf6-qqc2-desktop-style)
	$(call SIGN,kf6-qqc2-desktop-style,general.xml)
	$(call SIGN,kf6-qqc2-desktop-style-dev,general.xml)
	$(call PACK,kf6-qqc2-desktop-style,DEB_QQC2DESKTOPSTYLE_V)
	$(call PACK,kf6-qqc2-desktop-style-dev,DEB_QQC2DESKTOPSTYLE_V)
	rm -rf $(BUILD_DIST)/kf6-qqc2-desktop-style $(BUILD_DIST)/kf6-qqc2-desktop-style-dev

.PHONY: qqc2-desktop-style qqc2-desktop-style-package
