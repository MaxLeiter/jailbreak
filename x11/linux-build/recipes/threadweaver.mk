ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# threadweaver.mk — KF6 ThreadWeaver, needed by Okular.

SUBPROJECTS += threadweaver
THREADWEAVER_VERSION = $(KF6_VERSION)
DEB_THREADWEAVER_V ?= $(THREADWEAVER_VERSION)+ios1

threadweaver-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,threadweaver))
	$(call EXTRACT_TAR,threadweaver-$(KF6_VERSION).tar.xz,threadweaver-$(KF6_VERSION),threadweaver)
	sed -i '/add_subdirectory(examples)/s/^/# ios-no-examples: /' $(BUILD_WORK)/threadweaver/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/threadweaver/.build_complete),)
threadweaver:
	@echo "Using previously built threadweaver."
else
threadweaver: threadweaver-setup
	mkdir -p $(BUILD_WORK)/threadweaver/build
	cd $(BUILD_WORK)/threadweaver/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/threadweaver/build
	+DESTDIR="$(BUILD_STAGE)/threadweaver" ninja -C $(BUILD_WORK)/threadweaver/build install
	$(call AFTER_BUILD,copy)
endif

threadweaver-package: threadweaver-stage
	rm -rf $(BUILD_DIST)/kf6-threadweaver $(BUILD_DIST)/kf6-threadweaver-dev
	$(call KF6_COPY_RUNTIME,threadweaver,kf6-threadweaver)
	$(call KF6_COPY_DEV,threadweaver,kf6-threadweaver)
	$(call SIGN,kf6-threadweaver,general.xml)
	$(call SIGN,kf6-threadweaver-dev,general.xml)
	$(call PACK,kf6-threadweaver,DEB_THREADWEAVER_V)
	$(call PACK,kf6-threadweaver-dev,DEB_THREADWEAVER_V)
	rm -rf $(BUILD_DIST)/kf6-threadweaver $(BUILD_DIST)/kf6-threadweaver-dev

.PHONY: threadweaver threadweaver-package
