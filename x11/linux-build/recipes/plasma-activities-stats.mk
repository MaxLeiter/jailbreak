ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# plasma-activities-stats.mk — PlasmaActivitiesStats for rootless iOS.
# This is the first Plasma-workspace support package above the existing
# plasma-activities client library. It is small, but it requires QtSql, so it
# depends on the Qtbase round-4 feature bump.

SUBPROJECTS += plasma-activities-stats
PLASMAACTIVITIESSTATS_VERSION = $(PLASMA_VERSION)
DEB_PLASMAACTIVITIESSTATS_V ?= $(PLASMAACTIVITIESSTATS_VERSION)+ios1

plasma-activities-stats-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,plasma-activities-stats))
	$(call EXTRACT_TAR,plasma-activities-stats-$(PLASMA_VERSION).tar.xz,plasma-activities-stats-$(PLASMA_VERSION),plasma-activities-stats)
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/plasma-activities-stats/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/plasma-activities-stats/.build_complete),)
plasma-activities-stats:
	@echo "Using previously built plasma-activities-stats."
else
plasma-activities-stats: plasma-activities-stats-setup
	rm -rf $(BUILD_WORK)/plasma-activities-stats/build
	mkdir -p $(BUILD_WORK)/plasma-activities-stats/build
	cd $(BUILD_WORK)/plasma-activities-stats/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF
	+ninja -C $(BUILD_WORK)/plasma-activities-stats/build
	+DESTDIR="$(BUILD_STAGE)/plasma-activities-stats" ninja -C $(BUILD_WORK)/plasma-activities-stats/build install
	$(call AFTER_BUILD,copy)
endif

plasma-activities-stats-package: plasma-activities-stats-stage
	rm -rf $(BUILD_DIST)/plasma-activities-stats $(BUILD_DIST)/plasma-activities-stats-dev
	$(call KF6_COPY_RUNTIME,plasma-activities-stats,plasma-activities-stats)
	$(call KF6_COPY_DEV,plasma-activities-stats,plasma-activities-stats)
	$(call SIGN,plasma-activities-stats,general.xml)
	$(call SIGN,plasma-activities-stats-dev,general.xml)
	$(call PACK,plasma-activities-stats,DEB_PLASMAACTIVITIESSTATS_V)
	$(call PACK,plasma-activities-stats-dev,DEB_PLASMAACTIVITIESSTATS_V)
	rm -rf $(BUILD_DIST)/plasma-activities-stats $(BUILD_DIST)/plasma-activities-stats-dev

.PHONY: plasma-activities-stats plasma-activities-stats-package
