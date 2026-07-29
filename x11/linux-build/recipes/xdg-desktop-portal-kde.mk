ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# xdg-desktop-portal-kde.mk — the KDE portal BACKEND
# (libexec/xdg-desktop-portal-kde, DBus name org.freedesktop.impl.portal.desktop.kde)
# for rootless iOS.
#
# READ THIS FIRST: the portal FRONTEND (xdg-desktop-portal, which owns
# org.freedesktop.portal.Desktop and dispatches to backends via
# share/xdg-desktop-portal/portals/kde.portal) is NOT in repo/Packages and has no
# recipe in this tree. libportal1 0.7.1+ios1 is the client-side convenience library,
# not the frontend. Until xdg-desktop-portal itself is packaged, this backend builds
# and installs but nothing ever calls it. It is worth building anyway only as the
# second half of a portal story whose first half someone else has to land.
#
# Staged prerequisites (all published): qt6-base (Concurrent/PrintSupport/Widgets +
# the QtGui and QtPrintSupport private headers this links), qt6-declarative
# (Quick/QuickControls2/QuickWidgets), qt6-wayland (WaylandClient + the host
# qtwaylandscanner via QT_HOST_PATH), kwayland, libwayland-dev (share/wayland/wayland.xml
# for the protocol codegen), wayland-protocols, plasma-wayland-protocols,
# libxkbcommon-dev, and the KF6 set in build_info/xdg-desktop-portal-kde.control.
#
# Build walls cut by xdg-desktop-portal-kde-ios-fixes.sh:
#   * Qt6 `Test` is an unconditional REQUIRED COMPONENT of the top-level find_package,
#     and autotests/ links Qt::Test through ecm_add_test(s) (which has no BUILD_TESTING
#     guard of its own). qtbase 6.6.3-4+ios1 ships no Qt6Test cmake package and no
#     libQt6Test dylib. Same cut KIO and KCMUtils already took (see kde-kf6.md
#     "forward-scan fixes folded back into the generator").
#   * src/waylandintegration.cpp includes <linux/input-event-codes.h>. build-kwin.sh
#     already stages that header into the KF6 volume sysroot
#     (${BB}/usr/include/linux/input-event-codes.h), so on procursus-vol-kf6 this
#     resolves; on a cold volume it does not. See the report for the exact line to add
#     to whichever driver runs this target.
#
# Not walls, but they will be noisy: find_package(KIOFuse) is TYPE RUNTIME and
# ecm_find_qmlmodule(org.kde.iconthemes / org.kde.plasma.workspace.dialogs) also
# resolve to TYPE RUNTIME, so a miss is a warning in the feature summary, not a
# configure error. The screencast/remotedesktop portals go through the
# zkde-screencast-unstable-v1 Wayland protocol (no direct PipeWire link at build time)
# and need a compositor that implements it; KWin's KWIN_BUILD_* trims here mean those
# portal interfaces will answer but do nothing useful yet.

SUBPROJECTS += xdg-desktop-portal-kde
XDGDESKTOPPORTALKDE_VERSION = $(PLASMA_VERSION)
DEB_XDGDESKTOPPORTALKDE_V ?= $(XDGDESKTOPPORTALKDE_VERSION)+ios1

xdg-desktop-portal-kde-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,xdg-desktop-portal-kde))
	$(call EXTRACT_TAR,xdg-desktop-portal-kde-$(PLASMA_VERSION).tar.xz,xdg-desktop-portal-kde-$(PLASMA_VERSION),xdg-desktop-portal-kde)
	bash /work/recipes/xdg-desktop-portal-kde-ios-fixes.sh $(BUILD_WORK)/xdg-desktop-portal-kde
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/xdg-desktop-portal-kde/.build_complete),)
xdg-desktop-portal-kde:
	@echo "Using previously built xdg-desktop-portal-kde."
else
xdg-desktop-portal-kde: xdg-desktop-portal-kde-setup
	rm -rf $(BUILD_WORK)/xdg-desktop-portal-kde/build
	mkdir -p $(BUILD_WORK)/xdg-desktop-portal-kde/build
	cd $(BUILD_WORK)/xdg-desktop-portal-kde/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KIOFuse=TRUE
	+ninja -C $(BUILD_WORK)/xdg-desktop-portal-kde/build
	+DESTDIR="$(BUILD_STAGE)/xdg-desktop-portal-kde" ninja -C $(BUILD_WORK)/xdg-desktop-portal-kde/build install
	$(call AFTER_BUILD,copy)
endif

xdg-desktop-portal-kde-package: xdg-desktop-portal-kde-stage
	rm -rf $(BUILD_DIST)/xdg-desktop-portal-kde
	$(call KF6_COPY_RUNTIME,xdg-desktop-portal-kde,xdg-desktop-portal-kde)
	# No -dev split: one libexec executable plus portal/DBus-service/desktop data.
	# The backend puts QtQuick dialogs (file chooser, app chooser, screenshot region
	# select) on the compositor, so it takes the same GL/platform entitlement tier as
	# systemsettings/plasma-workspace.
	$(call SIGN,xdg-desktop-portal-kde,iosc-gl-ent.xml,,,nogeneral)
	$(call PACK,xdg-desktop-portal-kde,DEB_XDGDESKTOPPORTALKDE_V)
	rm -rf $(BUILD_DIST)/xdg-desktop-portal-kde

.PHONY: xdg-desktop-portal-kde xdg-desktop-portal-kde-package
