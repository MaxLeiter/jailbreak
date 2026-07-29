ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS += plasma-nano
PLASMANANO_VERSION = $(PLASMA_VERSION)
DEB_PLASMANANO_V ?= $(PLASMANANO_VERSION)+ios3

plasma-nano-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-nano))
	$(call EXTRACT_TAR,plasma-nano-$(PLASMA_VERSION).tar.xz,plasma-nano-$(PLASMA_VERSION),plasma-nano)
	bash /work/recipes/plasma-nano-ios-fixes.sh $(BUILD_WORK)/plasma-nano
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-nano/.build_complete),)
plasma-nano:
	@echo "Using previously built plasma-nano."
else
plasma-nano: plasma-nano-setup
	rm -rf $(BUILD_WORK)/plasma-nano/build
	mkdir -p $(BUILD_WORK)/plasma-nano/build
	cd $(BUILD_WORK)/plasma-nano/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/plasma-nano/build
	+DESTDIR="$(BUILD_STAGE)/plasma-nano" ninja -C $(BUILD_WORK)/plasma-nano/build install
	$(call AFTER_BUILD,copy)
endif

plasma-nano-package: plasma-nano-stage
	rm -rf $(BUILD_DIST)/plasma-nano $(BUILD_DIST)/plasma-nano-dev
	$(call KF6_COPY_RUNTIME,plasma-nano,plasma-nano)
	$(call KF6_COPY_DEV,plasma-nano,plasma-nano)
	$(call SIGN,plasma-nano,general.xml)
	$(call SIGN,plasma-nano-dev,general.xml)
	$(call PACK,plasma-nano,DEB_PLASMANANO_V)
	$(call PACK,plasma-nano-dev,DEB_PLASMANANO_V)
	rm -rf $(BUILD_DIST)/plasma-nano $(BUILD_DIST)/plasma-nano-dev

.PHONY: plasma-nano plasma-nano-package
