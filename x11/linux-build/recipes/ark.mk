ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# ark.mk - KDE archive manager. First pass uses libarchive and KProcess,
# avoiding KF6Pty and KFileMetaData.

SUBPROJECTS += ark
ARK_VERSION = 24.08.0
DEB_ARK_V ?= $(ARK_VERSION)+ios1

ark-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/ark-$(ARK_VERSION).tar.xz)
	$(call EXTRACT_TAR,ark-$(ARK_VERSION).tar.xz,ark-$(ARK_VERSION),ark)
	sed -i '/DocTools/d;/FileMetaData/d' $(BUILD_WORK)/ark/CMakeLists.txt
	perl -0777 -i -pe 's/\nif \(NOT WIN32\)\n\s*find_package\(KF6 [^\n]* COMPONENTS Pty\)\nendif\(\)\n//s' $(BUILD_WORK)/ark/CMakeLists.txt
	sed -i 's/add_subdirectory(doc)/# ios-bringup-no-doc: add_subdirectory(doc)/' $(BUILD_WORK)/ark/CMakeLists.txt
	sed -i '/kdoctools_install/d' $(BUILD_WORK)/ark/CMakeLists.txt
	sed -i '/KF6::FileMetaData/d;/KF6::Pty/d' $(BUILD_WORK)/ark/kerfuffle/CMakeLists.txt
	sed -i 's/add_subdirectory(cliunarchiverplugin)/# ios-bringup-no-kpty: add_subdirectory(cliunarchiverplugin)/' $(BUILD_WORK)/ark/plugins/CMakeLists.txt
	perl -0777 -i -pe 's/\nif \(NOT WIN32\)\n    target_link_libraries\(kerfuffle\n    PUBLIC\n    \)\nendif\(\)\n//s' $(BUILD_WORK)/ark/kerfuffle/CMakeLists.txt
	sed -i '/KPtyProcess/d' $(BUILD_WORK)/ark/kerfuffle/metadatabackup.h
	perl -0pi -e 's/#include <KFileMetaData\/UserMetaData>/#include <QString>\n#include <QStringList>/' $(BUILD_WORK)/ark/kerfuffle/metadatabackup.h
	perl -0777 -i -pe 's/MetadataBackup::MetadataBackup\(const QString &filePath\)\n\{.*?\n\}\n/MetadataBackup::MetadataBackup(const QString &filePath)\n{\n    Q_UNUSED(filePath)\n    m_rating = 0;\n}\n/s; s/void MetadataBackup::restore\(const QString &filePath\)\n\{.*?\n\}\n/void MetadataBackup::restore(const QString &filePath)\n{\n    Q_UNUSED(filePath)\n}\n/s' $(BUILD_WORK)/ark/kerfuffle/metadatabackup.cpp
	sed -i '/#include <KPtyDevice>/d;/#include <KPtyProcess>/d;s/#ifdef Q_OS_WIN/#if 1/;s/#else/#elif 0/' $(BUILD_WORK)/ark/kerfuffle/cliinterface.cpp
	perl -0777 -i -pe 's/\n#if 1\n    m_process = new KProcess;\n#elif 0\n    m_process = new KPtyProcess;\n    m_process->setPtyChannels\(KPtyProcess::StdinChannel\);\n#endif\n/\n    m_process = new KProcess;\n/s' $(BUILD_WORK)/ark/kerfuffle/cliinterface.cpp
	perl -0777 -i -pe 's/\n#ifdef Q_OS_WIN\n    KProcess \*m_process = nullptr;\n#else\n    KPtyProcess \*m_process = nullptr;\n#endif\n/\n    KProcess *m_process = nullptr;\n/s; s/ or KPtyDevice::write\(\), depending on\n     \* the platform/KProcess::write()/s' $(BUILD_WORK)/ark/kerfuffle/cliinterface.h
	perl -0777 -i -pe 's/\n#ifdef Q_OS_WIN\n    m_process->write\(data\);\n#else\n    m_process->pty\(\)->write\(data\);\n#endif\n/\n    m_process->write(data);\n/s' $(BUILD_WORK)/ark/kerfuffle/cliinterface.cpp
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/ark/.build_complete),)
ark:
	@echo "Using previously built ark."
else
ark: ark-setup
	rm -rf $(BUILD_WORK)/ark/build
	mkdir -p $(BUILD_WORK)/ark/build
	cd $(BUILD_WORK)/ark/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DCMAKE_DISABLE_FIND_PACKAGE_LibZip=TRUE
	+ninja -C $(BUILD_WORK)/ark/build
	+DESTDIR="$(BUILD_STAGE)/ark" ninja -C $(BUILD_WORK)/ark/build install
	$(call AFTER_BUILD,copy)
endif

ark-package: ark-stage
	rm -rf $(BUILD_DIST)/ark
	mkdir -p $(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/ark/Applications/KDE/ark.app" ]; then \
		mkdir -p "$(BUILD_DIST)/ark$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/ark/Applications/KDE/ark.app" "$(BUILD_DIST)/ark$(MEMO_PREFIX)/Applications/KDE/ark.app"; \
	fi
	if [ -x "$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/ark" ]; then \
		mkdir -p "$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/ark" "$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/ark.real"; \
	fi
	mkdir -p $(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/ark.app/ark" ]; then exec $(MEMO_PREFIX)/Applications/KDE/ark.app/ark "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/ark.real "$$@"' \
		> $(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/ark
	chmod 0755 $(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/ark
	rm -rf $(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/ark/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,ark,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,ark,DEB_ARK_V)
	rm -rf $(BUILD_DIST)/ark

.PHONY: ark ark-package
