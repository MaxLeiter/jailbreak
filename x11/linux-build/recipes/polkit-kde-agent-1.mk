ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# polkit-kde-agent-1.mk — Plasma's PolicyKit authentication agent
# (libexec/polkit-kde-authentication-agent-1) for rootless iOS.
#
# BLOCKED ON A MISSING DEPENDENCY. Upstream does
# `find_package(PolkitQt6-1 REQUIRED 0.103.0)` and links PolkitQt6-1::Agent. Nothing in
# repo/Packages provides PolkitQt6-1: the published `polkit 124+ios1` build is
# `-Dlibs-only=true` (see polkit.mk) and ships only the C libraries
# libpolkit-gobject-1 / libpolkit-agent-1 plus polkit-dev's headers and .pc files.
# polkit-qt-1 (the Qt binding, current release 0.200.0, built with
# -DQT_MAJOR_VERSION=6 to get the PolkitQt6-1 cmake package) has no recipe here and
# must be built first. This recipe is written and left ready; it will not configure
# until that package exists.
#
# RUNTIME REALITY, stated up front so nobody mistakes this for a working auth path:
# the agent is a client of org.freedesktop.PolicyKit1.Authority on the DBus SYSTEM
# bus, which is owned by polkitd. polkit.mk deliberately does not build polkitd (no
# PAM, no shadow, no setuid auth helper on iOS), and main.cpp's
# PolkitQt1::UnixSessionSubject(getpid()) resolves through
# polkit_unix_session_new_for_process_sync(), i.e. a logind/ConsoleKit session that
# does not exist here. registerListener() will therefore fail and main() calls
# exit(1). Building this package makes the dialog available to a future authority
# implementation; it does not by itself make polkit authentication work.
#
# Staged prerequisites beyond PolkitQt6-1 (all published): qt6-base, qt6-declarative,
# kf6-coreaddons, kf6-crash, kf6-dbusaddons, kf6-i18n, kf6-kirigami, kf6-windowsystem.
# No DocTools dependency, so nothing to cut there.

SUBPROJECTS += polkit-kde-agent-1
POLKITKDEAGENT1_VERSION = $(PLASMA_VERSION)
DEB_POLKITKDEAGENT1_V ?= $(POLKITKDEAGENT1_VERSION)+ios1

polkit-kde-agent-1-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,polkit-kde-agent-1))
	$(call EXTRACT_TAR,polkit-kde-agent-1-$(PLASMA_VERSION).tar.xz,polkit-kde-agent-1-$(PLASMA_VERSION),polkit-kde-agent-1)
	bash /work/recipes/polkit-kde-agent-1-ios-fixes.sh $(BUILD_WORK)/polkit-kde-agent-1
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/polkit-kde-agent-1/.build_complete),)
polkit-kde-agent-1:
	@echo "Using previously built polkit-kde-agent-1."
else
polkit-kde-agent-1: polkit-kde-agent-1-setup
	rm -rf $(BUILD_WORK)/polkit-kde-agent-1/build
	mkdir -p $(BUILD_WORK)/polkit-kde-agent-1/build
	cd $(BUILD_WORK)/polkit-kde-agent-1/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_QCH=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/polkit-kde-agent-1/build
	+DESTDIR="$(BUILD_STAGE)/polkit-kde-agent-1" ninja -C $(BUILD_WORK)/polkit-kde-agent-1/build install
	$(call AFTER_BUILD,copy)
endif

polkit-kde-agent-1-package: polkit-kde-agent-1-stage
	rm -rf $(BUILD_DIST)/polkit-kde-agent-1
	$(call KF6_COPY_RUNTIME,polkit-kde-agent-1,polkit-kde-agent-1)
	# KDE_INSTALL_AUTOSTARTDIR is <sysconfdir>/xdg/autostart, which KF6_COPY_RUNTIME
	# does not walk. Both prefixes are checked because KDEInstallDirs' sysconfdir
	# placement differs between the rootless /var/jb and /var/jb/usr roots.
	if [ -e "$(BUILD_STAGE)/polkit-kde-agent-1$(MEMO_PREFIX)/etc" ]; then \
		mkdir -p $(BUILD_DIST)/polkit-kde-agent-1$(MEMO_PREFIX); \
		cp -a $(BUILD_STAGE)/polkit-kde-agent-1$(MEMO_PREFIX)/etc $(BUILD_DIST)/polkit-kde-agent-1$(MEMO_PREFIX)/; \
	fi
	if [ -e "$(BUILD_STAGE)/polkit-kde-agent-1$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc" ]; then \
		mkdir -p $(BUILD_DIST)/polkit-kde-agent-1$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
		cp -a $(BUILD_STAGE)/polkit-kde-agent-1$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/polkit-kde-agent-1$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/; \
	fi
	# No -dev split: the project installs one libexec executable plus desktop/notifyrc
	# data, no headers and no cmake package.
	# The agent puts a QtQuick dialog on the compositor, so it takes the same
	# GL/platform entitlement tier as systemsettings/plasma-workspace. Validate on
	# device once there is an authority to talk to.
	$(call SIGN,polkit-kde-agent-1,iosc-gl-ent.xml,,,nogeneral)
	$(call PACK,polkit-kde-agent-1,DEB_POLKITKDEAGENT1_V)
	rm -rf $(BUILD_DIST)/polkit-kde-agent-1

.PHONY: polkit-kde-agent-1 polkit-kde-agent-1-package
