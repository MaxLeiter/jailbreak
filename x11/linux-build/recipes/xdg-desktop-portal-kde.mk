ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# The KDE portal BACKEND only (libexec/xdg-desktop-portal-kde, DBus name
# org.freedesktop.impl.portal.desktop.kde). The portal FRONTEND
# (xdg-desktop-portal, which owns org.freedesktop.portal.Desktop and
# dispatches to backends) has no recipe in this tree, so until it's
# packaged this backend builds and installs but nothing calls it.
#
# Build fixes (Qt6 Test component, autotests, cross-build hygiene): see
# xdg-desktop-portal-kde-ios-fixes.sh.
#
# On a cold volume (not procursus-vol-kf6), build-kwin.sh's staging of
# <linux/input-event-codes.h> into the sysroot must run first, or
# waylandintegration.cpp fails to find it.

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
