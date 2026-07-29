ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kcmshell6 (the standalone KCM launcher) does NOT live here; it moved into
# KCMUtils for KF6, and kf6-kcmutils already ships /var/jb/usr/bin/kcmshell6
# as a plain Mach-O binary. This package is not on the critical path for
# System Settings pages.
#
# Cuts: WITH_X11=OFF (kstart's only X11 use is Qt::GuiPrivate for startup-id);
# KF6Su is unpublished so kdesu is skipped by upstream's own KF6Su_FOUND guard;
# DocTools/doc/po are dropped by kde-cli-tools-ios-fixes.sh.
#
# kcm_filetypes calls kcmutils_generate_desktop_file() (KF6::kcmdesktopfilegenerator),
# which the cross build stages as an iOS binary. Build on a volume where
# build-plasma-desktop.sh has already installed its host Python replacement
# into KCMUtilsMacros.

SUBPROJECTS += kde-cli-tools
KDECLITOOLS_VERSION = $(PLASMA_VERSION)
DEB_KDECLITOOLS_V ?= $(KDECLITOOLS_VERSION)+ios1

kde-cli-tools-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,kde-cli-tools))
	$(call EXTRACT_TAR,kde-cli-tools-$(PLASMA_VERSION).tar.xz,kde-cli-tools-$(PLASMA_VERSION),kde-cli-tools)
	bash /work/recipes/kde-cli-tools-ios-fixes.sh $(BUILD_WORK)/kde-cli-tools
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kde-cli-tools/.build_complete),)
kde-cli-tools:
	@echo "Using previously built kde-cli-tools."
else
kde-cli-tools: kde-cli-tools-setup
	rm -rf $(BUILD_WORK)/kde-cli-tools/build
	mkdir -p $(BUILD_WORK)/kde-cli-tools/build
	cd $(BUILD_WORK)/kde-cli-tools/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6Su=TRUE
	+ninja -C $(BUILD_WORK)/kde-cli-tools/build
	+DESTDIR="$(BUILD_STAGE)/kde-cli-tools" ninja -C $(BUILD_WORK)/kde-cli-tools/build install
	$(call AFTER_BUILD,copy)
endif

# No installed headers/CMake metadata, so no -dev split. GUI-capable tools
# (keditfiletype, kioclient dialogs) are Qt Wayland clients under iosc, so
# they need the GPU-client entitlement tier, not plain general.xml.
kde-cli-tools-package: kde-cli-tools-stage
	rm -rf $(BUILD_DIST)/kde-cli-tools
	$(call KF6_COPY_RUNTIME,kde-cli-tools,kde-cli-tools)
	$(call SIGN,kde-cli-tools,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,kde-cli-tools,DEB_KDECLITOOLS_V)
	rm -rf $(BUILD_DIST)/kde-cli-tools

.PHONY: kde-cli-tools kde-cli-tools-package
