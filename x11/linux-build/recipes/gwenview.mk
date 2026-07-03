ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gwenview.mk - KDE image viewer.

SUBPROJECTS += gwenview
GWENVIEW_VERSION = 24.08.0
DEB_GWENVIEW_V ?= $(GWENVIEW_VERSION)+ios1

gwenview-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/gwenview-$(GWENVIEW_VERSION).tar.xz)
	$(call EXTRACT_TAR,gwenview-$(GWENVIEW_VERSION).tar.xz,gwenview-$(GWENVIEW_VERSION),gwenview)
	sed -i 's/add_subdirectory(tests)/# ios-bringup-no-tests: add_subdirectory(tests)/;s/add_subdirectory(doc)/# ios-bringup-no-doc: add_subdirectory(doc)/' $(BUILD_WORK)/gwenview/CMakeLists.txt
	sed -i '/add_definitions(-DTRANSLATION_DOMAIN/a add_definitions(-DGWENVIEW_NO_WAYLAND_GESTURES)' $(BUILD_WORK)/gwenview/lib/CMakeLists.txt
	sed -i '/kImageAnnotator-Qt6 PROPERTIES/s/TYPE REQUIRED/TYPE OPTIONAL/' $(BUILD_WORK)/gwenview/CMakeLists.txt
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0">' '<dict>' '  <key>CFBundleExecutable</key>' '  <string>gwenview</string>' '  <key>CFBundleIdentifier</key>' '  <string>org.kde.gwenview</string>' '  <key>CFBundleName</key>' '  <string>Gwenview</string>' '  <key>CFBundlePackageType</key>' '  <string>APPL</string>' '  <key>CFBundleVersion</key>' '  <string>$${RELEASE_SERVICE_VERSION}</string>' '</dict>' '</plist>' > $(BUILD_WORK)/gwenview/app/MacOSXBundleInfo.plist.in
	printf '%s\n' '#include "printhelper.h"' '#include <QtGlobal>' '' 'namespace Gwenview {' 'struct PrintHelperPrivate {};' 'PrintHelper::PrintHelper(QWidget *parent)' '    : d(new PrintHelperPrivate)' '{' '    Q_UNUSED(parent)' '}' 'PrintHelper::~PrintHelper()' '{' '    delete d;' '}' 'void PrintHelper::print(Document::Ptr doc)' '{' '    Q_UNUSED(doc)' '}' 'void PrintHelper::printPreview(Document::Ptr doc)' '{' '    Q_UNUSED(doc)' '}' '} // namespace Gwenview' > $(BUILD_WORK)/gwenview/lib/print/printhelper.cpp
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/gwenview/.build_complete),)
gwenview:
	@echo "Using previously built gwenview."
else
gwenview: gwenview-setup phonon exiv2
	rm -rf $(BUILD_WORK)/gwenview/build
	mkdir -p $(BUILD_WORK)/gwenview/build
	cd $(BUILD_WORK)/gwenview/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DGWENVIEW_SEMANTICINFO_BACKEND=None \
		-DGWENVIEW_NO_WAYLAND_GESTURES=ON \
		-DWITHOUT_X11=ON \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6Purpose=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_PlasmaActivities=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6Baloo=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KDcrawQt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_CFitsio=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_TIFF=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_kImageAnnotator-Qt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_kColorPicker-Qt6=TRUE
	+ninja -C $(BUILD_WORK)/gwenview/build
	+DESTDIR="$(BUILD_STAGE)/gwenview" ninja -C $(BUILD_WORK)/gwenview/build install
	$(call AFTER_BUILD,copy)
endif

gwenview-package: gwenview-stage
	rm -rf $(BUILD_DIST)/gwenview
	mkdir -p $(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/gwenview/Applications/KDE/gwenview.app" ]; then \
		mkdir -p "$(BUILD_DIST)/gwenview$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/gwenview/Applications/KDE/gwenview.app" "$(BUILD_DIST)/gwenview$(MEMO_PREFIX)/Applications/KDE/gwenview.app"; \
	fi
	if [ -x "$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gwenview" ]; then \
		mkdir -p "$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gwenview" "$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/gwenview.real"; \
	fi
	mkdir -p $(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/gwenview.app/gwenview" ]; then exec $(MEMO_PREFIX)/Applications/KDE/gwenview.app/gwenview "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/gwenview.real "$$@"' \
		> $(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gwenview
	chmod 0755 $(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/gwenview
	rm -rf $(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/gwenview/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,gwenview,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,gwenview,DEB_GWENVIEW_V)
	rm -rf $(BUILD_DIST)/gwenview

.PHONY: gwenview gwenview-package
