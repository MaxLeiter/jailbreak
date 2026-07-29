ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kde-cli-tools.mk — Plasma's small command-line/helper tools for Xios.
#
# WHAT THIS IS NOT: `kcmshell6`, the standalone KCM launcher, does NOT live here.
# In Plasma 5 it was kde-cli-tools/kcmshell; for KF6 it moved into KCMUtils
# (kcmutils/src/CMakeLists.txt:126 -> src/kcmshell), and the published
# kf6-kcmutils 6.3.0+ios1 deb already ships /var/jb/usr/bin/kcmshell6 as a plain
# Mach-O binary (upstream calls ecm_mark_nongui_executable() on it, so it dodged
# the MACOSX_BUNDLE landmine). This package is therefore NOT on the critical path
# for restoring System Settings pages.
#
# What it does add, in rough order of usefulness on this port:
#   kcm_filetypes            "File Associations" KCM (keditfiletype/) — a real
#                            System Settings page with no Linux-only dependency.
#   plasma-open-settings     resolves systemsettings:// URLs, i.e. the "Configure…"
#                            entries that Plasma UI hands to the desktop portal.
#   kde-open / kioclient6    the URL/file opener Plasma invokes for "Open With".
#   keditfiletype            standalone editor for the same MIME data.
#   kde-inhibit, kbroadcastnotification, kstart, kmimetypefinder, ksvgtopng,
#   kdemv, kdecp, kdeeject, kinfo.
#
# Cuts: WITH_X11=OFF (kstart's only X11 use is Qt::GuiPrivate for startup-id),
# KF6Su is not published so kdesu is left out by upstream's own KF6Su_FOUND
# guard, and DocTools/doc/po are dropped by kde-cli-tools-ios-fixes.sh.
#
# BUILD NOTE: kcm_filetypes calls kcmutils_generate_desktop_file(), which runs
# KF6::kcmdesktopfilegenerator. The cross build stages that as an iOS binary, so
# this unit must be built on a volume where build-plasma-desktop.sh has installed
# its host Python replacement into KCMUtilsMacros (build-plasma-desktop.sh:180-249).

SUBPROJECTS += kde-cli-tools
KDECLITOOLS_VERSION = $(PLASMA_VERSION)
DEB_KDECLITOOLS_V ?= $(KDECLITOOLS_VERSION)+ios1

kde-cli-tools-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,kde-cli-tools))
	$(call EXTRACT_TAR,kde-cli-tools-$(PLASMA_VERSION).tar.xz,kde-cli-tools-$(PLASMA_VERSION),kde-cli-tools)
	bash /work/recipes/kde-cli-tools-ios-fixes.sh $(BUILD_WORK)/kde-cli-tools
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kde-cli-tools/.build_complete),)
kde-cli-tools:
	@echo "Using previously built kde-cli-tools."
else
kde-cli-tools: kde-cli-tools-setup
	rm -rf $(BUILD_WORK)/kde-cli-tools/build
	mkdir -p $(BUILD_WORK)/kde-cli-tools/build
	cd $(BUILD_WORK)/kde-cli-tools/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITH_X11=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6Su=TRUE
	+ninja -C $(BUILD_WORK)/kde-cli-tools/build
	+DESTDIR="$(BUILD_STAGE)/kde-cli-tools" ninja -C $(BUILD_WORK)/kde-cli-tools/build install
	$(call AFTER_BUILD,copy)
endif

# No installed headers or CMake metadata here, so there is no -dev split (milou.mk
# precedent). The GUI-capable tools (keditfiletype, kioclient's dialogs) are Qt
# Wayland clients under iosc, so they take the same GPU-client entitlement tier as
# kscreen's KCM/OSD rather than plain general.xml.
kde-cli-tools-package: kde-cli-tools-stage
	rm -rf $(BUILD_DIST)/kde-cli-tools
	$(call KF6_COPY_RUNTIME,kde-cli-tools,kde-cli-tools)
	$(call SIGN,kde-cli-tools,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,kde-cli-tools,DEB_KDECLITOOLS_V)
	rm -rf $(BUILD_DIST)/kde-cli-tools

.PHONY: kde-cli-tools kde-cli-tools-package
