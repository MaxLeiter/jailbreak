ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kscreen.mk - display KCM, KDED daemon, OSD, and CLI tools for Xios.

SUBPROJECTS += kscreen
KSCREEN_VERSION = $(PLASMA_VERSION)
DEB_KSCREEN_V ?= $(KSCREEN_VERSION)+ios1

kscreen-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,kscreen))
	$(call EXTRACT_TAR,kscreen-$(PLASMA_VERSION).tar.xz,kscreen-$(PLASMA_VERSION),kscreen)
	bash /work/recipes/kscreen-ios-fixes.sh $(BUILD_WORK)/kscreen
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kscreen/.build_complete),)
kscreen:
	@echo "Using previously built kscreen."
else
kscreen: kscreen-setup libkscreen
	rm -rf $(BUILD_WORK)/kscreen/build
	mkdir -p $(BUILD_WORK)/kscreen/build
	cd $(BUILD_WORK)/kscreen/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/kscreen/build
	+DESTDIR="$(BUILD_STAGE)/kscreen" ninja -C $(BUILD_WORK)/kscreen/build install
	$(call AFTER_BUILD,copy)
endif

kscreen-package: kscreen-stage
	rm -rf $(BUILD_DIST)/kscreen $(BUILD_DIST)/kscreen-dev
	$(call KF6_COPY_RUNTIME,kscreen,kscreen)
	$(call KF6_COPY_DEV,kscreen,kscreen)
	$(call SIGN,kscreen,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call SIGN,kscreen-dev,general.xml)
	$(call PACK,kscreen,DEB_KSCREEN_V)
	$(call PACK,kscreen-dev,DEB_KSCREEN_V)
	rm -rf $(BUILD_DIST)/kscreen $(BUILD_DIST)/kscreen-dev

.PHONY: kscreen kscreen-package
