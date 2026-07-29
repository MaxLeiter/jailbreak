ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kcalc.mk - KDE scientific calculator (KDE Gear 24.08.0).
#
# The cheapest of the KDE app batch: Qt6 Core + Widgets, seven already-published KF6
# frameworks, and GMP + MPFR, which Procursus already ships as libgmp10 / libmpfr6.
# gnome-calculator.mk uses the same `mpfr4` Procursus target (Procursus's mpfr4 target
# depends on libgmp10, so one prerequisite pulls both).
#
# Note: build-kde-apps.sh's header says "KCalc was intentionally skipped because GNOME
# Calculator is already in the app set". That was an app-set decision, not a build
# blocker; this recipe exists so the KDE flavor can ship its own calculator. If the
# coordinator still wants only one calculator in the flavor, drop kcalc from the build
# order rather than from the recipe set.
#
# iOS cuts:
#   - KF6DocTools (no docbook toolchain) - already handled by KF6_CMAKE_FLAGS, and
#     upstream guards both kdoctools_install(po) and add_subdirectory(doc) behind
#     if(KF6DocTools_FOUND), so no sed is needed at the top level.
#   - knumber/CMakeLists.txt does an UNCONDITIONAL add_subdirectory( tests ) - it is not
#     inside the if(BUILD_TESTING) that guards kcalc's own autotests/appiumtests - and
#     this qtbase is built with FEATURE_testlib=OFF, so that directory is sed'd out.
#
# MACOSX_BUNDLE: one add_executable(kcalc), a GUI target, so the .app bundle at
# /var/jb/Applications/KDE/kcalc.app is the wanted outcome. knumber is a STATIC lib.
# kcalc does set MACOSX_BUNDLE_INFO_PLIST to its own template but never sets
# MACOSX_BUNDLE_GUI_IDENTIFIER, so the generated Info.plist gets an empty
# CFBundleIdentifier - exactly the same as the already-shipping ark and kwrite bundles.
# If a real identifier is ever needed (e.g. for `uiopen -b`), gwenview.mk shows the fix:
# overwrite MacOSXBundleInfo.plist.in in the setup step.

SUBPROJECTS += kcalc
KCALC_VERSION = 24.08.0
DEB_KCALC_V ?= $(KCALC_VERSION)+ios1

kcalc-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/kcalc-$(KCALC_VERSION).tar.xz)
	$(call EXTRACT_TAR,kcalc-$(KCALC_VERSION).tar.xz,kcalc-$(KCALC_VERSION),kcalc)
	sed -i 's/add_subdirectory( tests )/# ios-bringup-no-tests: add_subdirectory( tests )/' $(BUILD_WORK)/kcalc/knumber/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kcalc/.build_complete),)
kcalc:
	@echo "Using previously built kcalc."
else
kcalc: kcalc-setup mpfr4
	rm -rf $(BUILD_WORK)/kcalc/build
	mkdir -p $(BUILD_WORK)/kcalc/build
	cd $(BUILD_WORK)/kcalc/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DINSTALL_ICONS=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/kcalc/build
	+DESTDIR="$(BUILD_STAGE)/kcalc" ninja -C $(BUILD_WORK)/kcalc/build install
	$(call AFTER_BUILD,copy)
endif

kcalc-package: kcalc-stage
	rm -rf $(BUILD_DIST)/kcalc
	mkdir -p $(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/kcalc/Applications/KDE/kcalc.app" ]; then \
		mkdir -p "$(BUILD_DIST)/kcalc$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/kcalc/Applications/KDE/kcalc.app" "$(BUILD_DIST)/kcalc$(MEMO_PREFIX)/Applications/KDE/kcalc.app"; \
	fi
	if [ -x "$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kcalc" ]; then \
		mkdir -p "$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kcalc" "$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/kcalc.real"; \
	fi
	mkdir -p $(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/kcalc.app/kcalc" ]; then exec $(MEMO_PREFIX)/Applications/KDE/kcalc.app/kcalc "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/kcalc.real "$$@"' \
		> $(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kcalc
	chmod 0755 $(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kcalc
	rm -rf $(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/kcalc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,kcalc,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,kcalc,DEB_KCALC_V)
	rm -rf $(BUILD_DIST)/kcalc

.PHONY: kcalc kcalc-package
