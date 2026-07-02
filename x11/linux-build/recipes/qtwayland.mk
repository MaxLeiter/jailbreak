ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qtwayland.mk — the Wayland CLIENT QPA (platform plugin) for rootless iOS: how every Qt
# app (and eventually KWin-nested + Plasma Mobile) gets a window on iosc.
#
# SCOPE, round 3: wl_shm remains the safe fallback, but qtbase now exposes EGL/OpenGL ES
# through the ANGLE package. QtWayland's stock `wayland-egl` client buffer integration is
# built and resolves EGL calls to /var/jb/lib/angle/libEGL.dylib, which is the iosc shim:
# it advertises EGL_PLATFORM_WAYLAND, remaps the display to ANGLE Metal, renders window
# surfaces into IOSurface pbuffers, and hands those buffers to iosc zero-copy.
#
# If stock QtWayland rejects that shim during device validation, the fallback is the
# private-ABI plugin described in docs/qtwayland-angle-iosurface.md: move the same
# swapchain logic into a Qt `wayland-graphics-integration-client` plugin named
# `iosurface`. Do that only if validation proves the generic shim is insufficient.
#
# Build deps:
#   - TARGET: wayland-client (W0 debs, staged in build_base — the driver verifies
#     wayland-client.pc before building this module). Protocol XML is bundled by qtwayland.
#   - HOST: qtwaylandscanner via QT_HOST_PATH (host qtwayland, build-qt-modules.sh stage 1)
#     AND the plain wayland-scanner binary (Wayland::Scanner; container needs Debian's
#     libwayland-bin/libwayland-dev — the driver apt-installs them).
#   - keyboards: proper keymap handling follows QtGui's xkbcommon feature, which is OFF in
#     qtbase round 1 (falls back to raw keysyms). Fixed by qtbase round 2 (+xkbcommon).
# FEATURE_wayland_server=OFF: QtWaylandCompositor is dead weight — KWin speaks
# libwayland-server directly, and iosc is our own compositor.
# Shared Apple/Darwin flags + MACOS-condition fix: qt6-common.mk (rationale in qtbase.mk).

SUBPROJECTS       += qtwayland
QTWAYLAND_VERSION := 6.6.3
DEB_QTWAYLAND_V   ?= $(QTWAYLAND_VERSION)

qtwayland-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtwayland))
	$(call EXTRACT_TAR,qtwayland-everywhere-src-$(QTWAYLAND_VERSION).tar.xz,qtwayland-everywhere-src-$(QTWAYLAND_VERSION),qtwayland)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtwayland)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)
	# qgenericunixthemes never built in our qtbase (gated UNIX AND NOT MACOS; MACOS
	# stays set under the masquerade — the seds only disable `CONDITION MACOS` forms),
	# so its private header isn't staged. The sibling unix fontdb/eventdispatcher/
	# services headers ARE staged (verified), so only the theme hookup goes: nullptr
	# theme = Qt default; the Plasma flavor later gets real theming from
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
# No prereqs on qtbase/wayland (staged in build_base already; mutter.mk precedent).
# No `rm -rf build` (incremental iteration, qtbase.mk).
qtwayland: qtwayland-setup
	mkdir -p $(BUILD_WORK)/qtwayland/build
# WaylandScanner_EXECUTABLE pinned to the HOST binary: the W0 wayland deb stages an
# arm64-iOS wayland-scanner into build_base/usr/bin, and the cross find-root searches
# the sysroot first -> "Exec format error" at codegen. The ECM find module
# (find_program(WaylandScanner_EXECUTABLE ...)) honors a -D pre-set. /usr/bin copy
# exists because the driver apt-installs libwayland-bin every run.
	cd $(BUILD_WORK)/qtwayland/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DWaylandScanner_EXECUTABLE=/usr/bin/wayland-scanner \
		-DFEATURE_wayland_client=ON \
		-DFEATURE_wayland_server=OFF
	+ninja -C $(BUILD_WORK)/qtwayland/build
	+DESTDIR="$(BUILD_STAGE)/qtwayland" ninja -C $(BUILD_WORK)/qtwayland/build install
	$(call AFTER_BUILD,copy,qtwayland,/var/jb/lib/angle)
endif

qtwayland-package: qtwayland-stage
	rm -rf $(BUILD_DIST)/qt6-wayland $(BUILD_DIST)/qt6-wayland-dev
	mkdir -p $(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-wayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: WaylandClient dylibs + every plugin dir (platforms/libqwayland-generic,
	# wayland-shell-integration, wayland-decoration-client, and — once round 2 lands —
	# wayland-graphics-integration-client).
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
