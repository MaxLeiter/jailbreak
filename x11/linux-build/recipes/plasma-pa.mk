ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# plasma-pa.mk — Plasma volume applet and org.kde.plasma.private.volume QML import.

SUBPROJECTS += plasma-pa
PLASMAPA_VERSION = $(PLASMA_VERSION)
DEB_PLASMAPA_V ?= $(PLASMAPA_VERSION)+ios2

plasma-pa-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-pa))
	$(call EXTRACT_TAR,plasma-pa-$(PLASMA_VERSION).tar.xz,plasma-pa-$(PLASMA_VERSION),plasma-pa)
	bash /work/recipes/plasma-pa-ios-fixes.sh $(BUILD_WORK)/plasma-pa
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-pa/.build_complete),)
plasma-pa:
	@echo "Using previously built plasma-pa."
else
plasma-pa: plasma-pa-setup
	rm -rf $(BUILD_WORK)/plasma-pa/build
	mkdir -p $(BUILD_WORK)/plasma-pa/build
	cd $(BUILD_WORK)/plasma-pa/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_Canberra=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/plasma-pa/build
	+DESTDIR="$(BUILD_STAGE)/plasma-pa" ninja -C $(BUILD_WORK)/plasma-pa/build install
	$(call AFTER_BUILD,copy)
endif

plasma-pa-package: plasma-pa-stage
	rm -rf $(BUILD_DIST)/plasma-pa $(BUILD_DIST)/plasma-pa-dev
	$(call KF6_COPY_RUNTIME,plasma-pa,plasma-pa)
	$(call KF6_COPY_DEV,plasma-pa,plasma-pa)
	$(call SIGN,plasma-pa,general.xml)
	$(call SIGN,plasma-pa-dev,general.xml)
	$(call PACK,plasma-pa,DEB_PLASMAPA_V)
	$(call PACK,plasma-pa-dev,DEB_PLASMAPA_V)
	rm -rf $(BUILD_DIST)/plasma-pa $(BUILD_DIST)/plasma-pa-dev

.PHONY: plasma-pa plasma-pa-package
