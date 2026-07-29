ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Data engines are deferred (dataengines/ skipped in the fixes script) because
# devicenotifications there pulls in KSysGuard.

SUBPROJECTS += plasma5support
PLASMA5SUPPORT_VERSION = $(PLASMA_VERSION)
DEB_PLASMA5SUPPORT_V ?= $(PLASMA5SUPPORT_VERSION)+ios1

plasma5support-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma5support))
	$(call EXTRACT_TAR,plasma5support-$(PLASMA_VERSION).tar.xz,plasma5support-$(PLASMA_VERSION),plasma5support)
	bash /work/recipes/plasma5support-ios-fixes.sh $(BUILD_WORK)/plasma5support
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma5support/.build_complete),)
plasma5support:
	@echo "Using previously built plasma5support."
else
plasma5support: plasma5support-setup
	rm -rf $(BUILD_WORK)/plasma5support/build
	mkdir -p $(BUILD_WORK)/plasma5support/build
	cd $(BUILD_WORK)/plasma5support/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KSysGuard=TRUE
	+ninja -C $(BUILD_WORK)/plasma5support/build
	+DESTDIR="$(BUILD_STAGE)/plasma5support" ninja -C $(BUILD_WORK)/plasma5support/build install
	$(call AFTER_BUILD,copy)
endif

plasma5support-package: plasma5support-stage
	rm -rf $(BUILD_DIST)/plasma5support $(BUILD_DIST)/plasma5support-dev
	$(call KF6_COPY_RUNTIME,plasma5support,plasma5support)
	$(call KF6_COPY_DEV,plasma5support,plasma5support)
	$(call SIGN,plasma5support,general.xml)
	$(call SIGN,plasma5support-dev,general.xml)
	$(call PACK,plasma5support,DEB_PLASMA5SUPPORT_V)
	$(call PACK,plasma5support-dev,DEB_PLASMA5SUPPORT_V)
	rm -rf $(BUILD_DIST)/plasma5support $(BUILD_DIST)/plasma5support-dev

.PHONY: plasma5support plasma5support-package
