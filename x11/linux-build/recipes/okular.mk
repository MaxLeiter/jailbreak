ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS    += okular
OKULAR_VERSION := 24.08.0
DEB_OKULAR_V   ?= $(OKULAR_VERSION)+ios3

okular-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/okular-$(OKULAR_VERSION).tar.xz)
	$(call EXTRACT_TAR,okular-$(OKULAR_VERSION).tar.xz,okular-$(OKULAR_VERSION),okular)
	# The comicbook backend tries to require KF6Pty on all UNIX platforms. iOS has
	# no packaged KPty yet, and the backend can still build without shelling out.
	sed -i 's/if (UNIX AND NOT ANDROID)/if (UNIX AND NOT ANDROID AND NOT APPLE)/' \
		$(BUILD_WORK)/okular/generators/comicbook/CMakeLists.txt
	# No docbook/linguist or optional integration packages in the first package.
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/okular/CMakeLists.txt
	sed -i 's/Core Test Widgets/Core Widgets/' $(BUILD_WORK)/okular/CMakeLists.txt
	perl -0777 -i -pe 's/\n########### autotests ###############\n\necm_add_test\(autotests\/testimagescaling\.cpp.*?\n\)\n/\n########### autotests disabled for iOS ###############\n/s' \
		$(BUILD_WORK)/okular/generators/poppler/CMakeLists.txt
	perl -0777 -i -pe 's/\n########### autotests ###############\n\nadd_definitions\( -DKDESRCDIR="\$${CMAKE_CURRENT_SOURCE_DIR}\/" \)\necm_add_test\(autotests\/comicbooktest\.cpp.*?\n\)\n/\n########### autotests disabled for iOS ###############\n/s' \
		$(BUILD_WORK)/okular/generators/comicbook/CMakeLists.txt
	sed -i 's/!defined(Q_OS_WIN) && !defined(Q_OS_OSX)/!defined(Q_OS_WIN) \&\& !defined(Q_OS_DARWIN)/g' \
		$(BUILD_WORK)/okular/shell/shell.cpp
	sed -i '/#include <QPrintDialog>/d;/#include <QPrintPreviewDialog>/d' \
		$(BUILD_WORK)/okular/core/document.cpp \
		$(BUILD_WORK)/okular/part/part.cpp
	perl -0777 -i -pe 's/void Part::slotPrint\(\)\n\{.*?\n\}\n\nvoid Part::setupPrint/void Part::slotPrint()\n{\n    if (m_cliPrintAndExit) {\n        exit(EXIT_FAILURE);\n    }\n}\n\nvoid Part::setupPrint/s' \
		$(BUILD_WORK)/okular/part/part.cpp
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/okular/.build_complete),)
okular:
	@echo "Using previously built okular."
else
okular: okular-setup poppler-qt6 threadweaver
	mkdir -p $(BUILD_WORK)/okular/build
	cd $(BUILD_WORK)/okular/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DOKULAR_UI=desktop \
		-DUSE_DBUS=OFF \
		-DFORCE_NOT_REQUIRED_DEPENDENCIES="KF6Wallet;KF6DocTools;Qt6Qml;KF6Purpose;Qt6TextToSpeech;Phonon4Qt6;TIFF;LibSpectre;KExiv2Qt6;CHM;LibZip;DjVuLibre;EPub;Discount;QMobipocket6" \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6Purpose=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_Qt6TextToSpeech=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_Phonon4Qt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_TIFF=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_LibSpectre=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KExiv2Qt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_DJVULIBRE=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_EPub=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_Discount=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_QMobipocket6=TRUE
	+ninja -C $(BUILD_WORK)/okular/build
	+DESTDIR="$(BUILD_STAGE)/okular" ninja -C $(BUILD_WORK)/okular/build install
	$(call AFTER_BUILD,copy)
endif

okular-package: okular-stage
	rm -rf $(BUILD_DIST)/okular
	mkdir -p $(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share; do \
		if [ -e "$(BUILD_STAGE)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/okular/Applications/KDE/okular.app" ]; then \
		mkdir -p "$(BUILD_DIST)/okular$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/okular/Applications/KDE/okular.app" \
			"$(BUILD_DIST)/okular$(MEMO_PREFIX)/Applications/KDE/okular.app"; \
	fi
	mkdir -p $(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'exec $(MEMO_PREFIX)/Applications/KDE/okular.app/okular "$$@"' \
		> $(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/okular
	chmod 0755 $(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/okular
	rm -rf $(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/okular/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,okular,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,okular,DEB_OKULAR_V)
	rm -rf $(BUILD_DIST)/okular

.PHONY: okular okular-package
