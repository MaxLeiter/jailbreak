ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kactivitymanagerd.mk — Plasma activity manager daemon for rootless iOS.
# Plasma 6 ships the daemon as a sibling tarball to plasma-activities. Keep it
# packageable separately so plasmashell can use the real DBus activity service
# instead of relying on a first-light bypass.

SUBPROJECTS += kactivitymanagerd
KACTIVITYMANAGERD_VERSION = $(PLASMA_VERSION)
DEB_KACTIVITYMANAGERD_V ?= $(KACTIVITYMANAGERD_VERSION)+ios1

kactivitymanagerd-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,kactivitymanagerd))
	$(call EXTRACT_TAR,kactivitymanagerd-$(PLASMA_VERSION).tar.xz,kactivitymanagerd-$(PLASMA_VERSION),kactivitymanagerd)
	bash /work/recipes/kactivitymanagerd-ios-fixes.sh $(BUILD_WORK)/kactivitymanagerd
	sed -i '/^[[:space:]]*ki18n_install[[:space:]]*(po)/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/kactivitymanagerd/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kactivitymanagerd/.build_complete),)
kactivitymanagerd:
	@echo "Using previously built kactivitymanagerd."
else
# Depends on already-staged Qt/KF6/Plasma libraries from the KDE and Plasma
# waves. Boost is headers-only here and is installed by the build driver.
kactivitymanagerd: kactivitymanagerd-setup
	rm -rf $(BUILD_WORK)/kactivitymanagerd/build
	mkdir -p $(BUILD_WORK)/kactivitymanagerd/build
	cd $(BUILD_WORK)/kactivitymanagerd/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/kactivitymanagerd/build
	+DESTDIR="$(BUILD_STAGE)/kactivitymanagerd" ninja -C $(BUILD_WORK)/kactivitymanagerd/build install
	$(call AFTER_BUILD,copy)
endif

kactivitymanagerd-package: kactivitymanagerd-stage
	rm -rf $(BUILD_DIST)/kactivitymanagerd
	$(call KF6_COPY_RUNTIME,kactivitymanagerd,kactivitymanagerd)
	$(call SIGN,kactivitymanagerd,general.xml)
	$(call PACK,kactivitymanagerd,DEB_KACTIVITYMANAGERD_V)
	rm -rf $(BUILD_DIST)/kactivitymanagerd

.PHONY: kactivitymanagerd kactivitymanagerd-package
