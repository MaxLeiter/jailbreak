ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Qt 6.10 moved the Wayland client QPA (libQt6WaylandClient + the wayland platform, shell, decoration and
# graphics-integration plugins) INTO qtbase (src/plugins/platforms/wayland), so there is nothing left to
# cross-build from the qtwayland module (FEATURE_wayland_server stays off: KWin speaks libwayland-server and iosc
# is our own compositor). The Wayland port work now lives in qtbase.mk (hunks 11/12) and
# qtbase-wayland-ios-fixes.sh. This recipe only emits the two TRANSITIONAL packages so that a device with the 6.6
# qt6-wayland installed upgrades cleanly: the files moved to qt6-base/qt6-base-dev (which Replaces/Breaks the old
# qt6-wayland), and these debs ship only a README and depend on the new owners.

SUBPROJECTS       += qtwayland
QTWAYLAND_VERSION := 6.10.3
DEB_QTWAYLAND_V   ?= $(QTWAYLAND_VERSION)-1+ios1

qtwayland:
	@echo "qtwayland: client is built inside qtbase 6.10; nothing to build."

qtwayland-package:
	rm -rf $(BUILD_DIST)/qt6-wayland $(BUILD_DIST)/qt6-wayland-dev
	mkdir -p $(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc/qt6-wayland \
		$(BUILD_DIST)/qt6-wayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc/qt6-wayland-dev
	echo "Transitional: the Qt Wayland client now ships in qt6-base." \
		> $(BUILD_DIST)/qt6-wayland/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc/qt6-wayland/README
	echo "Transitional: the Qt Wayland client headers now ship in qt6-base-dev." \
		> $(BUILD_DIST)/qt6-wayland-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc/qt6-wayland-dev/README
	$(call PACK,qt6-wayland,DEB_QTWAYLAND_V)
	$(call PACK,qt6-wayland-dev,DEB_QTWAYLAND_V)
	rm -rf $(BUILD_DIST)/qt6-wayland $(BUILD_DIST)/qt6-wayland-dev

.PHONY: qtwayland qtwayland-package
