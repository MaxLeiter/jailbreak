ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# breeze.mk - Plasma Breeze Qt widget style, colors, and cursors for Xios.

SUBPROJECTS += breeze
BREEZE_VERSION = $(PLASMA_VERSION)
DEB_BREEZE_V ?= $(BREEZE_VERSION)+ios1

breeze-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,breeze))
	$(call EXTRACT_TAR,breeze-$(PLASMA_VERSION).tar.xz,breeze-$(PLASMA_VERSION),breeze)
	sed -i '/^[[:space:]]*ki18n_install[[:space:]]*(po)/s/^/# ios-style-no-linguist: /' $(BUILD_WORK)/breeze/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/breeze/.build_complete),)
breeze:
	@echo "Using previously built breeze."
else
breeze: breeze-setup
	rm -rf $(BUILD_WORK)/breeze/build
	mkdir -p $(BUILD_WORK)/breeze/build
	cd $(BUILD_WORK)/breeze/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QT5=OFF \
		-DBUILD_QT6=ON \
		-DBUILD_TESTING=OFF \
		-DWITH_DECORATIONS=OFF \
		-DWITH_WALLPAPERS=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/breeze/build
	+DESTDIR="$(BUILD_STAGE)/breeze" ninja -C $(BUILD_WORK)/breeze/build install
	$(call AFTER_BUILD,copy)
endif

breeze-package: breeze-stage
	rm -rf $(BUILD_DIST)/breeze $(BUILD_DIST)/breeze-dev
	$(call KF6_COPY_RUNTIME,breeze,breeze)
	$(call KF6_COPY_DEV,breeze,breeze)
	$(call SIGN,breeze,general.xml)
	$(call SIGN,breeze-dev,general.xml)
	$(call PACK,breeze,DEB_BREEZE_V)
	$(call PACK,breeze-dev,DEB_BREEZE_V)
	rm -rf $(BUILD_DIST)/breeze $(BUILD_DIST)/breeze-dev

.PHONY: breeze breeze-package
