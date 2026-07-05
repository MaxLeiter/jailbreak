ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# plasma-workspace.mk — first-light plasmashell/workspace package for rootless iOS.
# This is deliberately not the full Linux desktop session. The source-fix script
# keeps the core shell path and trims KScreenLocker, KSysGuard, Phonon/Canberra,
# UDev, KCMs, applets, data engines, and session management for the first pass.

SUBPROJECTS += plasma-workspace
PLASMAWORKSPACE_VERSION = $(PLASMA_VERSION)
DEB_PLASMAWORKSPACE_V ?= $(PLASMAWORKSPACE_VERSION)+ios7

plasma-workspace-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-workspace))
	$(call EXTRACT_TAR,plasma-workspace-$(PLASMA_VERSION).tar.xz,plasma-workspace-$(PLASMA_VERSION),plasma-workspace)
	bash /work/recipes/plasma-workspace-ios-fixes.sh $(BUILD_WORK)/plasma-workspace
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-workspace/.build_complete),)
plasma-workspace:
	@echo "Using previously built plasma-workspace."
else
plasma-workspace: plasma-workspace-setup
	rm -rf $(BUILD_WORK)/plasma-workspace/build
	mkdir -p $(BUILD_WORK)/plasma-workspace/build
	cd $(BUILD_WORK)/plasma-workspace/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/plasma-workspace/build
	+DESTDIR="$(BUILD_STAGE)/plasma-workspace" ninja -C $(BUILD_WORK)/plasma-workspace/build install
	$(call AFTER_BUILD,copy)
endif

plasma-workspace-package: plasma-workspace-stage
	rm -rf $(BUILD_DIST)/plasma-workspace $(BUILD_DIST)/plasma-workspace-dev
	$(call KF6_COPY_RUNTIME,plasma-workspace,plasma-workspace)
	if [ -e "$(BUILD_STAGE)/plasma-workspace/Applications" ]; then \
		mkdir -p $(BUILD_DIST)/plasma-workspace$(MEMO_PREFIX)/Applications; \
		cp -a $(BUILD_STAGE)/plasma-workspace/Applications/. $(BUILD_DIST)/plasma-workspace$(MEMO_PREFIX)/Applications/; \
	fi
	if [ -e "$(BUILD_STAGE)/plasma-workspace$(MEMO_PREFIX)/etc" ]; then \
		mkdir -p $(BUILD_DIST)/plasma-workspace$(MEMO_PREFIX); \
		cp -a $(BUILD_STAGE)/plasma-workspace$(MEMO_PREFIX)/etc $(BUILD_DIST)/plasma-workspace$(MEMO_PREFIX)/; \
	fi
	bash /work/recipes/plasma-workspace-ios-package-fixes.sh $(BUILD_DIST)/plasma-workspace
	$(call KF6_COPY_DEV,plasma-workspace,plasma-workspace)
	# plasmashell/plasmawindowed are real QtQuick/Wayland clients; keep them on
	# the GPU/IOSurface entitlement set instead of Procursus general.xml.
	$(call SIGN,plasma-workspace,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call SIGN,plasma-workspace-dev,general.xml)
	$(call PACK,plasma-workspace,DEB_PLASMAWORKSPACE_V)
	$(call PACK,plasma-workspace-dev,DEB_PLASMAWORKSPACE_V)
	rm -rf $(BUILD_DIST)/plasma-workspace $(BUILD_DIST)/plasma-workspace-dev

.PHONY: plasma-workspace plasma-workspace-package
