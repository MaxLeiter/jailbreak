ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libkscreen.mk - KF6 screen management library for Wayland/Xios.

SUBPROJECTS += libkscreen
LIBKSCREEN_VERSION = $(PLASMA_VERSION)
DEB_LIBKSCREEN_V ?= $(LIBKSCREEN_VERSION)+ios2

libkscreen-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,libkscreen))
	$(call EXTRACT_TAR,libkscreen-$(PLASMA_VERSION).tar.xz,libkscreen-$(PLASMA_VERSION),libkscreen)
	bash /work/recipes/libkscreen-ios-fixes.sh $(BUILD_WORK)/libkscreen
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/libkscreen/.build_complete),)
libkscreen:
	@echo "Using previously built libkscreen."
else
libkscreen: libkscreen-setup
	rm -rf $(BUILD_WORK)/libkscreen/build
	mkdir -p $(BUILD_WORK)/libkscreen/build
	cd $(BUILD_WORK)/libkscreen/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_Qt6Test=TRUE
	+ninja -C $(BUILD_WORK)/libkscreen/build
	+DESTDIR="$(BUILD_STAGE)/libkscreen" ninja -C $(BUILD_WORK)/libkscreen/build install
	$(call AFTER_BUILD,copy)
endif

libkscreen-package: libkscreen-stage
	rm -rf $(BUILD_DIST)/libkscreen $(BUILD_DIST)/libkscreen-dev
	$(call KF6_COPY_RUNTIME,libkscreen,libkscreen)
	$(call KF6_COPY_DEV,libkscreen,libkscreen)
	$(call SIGN,libkscreen,general.xml)
	$(call SIGN,libkscreen-dev,general.xml)
	$(call PACK,libkscreen,DEB_LIBKSCREEN_V)
	$(call PACK,libkscreen-dev,DEB_LIBKSCREEN_V)
	rm -rf $(BUILD_DIST)/libkscreen $(BUILD_DIST)/libkscreen-dev

.PHONY: libkscreen libkscreen-package
