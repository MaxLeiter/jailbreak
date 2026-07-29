ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# dolphin.mk - KDE file manager (KDE Gear 24.08.0).
#
# iOS cuts in this first package, and exactly what each one costs:
#   - Baloo: upstream sets HAVE_BALOO only when KF6Baloo AND KF6BalooWidgets AND
#     KF6FileMetaData are all found, so disabling the three find_package() calls is a
#     supported configuration, not a patch. Cost: no "Search" panel content-indexing
#     (the Search box falls back to filename search through KIO), no Information-panel
#     tags/rating/comment editing, and no metadata rows in the file tooltip. Directory
#     browsing, previews, copy/move/delete, split view, places, VCS integration and the
#     terminal panel are all unaffected. Neither Baloo nor KFileMetaData is published,
#     and Baloo additionally wants an inotify-shaped file watcher and a LMDB store,
#     which is a separate porting project (note the existing LMDB SIGSYS landmine on
#     this platform).
#   - KUserFeedback: telemetry, upstream-optional, not published.
#   - PackageKitQt6: only used by servicemenuinstaller to offer distro packages for a
#     service menu's missing dependencies. Meaningless here.
#   - X11: dolphin only uses it for a Qt::GuiPrivate startup-notification path.
#   - doc/ and appiumtests/ are add_subdirectory()'d unconditionally by upstream and
#     have to be sed'd out (no docbook toolchain, no Qt6Test in this qtbase).
#
# MACOSX_BUNDLE landmine: src/settings/contextmenu/servicemenuinstaller/CMakeLists.txt
# is a plain add_executable() + install(TARGETS ...) CLI helper. With ECM's
# KDECMakeSettings on Apple it would be built as servicemenuinstaller.app under
# KDE_INSTALL_BUNDLEDIR and vanish from bin/ in the deb - the same failure mode as
# kscreen-doctor. The setup step pins MACOSX_BUNDLE FALSE on that target instead of
# dropping it, so upstream behaviour is preserved and the binary lands in bin/.
# `dolphin` itself IS a GUI target and the .app bundle is what we want there.
#
# Runtime note: HAVE_TERMINAL is TRUE on every non-Windows platform, so the terminal
# panel is compiled. It loads Konsole's KParts plugin (kf6/parts/konsolepart) at
# runtime through KPluginFactory, so it is a Recommends on konsole, not a build dep.

SUBPROJECTS += dolphin
DOLPHIN_VERSION = 24.08.0
DEB_DOLPHIN_V ?= $(DOLPHIN_VERSION)+ios1

dolphin-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/dolphin-$(DOLPHIN_VERSION).tar.xz)
	$(call EXTRACT_TAR,dolphin-$(DOLPHIN_VERSION).tar.xz,dolphin-$(DOLPHIN_VERSION),dolphin)
	sed -i 's/^add_subdirectory(doc)/# ios-bringup-no-doc: add_subdirectory(doc)/;s/^add_subdirectory(appiumtests)/# ios-bringup-no-appiumtests: add_subdirectory(appiumtests)/' $(BUILD_WORK)/dolphin/CMakeLists.txt
	sed -i '/^install(TARGETS servicemenuinstaller/i # ios-bringup-no-bundle: a CLI helper must not become an .app under KDE_INSTALL_BUNDLEDIR\nset_target_properties(servicemenuinstaller PROPERTIES MACOSX_BUNDLE FALSE)' $(BUILD_WORK)/dolphin/src/settings/contextmenu/servicemenuinstaller/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/dolphin/.build_complete),)
dolphin:
	@echo "Using previously built dolphin."
else
dolphin: dolphin-setup phonon
	rm -rf $(BUILD_WORK)/dolphin/build
	mkdir -p $(BUILD_WORK)/dolphin/build
	cd $(BUILD_WORK)/dolphin/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6Baloo=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6BalooWidgets=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6FileMetaData=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6UserFeedback=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_PackageKitQt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/dolphin/build
	+DESTDIR="$(BUILD_STAGE)/dolphin" ninja -C $(BUILD_WORK)/dolphin/build install
	$(call AFTER_BUILD,copy)
endif

dolphin-package: dolphin-stage
	rm -rf $(BUILD_DIST)/dolphin
	mkdir -p $(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/dolphin/Applications/KDE/dolphin.app" ]; then \
		mkdir -p "$(BUILD_DIST)/dolphin$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/dolphin/Applications/KDE/dolphin.app" "$(BUILD_DIST)/dolphin$(MEMO_PREFIX)/Applications/KDE/dolphin.app"; \
	fi
	if [ -x "$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dolphin" ]; then \
		mkdir -p "$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dolphin" "$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/dolphin.real"; \
	fi
	mkdir -p $(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/dolphin.app/dolphin" ]; then exec $(MEMO_PREFIX)/Applications/KDE/dolphin.app/dolphin "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/dolphin.real "$$@"' \
		> $(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dolphin
	chmod 0755 $(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/dolphin
	rm -rf $(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/dolphin/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,dolphin,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,dolphin,DEB_DOLPHIN_V)
	rm -rf $(BUILD_DIST)/dolphin

.PHONY: dolphin dolphin-package
