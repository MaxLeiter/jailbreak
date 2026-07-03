ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# kwrite.mk - KWrite from the Kate source tree.

SUBPROJECTS += kwrite
KWRITE_VERSION = 24.08.0
DEB_KWRITE_V ?= $(KWRITE_VERSION)+ios2

kwrite-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/kate-$(KWRITE_VERSION).tar.xz)
	$(call EXTRACT_TAR,kate-$(KWRITE_VERSION).tar.xz,kate-$(KWRITE_VERSION),kwrite)
	sed -i 's/ecm_optional_add_subdirectory(addons)/# ios-bringup-no-addons: ecm_optional_add_subdirectory(addons)/;s/ecm_optional_add_subdirectory(doc)/# ios-bringup-no-doc: ecm_optional_add_subdirectory(doc)/;s/add_subdirectory(appiumtests)/# ios-bringup-no-appiumtests: add_subdirectory(appiumtests)/' $(BUILD_WORK)/kwrite/CMakeLists.txt
	sed -i 's/ecm_optional_add_subdirectory(kate)/# ios-bringup-kwrite-only: ecm_optional_add_subdirectory(kate)/' $(BUILD_WORK)/kwrite/apps/CMakeLists.txt
	grep -q 'QApplication' $(BUILD_WORK)/kwrite/apps/lib/diff/difflinenumarea.cpp || sed -i '1i #include <QApplication>' $(BUILD_WORK)/kwrite/apps/lib/diff/difflinenumarea.cpp
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/kwrite/.build_complete),)
kwrite:
	@echo "Using previously built kwrite."
else
kwrite: kwrite-setup ktexteditor
	mkdir -p $(BUILD_WORK)/kwrite/build
	cd $(BUILD_WORK)/kwrite/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_PCH=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KUserFeedback=TRUE
	+ninja -C $(BUILD_WORK)/kwrite/build
	+DESTDIR="$(BUILD_STAGE)/kwrite" ninja -C $(BUILD_WORK)/kwrite/build install
	$(call AFTER_BUILD,copy)
endif

kwrite-package: kwrite-stage
	rm -rf $(BUILD_DIST)/kwrite
	mkdir -p $(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/kwrite/Applications/KDE/kwrite.app" ]; then \
		mkdir -p "$(BUILD_DIST)/kwrite$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/kwrite/Applications/KDE/kwrite.app" "$(BUILD_DIST)/kwrite$(MEMO_PREFIX)/Applications/KDE/kwrite.app"; \
	fi
	if [ -x "$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kwrite" ]; then \
		mkdir -p "$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kwrite" "$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/kwrite.real"; \
	fi
	mkdir -p $(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/kwrite.app/kwrite" ]; then exec $(MEMO_PREFIX)/Applications/KDE/kwrite.app/kwrite "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/kwrite.real "$$@"' \
		> $(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kwrite
	chmod 0755 $(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/kwrite
	rm -rf $(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/kwrite/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	for file in $$(find $(BUILD_DIST)/kwrite -type f -exec sh -c "file -ib '{}' | grep -q 'x-mach-binary; charset=binary'" \; -print); do \
		$(I_N_T) -change @rpath/libintl.dylib @rpath/libgtkintl.dylib $$file 2>/dev/null || true; \
	done
	$(call SIGN,kwrite,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,kwrite,DEB_KWRITE_V)
	rm -rf $(BUILD_DIST)/kwrite

.PHONY: kwrite kwrite-package
