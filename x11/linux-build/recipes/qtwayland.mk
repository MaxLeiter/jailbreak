ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# The Wayland CLIENT QPA (platform plugin): how every Qt app gets a window on iosc.
#
# wl_shm remains the safe fallback; qtwayland's stock `wayland-egl` client buffer
# integration resolves EGL calls to /var/jb/lib/angle/libEGL.dylib, the iosc shim that
# advertises EGL_PLATFORM_WAYLAND, remaps the display to ANGLE Metal, renders window
# surfaces into IOSurface pbuffers, and hands those to iosc zero-copy. If stock QtWayland
# rejects that shim during device validation, the fallback is the private-ABI plugin in
# docs/qtwayland-angle-iosurface.md (a Qt `wayland-graphics-integration-client` plugin
# named `iosurface`) — only build that if validation proves the generic shim insufficient.
#
# HOST build needs both qtwaylandscanner (via QT_HOST_PATH) AND the plain wayland-scanner
# binary (Wayland::Scanner; from Debian's libwayland-bin, apt-installed by the driver).
# FEATURE_wayland_server=OFF: QtWaylandCompositor is dead weight — KWin speaks
# libwayland-server directly, and iosc is our own compositor.

SUBPROJECTS       += qtwayland
QTWAYLAND_VERSION := 6.6.3
DEB_QTWAYLAND_V   ?= $(QTWAYLAND_VERSION)-1+ios3
QTWAYLAND_ANGLE_PREFIX := $(BUILD_BASE)$(MEMO_PREFIX)
QTWAYLAND_ANGLE_INC    := $(QTWAYLAND_ANGLE_PREFIX)/include
QTWAYLAND_ANGLE_LIB    := $(QTWAYLAND_ANGLE_PREFIX)/lib/angle

qtwayland-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtwayland))
	$(call EXTRACT_TAR,qtwayland-everywhere-src-$(QTWAYLAND_VERSION).tar.xz,qtwayland-everywhere-src-$(QTWAYLAND_VERSION),qtwayland)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtwayland)
	bash /work/recipes/qtwayland-ios-fixes.sh $(BUILD_WORK)/qtwayland
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)
	# qgenericunixthemes never built in our qtbase (gated UNIX AND NOT MACOS, and MACOS
	# stays set under the masquerade), so its private header isn't staged — drop only the
	# theme hookup (nullptr = Qt default). Plasma later gets real theming from
	# plasma-integration's own platformtheme plugin, which replaces the generic one.
	sed -i '/#include <QtGui\/private\/qgenericunixthemes_p.h>/d' \
		$(BUILD_WORK)/qtwayland/src/client/qwaylandintegration.cpp
	sed -i 's/return QGenericUnixTheme::themeNames();/return QStringList();/' \
		$(BUILD_WORK)/qtwayland/src/client/qwaylandintegration.cpp
	sed -i 's/return QGenericUnixTheme::createUnixTheme(name);/return nullptr;/' \
		$(BUILD_WORK)/qtwayland/src/client/qwaylandintegration.cpp

ifneq ($(wildcard $(BUILD_WORK)/qtwayland/.build_complete),)
qtwayland:
	@echo "Using previously built qtwayland."
else
qtwayland: qtwayland-setup
	mkdir -p $(BUILD_WORK)/qtwayland/build
# WaylandScanner_EXECUTABLE pinned to the HOST binary: build_base/usr/bin has an
# arm64-iOS wayland-scanner, and the cross find-root searches the sysroot first ->
# "Exec format error" at codegen. find_program honors a -D pre-set.
	cd $(BUILD_WORK)/qtwayland/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner \
		-DEGL_INCLUDE_DIR=$(QTWAYLAND_ANGLE_INC) \
		-DEGL_LIBRARY=$(QTWAYLAND_ANGLE_LIB)/libEGL.dylib \
		-DGLESv2_INCLUDE_DIR=$(QTWAYLAND_ANGLE_INC) \
		-DGLESv2_LIBRARY=$(QTWAYLAND_ANGLE_LIB)/libGLESv2.dylib \
		-DFEATURE_egl_extension_platform_wayland=OFF \
		-DFEATURE_wayland_egl=ON \
		-DFEATURE_wayland_drm_egl_server_buffer=OFF \
		-DFEATURE_wayland_libhybris_egl_server_buffer=OFF \
		-DFEATURE_wayland_shm_emulation_server_buffer=OFF \
		-DFEATURE_wayland_client=ON \
		-DFEATURE_wayland_server=OFF
	+ninja -C $(BUILD_WORK)/qtwayland/build
	+DESTDIR="$(BUILD_STAGE)/qtwayland" ninja -C $(BUILD_WORK)/qtwayland/build install
	test -f "$(BUILD_STAGE)/qtwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins/wayland-graphics-integration-client/libqt-plugin-wayland-egl.dylib"
	$(call AFTER_BUILD,copy,qtwayland,/var/jb/lib/angle)
endif

qtwayland-package: qtwayland-stage
	rm -rf $(BUILD_DIST)/qt6-wayland $(BUILD_DIST)/qt6-wayland-dev
	mkdir -p $(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-wayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: WaylandClient dylibs + every plugin dir (platforms/libqwayland-generic,
	# wayland-shell-integration, wayland-decoration-client, wayland-graphics-integration-client).
	cp -a $(BUILD_STAGE)/qtwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/qtwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins" ]; then \
		mkdir -p $(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6; \
		cp -a $(BUILD_STAGE)/qtwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins \
			$(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins; \
	fi

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue (needed to build the
	# iosurface graphics-integration plugin out-of-tree later, and any KDE bits that link
	# WaylandClient private API).
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules bin lib/qt6/libexec; do \
		if [ -e "$(BUILD_STAGE)/qtwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-wayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtwayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-wayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-wayland,general.xml)
	$(call SIGN,qt6-wayland-dev,general.xml)
	$(call PACK,qt6-wayland,DEB_QTWAYLAND_V)
	$(call PACK,qt6-wayland-dev,DEB_QTWAYLAND_V)
	rm -rf $(BUILD_DIST)/qt6-wayland $(BUILD_DIST)/qt6-wayland-dev

.PHONY: qtwayland qtwayland-package
