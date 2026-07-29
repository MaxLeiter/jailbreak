ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# The Linux hardware layer (UDev/UdevQt, XCB, KF6 DocTools) is cut by
# powerdevil-ios-fixes.sh, not cmake flags — upstream hard-REQUIREs all three with no
# option to disable. See that script for the per-item rationale. Libcap and DDCUtil are
# genuinely optional upstream and turned off via cmake below.
#
# Suspend/hibernate/lid go through org.freedesktop.login1 on the system bus, and the
# charge-threshold/backlight KAuth helpers read /sys — pure QtDBus/QFile paths that
# compile and degrade to "unsupported" at runtime, not build walls. Battery state comes
# from org.freedesktop.UPower, owned on-device by xios-fhs's xios-hwbridged.

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
	# doesn't walk; without powerdevil.desktop there the daemon never autostarts. Both
	# prefixes are checked because sysconfdir placement differs between the rootless
	# /var/jb and /var/jb/usr roots.
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
