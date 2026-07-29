ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# powerdevil.mk — Plasma's power-management daemon (org_kde_powerdevil), its bundled
# action plugins, the power-profile OSD, and kcm_powerdevilprofilesconfig, for rootless
# iOS.
#
# Staged prerequisites (all already published, see repo/Packages): qt6-base,
# qt6-declarative, plasma-activities, plasma-workspace (PW::KWorkspace comes from
# plasma-workspace-dev's LibKWorkspace cmake package), libkscreen (KF6::Screen and
# KF6::ScreenDpms), layer-shell-qt, and the KF6 set listed in build_info/powerdevil.control.
#
# The Linux hardware layer is cut by powerdevil-ios-fixes.sh, not by cmake flags —
# upstream hard-REQUIREs all three of these with no option to turn them off:
#   * UDev + the vendored UdevQt client (daemon/controllers/udevqt*.cpp). The repo's
#     libudev stub (linux-build/udev-stub) only implements the 8 hwdb entry points
#     gnome-bluetooth needs; UdevQt calls ~40 device/enumerate/monitor symbols, so this
#     cannot link. UdevQt exists only to feed BacklightDetector, so both are dropped.
#     The remaining KWinDisplayDetector (daemon/controllers/kwinbrightness.cpp) is a
#     plain DBus client of KWin's brightness interface and is the correct screen
#     brightness path for this stack anyway.
#   * XCB (XCB/RANDR/DPMS). Its only consumer is the KWin/KScreen fade helper effect,
#     which is already `#if HAVE_XCB`-guarded internally; only its unconditional
#     <private/qtx11extras_p.h> include needs the same guard. Same X11-off policy as
#     kglobalacceld/kscreen/plasma-workspace.
#   * KF6 DocTools (a REQUIRED find_package COMPONENT, so KF6_CMAKE_FLAGS's
#     CMAKE_DISABLE_FIND_PACKAGE_KF6DocTools cannot help — it turns the component
#     NOT_FOUND and fails the whole find_package). No docbook toolchain here.
# Libcap and DDCUtil are genuinely optional upstream and are turned off via cmake.
#
# RUNTIME REALITY: suspend/hibernate/lid handling go through org.freedesktop.login1 on
# the system bus (daemon/controllers/suspendcontroller.cpp) and the charge-threshold /
# backlight KAuth helpers read /sys. Those are pure QtDBus/QFile paths, so they compile
# and degrade to "unsupported" at runtime — they are not build walls. Battery state comes
# from org.freedesktop.UPower, which xios-fhs's xios-hwbridged owns on-device (the same
# shim solid.mk's upower device backend already relies on).

SUBPROJECTS += powerdevil
POWERDEVIL_VERSION = $(PLASMA_VERSION)
DEB_POWERDEVIL_V ?= $(POWERDEVIL_VERSION)+ios1

powerdevil-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,powerdevil))
	$(call EXTRACT_TAR,powerdevil-$(PLASMA_VERSION).tar.xz,powerdevil-$(PLASMA_VERSION),powerdevil)
	bash /work/recipes/powerdevil-ios-fixes.sh $(BUILD_WORK)/powerdevil
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/powerdevil/.build_complete),)
powerdevil:
	@echo "Using previously built powerdevil."
else
powerdevil: powerdevil-setup
	rm -rf $(BUILD_WORK)/powerdevil/build
	mkdir -p $(BUILD_WORK)/powerdevil/build
	cd $(BUILD_WORK)/powerdevil/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_Libcap=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_DDCUtil=TRUE
	+ninja -C $(BUILD_WORK)/powerdevil/build
	+DESTDIR="$(BUILD_STAGE)/powerdevil" ninja -C $(BUILD_WORK)/powerdevil/build install
	$(call AFTER_BUILD,copy)
endif

powerdevil-package: powerdevil-stage
	rm -rf $(BUILD_DIST)/powerdevil
	$(call KF6_COPY_RUNTIME,powerdevil,powerdevil)
	# KDE_INSTALL_AUTOSTARTDIR is <sysconfdir>/xdg/autostart, which KF6_COPY_RUNTIME
	# does not walk. Without powerdevil.desktop there the daemon never autostarts.
	# Both prefixes are checked because KDEInstallDirs' sysconfdir placement differs
	# between the rootless /var/jb and /var/jb/usr roots (plasma-workspace.mk hits the
	# same thing).
	if [ -e "$(BUILD_STAGE)/powerdevil$(MEMO_PREFIX)/etc" ]; then \
		mkdir -p $(BUILD_DIST)/powerdevil$(MEMO_PREFIX); \
		cp -a $(BUILD_STAGE)/powerdevil$(MEMO_PREFIX)/etc $(BUILD_DIST)/powerdevil$(MEMO_PREFIX)/; \
	fi
	if [ -e "$(BUILD_STAGE)/powerdevil$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc" ]; then \
		mkdir -p $(BUILD_DIST)/powerdevil$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
		cp -a $(BUILD_STAGE)/powerdevil$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/powerdevil$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/; \
	fi
	# No -dev split: powerdevil installs no public headers and no cmake package
	# (libpowerdevilcore/libpowerdevilconfigcommonprivate are private to the daemon,
	# the KCM, and the bundled action plugins). Same shape as milou.
	# power_profile_osd_service is a real QtQuick + LayerShellQt Wayland client, so the
	# package takes the same GL/platform entitlement tier as systemsettings and
	# plasma-workspace rather than the narrower GPU-only set. Validate on device.
	$(call SIGN,powerdevil,iosc-gl-ent.xml,,,nogeneral)
	$(call PACK,powerdevil,DEB_POWERDEVIL_V)
	rm -rf $(BUILD_DIST)/powerdevil

.PHONY: powerdevil powerdevil-package
