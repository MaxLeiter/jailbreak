ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Unix QtDBus is enabled on iOS (not just Linux/FreeBSD) so KIOCore's DBus-gated desktop:/
# worker works; kiod6's AppKit bits are stripped via targeted sed instead of a blanket
# if(APPLE) guard, so ecm_mark_nongui_executable(kiod6) still runs and D-Bus activation doesn't break.

SUBPROJECTS += kio
KIO_VERSION = $(KF6_VERSION)
DEB_KIO_V ?= $(KIO_VERSION)+ios3

kio-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call KF6_URL,kio))
	$(call EXTRACT_TAR,kio-$(KF6_VERSION).tar.xz,kio-$(KF6_VERSION),kio)
	sed -i 's/if(UNIX AND NOT APPLE AND NOT ANDROID)/if(UNIX AND NOT ANDROID)/' $(BUILD_WORK)/kio/CMakeLists.txt
	sed -i '/kiod_agent\.mm/d' $(BUILD_WORK)/kio/src/kiod/CMakeLists.txt
	sed -i '/-framework AppKit -framework CoreFoundation/d' $(BUILD_WORK)/kio/src/kiod/CMakeLists.txt
	sed -i 's/defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD)/defined(Q_OS_LINUX) || defined(Q_OS_FREEBSD) || defined(Q_OS_IOS)/' $(BUILD_WORK)/kio/src/gui/openfilemanagerwindowjob_p.h
	sed -i 's/ Widgets Network Concurrent Xml Test)/ Widgets Network Concurrent Xml)/' $(BUILD_WORK)/kio/CMakeLists.txt
	sed -i 's/#ifdef Q_OS_MACOS/#if defined(Q_OS_MACOS) || defined(Q_OS_IOS)/' $(BUILD_WORK)/kio/src/kioworkers/file/file_unix.cpp
	sed -i 's/Q_OS_OSX/Q_OS_MACOS/g' $(BUILD_WORK)/kio/src/kioworkers/trash/trashimpl.cpp
	sed -i 's/-framework DiskArbitration //' $(BUILD_WORK)/kio/src/kioworkers/trash/CMakeLists.txt
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/kio/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kio/.build_complete),)
kio:
	@echo "Using previously built kio."
else
# Deps come pre-staged from build_base (mutter.mk precedent, no make-level
# prereqs); build-kf6.sh runs the targets in audit wave order.
kio: kio-setup
	mkdir -p $(BUILD_WORK)/kio/build
	cd $(BUILD_WORK)/kio/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DCMAKE_DISABLE_FIND_PACKAGE_ACL=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/kio/build
	+DESTDIR="$(BUILD_STAGE)/kio" ninja -C $(BUILD_WORK)/kio/build install
	$(call AFTER_BUILD,copy)
endif

kio-package: kio-stage
	rm -rf $(BUILD_DIST)/kf6-kio $(BUILD_DIST)/kf6-kio-dev
	$(call KF6_COPY_RUNTIME,kio,kf6-kio)
	$(call KF6_COPY_DEV,kio,kf6-kio)
	$(call SIGN,kf6-kio,general.xml)
	$(call SIGN,kf6-kio-dev,general.xml)
	$(call PACK,kf6-kio,DEB_KIO_V)
	$(call PACK,kf6-kio-dev,DEB_KIO_V)
	rm -rf $(BUILD_DIST)/kf6-kio $(BUILD_DIST)/kf6-kio-dev

.PHONY: kio kio-package
