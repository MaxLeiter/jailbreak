ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# BLOCKED: upstream requires PolkitQt6-1 (find_package REQUIRED 0.103.0), which
# nothing in repo/Packages provides — the published polkit build is
# -Dlibs-only=true (see polkit.mk) and ships only the C libraries. polkit-qt-1
# (the Qt binding, built with -DQT_MAJOR_VERSION=6) has no recipe yet and must
# land first; until then this recipe won't configure.
#
# Even once it builds: polkitd isn't built either (no PAM/shadow on iOS), so
# PolkitQt1::UnixSessionSubject in main.cpp can't resolve a logind session and
# registerListener() exits(1) at runtime. This package makes the dialog
# available to a future authority implementation, not working auth.

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
