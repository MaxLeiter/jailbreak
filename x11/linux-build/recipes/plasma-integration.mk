ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# plasma-integration.mk - KDE Qt platform theme for Xios.

SUBPROJECTS += plasma-integration
PLASMAINTEGRATION_VERSION = $(PLASMA_VERSION)
DEB_PLASMAINTEGRATION_V ?= $(PLASMAINTEGRATION_VERSION)+ios1

plasma-integration-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-integration))
	$(call EXTRACT_TAR,plasma-integration-$(PLASMA_VERSION).tar.xz,plasma-integration-$(PLASMA_VERSION),plasma-integration)
	bash /work/recipes/plasma-integration-ios-fixes.sh $(BUILD_WORK)/plasma-integration
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-integration/.build_complete),)
plasma-integration:
	@echo "Using previously built plasma-integration."
else
plasma-integration: plasma-integration-setup
	rm -rf $(BUILD_WORK)/plasma-integration/build
	mkdir -p $(BUILD_WORK)/plasma-integration/build
	cd $(BUILD_WORK)/plasma-integration/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QT5=OFF \
		-DBUILD_QT6=ON \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_XCB=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/plasma-integration/build
	+DESTDIR="$(BUILD_STAGE)/plasma-integration" ninja -C $(BUILD_WORK)/plasma-integration/build install
	$(call AFTER_BUILD,copy)
endif

plasma-integration-package: plasma-integration-stage
	rm -rf $(BUILD_DIST)/plasma-integration
	$(call KF6_COPY_RUNTIME,plasma-integration,plasma-integration)
	$(call SIGN,plasma-integration,general.xml)
	$(call PACK,plasma-integration,DEB_PLASMAINTEGRATION_V)
	rm -rf $(BUILD_DIST)/plasma-integration

.PHONY: plasma-integration plasma-integration-package
