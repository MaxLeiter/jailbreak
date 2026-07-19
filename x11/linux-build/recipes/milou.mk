ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# milou.mk — Plasma's real KRunner-backed search model and QML result views.
# Plasma Mobile imports org.kde.milou from KRunnerScreen; this package replaces
# the old inert ResultsListView fallback with the upstream C++ model/plugin.

SUBPROJECTS += milou
MILOU_VERSION = $(PLASMA_VERSION)
DEB_MILOU_V ?= $(MILOU_VERSION)+ios1

milou-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,milou))
	$(call EXTRACT_TAR,milou-$(PLASMA_VERSION).tar.xz,milou-$(PLASMA_VERSION),milou)
	sed -i '/^[[:space:]]*ki18n_install(/s/^/# ios-no-target-linguist: /' $(BUILD_WORK)/milou/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/milou/.build_complete),)
milou:
	@echo "Using previously built milou."
else
milou: milou-setup
	rm -rf $(BUILD_WORK)/milou/build
	mkdir -p $(BUILD_WORK)/milou/build
	cd $(BUILD_WORK)/milou/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/milou/build
	+DESTDIR="$(BUILD_STAGE)/milou" ninja -C $(BUILD_WORK)/milou/build install
	$(call AFTER_BUILD,copy)
endif

milou-package: milou-stage
	rm -rf $(BUILD_DIST)/milou $(BUILD_DIST)/milou-dev
	$(call KF6_COPY_RUNTIME,milou,milou)
	$(call SIGN,milou,general.xml)
	$(call PACK,milou,DEB_MILOU_V)
	rm -rf $(BUILD_DIST)/milou $(BUILD_DIST)/milou-dev

.PHONY: milou milou-package
