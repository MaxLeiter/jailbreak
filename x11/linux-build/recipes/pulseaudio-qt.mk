ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# pulseaudio-qt.mk — KF6 PulseAudioQt library needed by plasma-pa.

SUBPROJECTS += pulseaudio-qt
PULSEAUDIOQT_VERSION = 1.5.0
DEB_PULSEAUDIOQT_V ?= $(PULSEAUDIOQT_VERSION)+ios1

pulseaudio-qt-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/pulseaudio-qt/pulseaudio-qt-$(PULSEAUDIOQT_VERSION).tar.xz)
	$(call EXTRACT_TAR,pulseaudio-qt-$(PULSEAUDIOQT_VERSION).tar.xz,pulseaudio-qt-$(PULSEAUDIOQT_VERSION),pulseaudio-qt)
	sed -i '/ecm_install_po_files_as_qm/s/^/# ios: skip translations for first-light build /' $(BUILD_WORK)/pulseaudio-qt/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/pulseaudio-qt/.build_complete),)
pulseaudio-qt:
	@echo "Using previously built pulseaudio-qt."
else
pulseaudio-qt: pulseaudio-qt-setup
	rm -rf $(BUILD_WORK)/pulseaudio-qt/build
	mkdir -p $(BUILD_WORK)/pulseaudio-qt/build
	cd $(BUILD_WORK)/pulseaudio-qt/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DQT_MAJOR_VERSION=6 \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF
	+ninja -C $(BUILD_WORK)/pulseaudio-qt/build
	+DESTDIR="$(BUILD_STAGE)/pulseaudio-qt" ninja -C $(BUILD_WORK)/pulseaudio-qt/build install
	$(call AFTER_BUILD,copy)
endif

pulseaudio-qt-package: pulseaudio-qt-stage
	rm -rf $(BUILD_DIST)/kf6-pulseaudio-qt $(BUILD_DIST)/kf6-pulseaudio-qt-dev
	$(call KF6_COPY_RUNTIME,pulseaudio-qt,kf6-pulseaudio-qt)
	$(call KF6_COPY_DEV,pulseaudio-qt,kf6-pulseaudio-qt)
	$(call SIGN,kf6-pulseaudio-qt,general.xml)
	$(call SIGN,kf6-pulseaudio-qt-dev,general.xml)
	$(call PACK,kf6-pulseaudio-qt,DEB_PULSEAUDIOQT_V)
	$(call PACK,kf6-pulseaudio-qt-dev,DEB_PULSEAUDIOQT_V)
	rm -rf $(BUILD_DIST)/kf6-pulseaudio-qt $(BUILD_DIST)/kf6-pulseaudio-qt-dev

.PHONY: pulseaudio-qt pulseaudio-qt-package
