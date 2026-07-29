ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kate.mk - Kate, from the same kate-24.08.0 tarball kwrite.mk already builds.
#
# kwrite.mk builds this tree with apps/kate commented out; this recipe is its mirror
# image - apps/kwrite commented out - so the two never fight over the kwrite binary.
#
# IMPORTANT packaging constraint: apps/lib builds `libkateprivate`, which BOTH Kate and
# KWrite link, and the published kwrite 24.08.0+ios2 deb already ships
# /var/jb/usr/lib/libkateprivate.24.08.0.dylib (verified in the deb payload). Shipping
# it again from a kate deb would be a dpkg file conflict. So the kate package drops
# libkateprivate* at package time and Depends on kwrite instead. That keeps kwrite.mk
# untouched, and it is safe because both packages build the identical library from the
# identical 24.08.0 sources with the identical flags below - if kwrite.mk's flags ever
# change, this recipe has to change with them.
#
# Cuts, all inherited from kwrite.mk for exactly the same reasons:
#   - addons/ (the whole Kate plugin set: Project, Search & Replace, LSP client,
#     Terminal/Konsole panel, Git, ...). This is the real functional gap versus a Linux
#     Kate; the editor, sessions, session-restore, split views, the file-system browser
#     and the document list are all upstream. Building addons is the obvious follow-up
#     and is a separate unit of work: the LSP/Project addons pull KF6TextEditor extras,
#     Qt6Network and the KF6ThreadWeaver/KF6Sonnet surface, and the Terminal addon
#     needs the konsolepart from konsole.mk.
#   - doc/ (no docbook toolchain), appiumtests/ (no Qt6Test in this qtbase).
#   - KUserFeedback (telemetry, upstream-optional, not published).
#   - The missing <QApplication> include in apps/lib/diff/difflinenumarea.cpp, which
#     upstream gets for free from a PCH; BUILD_PCH is OFF here.
#
# MACOSX_BUNDLE: apps/kate has one add_executable(kate), a GUI target, so the bundle at
# /var/jb/Applications/KDE/kate.app is the wanted outcome. No CLI helper in this tree.

SUBPROJECTS += kate
KATE_VERSION = 24.08.0
DEB_KATE_V ?= $(KATE_VERSION)+ios2

kate-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/kate-$(KATE_VERSION).tar.xz)
	$(call EXTRACT_TAR,kate-$(KATE_VERSION).tar.xz,kate-$(KATE_VERSION),kate)
	sed -i 's/ecm_optional_add_subdirectory(addons)/# ios-bringup-no-addons: ecm_optional_add_subdirectory(addons)/;s/ecm_optional_add_subdirectory(doc)/# ios-bringup-no-doc: ecm_optional_add_subdirectory(doc)/;s/add_subdirectory(appiumtests)/# ios-bringup-no-appiumtests: add_subdirectory(appiumtests)/' $(BUILD_WORK)/kate/CMakeLists.txt
	sed -i 's/ecm_optional_add_subdirectory(kwrite)/# ios-bringup-kate-only: ecm_optional_add_subdirectory(kwrite)/' $(BUILD_WORK)/kate/apps/CMakeLists.txt
	grep -q 'QApplication' $(BUILD_WORK)/kate/apps/lib/diff/difflinenumarea.cpp || sed -i '1i #include <QApplication>' $(BUILD_WORK)/kate/apps/lib/diff/difflinenumarea.cpp
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kate/.build_complete),)
kate:
	@echo "Using previously built kate."
else
kate: kate-setup ktexteditor
	rm -rf $(BUILD_WORK)/kate/build
	mkdir -p $(BUILD_WORK)/kate/build
	cd $(BUILD_WORK)/kate/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_PCH=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KUserFeedback=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6UserFeedback=TRUE
	+ninja -C $(BUILD_WORK)/kate/build
	+DESTDIR="$(BUILD_STAGE)/kate" ninja -C $(BUILD_WORK)/kate/build install
	$(call AFTER_BUILD,copy)
endif

kate-package: kate-stage
	rm -rf $(BUILD_DIST)/kate
	mkdir -p $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	# libkateprivate is owned by the kwrite package; see the header comment.
	rm -f $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libkateprivate*.dylib
	# share/locale is owned by kwrite too, for the same reason: both apps come out
	# of the same tarball, so kwrite already installs every kate*.mo. 1584 of
	# kate's 1601 files were duplicates and dpkg refused the install with
	# "trying to overwrite ... which is also in package kwrite". Kate Depends on
	# kwrite, so the catalogs are always present.
	rm -rf $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale
	if [ -d "$(BUILD_STAGE)/kate/Applications/KDE/kate.app" ]; then \
		mkdir -p "$(BUILD_DIST)/kate$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/kate/Applications/KDE/kate.app" "$(BUILD_DIST)/kate$(MEMO_PREFIX)/Applications/KDE/kate.app"; \
	fi
	if [ -x "$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kate" ]; then \
		mkdir -p "$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kate" "$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/kate.real"; \
	fi
	mkdir -p $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/kate.app/kate" ]; then exec $(MEMO_PREFIX)/Applications/KDE/kate.app/kate "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/kate.real "$$@"' \
		> $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kate
	chmod 0755 $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kate
	rm -rf $(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/kate/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	for file in $$(find $(BUILD_DIST)/kate -type f -exec sh -c "file -ib '{}' | grep -q 'x-mach-binary; charset=binary'" \; -print); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$file 2>/dev/null || true; \
	done
	$(call SIGN,kate,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,kate,DEB_KATE_V)
	rm -rf $(BUILD_DIST)/kate

.PHONY: kate kate-package
