ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# konsole.mk - KDE terminal emulator (KDE Gear 24.08.0).
#
# Requires the kf6-pty unit (kpty.mk) - a terminal cannot be faked without it.
# See kpty.mk for the evidence that openpty()/forkpty() are real on iPhoneOS.
#
# iOS cuts in this first package, all forced by what the Qt/KF6 stack here ships:
#   - Qt::Multimedia is dropped. konsole 24.08.0 lists it in the top-level
#     find_package(Qt6 ...) COMPONENTS and in konsole_LIBS, but no konsole source in
#     this release includes a Multimedia header: the bell is KNotification +
#     QApplication::beep in terminalDisplay/TerminalBell.{h,cpp}, and Session.cpp,
#     SessionController.cpp, TerminalDisplay.cpp, Application.cpp and
#     EditProfileDialog.cpp have no Multimedia include either. The link entry is
#     vestigial; qt6-multimedia is not built for this stack, so it has to go.
#   - widgets/KonsolePrintManager.cpp is replaced by a stub. It is the only konsole
#     file that uses QPrintDialog, and qtbase.mk builds with -DFEATURE_printdialog=OFF
#     / -DFEATURE_printpreviewdialog=OFF (printsupport itself is ON, but the dialogs
#     have no iOS implementation). Same cut Okular, Gwenview and KTextEditor already
#     took. "Print" in the menus becomes a no-op; everything else in konsole is intact.
#   - DBus stays OFF, which is upstream's own default on Apple
#     (USE_DBUS_DEFAULT is only ON for UNIX AND NOT APPLE). That loses konsole's
#     single-instance/`konsole --new-tab` DBus path and the KGlobalAccel shortcut,
#     not terminal function. Flipping it back on later only needs -DUSE_DBUS=ON:
#     Qt6DBus, kf6-dbusaddons and kf6-globalaccel are all available.
#   - KF6DocTools is off via KF6_CMAKE_FLAGS, so doc/manual is skipped by upstream's
#     own if(KF6DocTools_FOUND) guard - no sed needed.
#
# MACOSX_BUNDLE: the only add_executable() targets are `konsole` (GUI - the bundle at
# /var/jb/Applications/KDE/konsole.app is what we want) and tools/uni2characterwidth,
# which upstream wraps in if(KONSOLE_BUILD_UNI2CHARACTERWIDTH), default OFF. konsolepart
# and the two konsoleplugins are MODULEs, not executables. tools/konsoleprofile is a
# shell script installed with install(PROGRAMS). So no CLI binary can silently turn
# into a bundle here.

SUBPROJECTS += konsole
KONSOLE_VERSION = 24.08.0
DEB_KONSOLE_V ?= $(KONSOLE_VERSION)+ios1

konsole-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.kde.org/stable/release-service/24.08.0/src/konsole-$(KONSOLE_VERSION).tar.xz)
	$(call EXTRACT_TAR,konsole-$(KONSOLE_VERSION).tar.xz,konsole-$(KONSOLE_VERSION),konsole)
	bash $(BUILD_INFO)/konsole-ios-fixes.sh $(BUILD_WORK)/konsole
	perl -0777 -i -pe 's/\n    Multimedia\n/\n/s' $(BUILD_WORK)/konsole/CMakeLists.txt
	perl -0777 -i -pe 's/\n    Qt::Multimedia\n/\n/s' $(BUILD_WORK)/konsole/src/CMakeLists.txt
	printf '%s\n' '#include "KonsolePrintManager.h"' '' '#include <QFont>' '#include <QPainter>' '#include <QPoint>' '#include <QRect>' '#include <QtGlobal>' '' '// ios-bringup-no-printdialog: qtbase is built with FEATURE_printdialog=OFF' '// (qprintdialog_unix.cpp needs CUPS, qprintdialog_mac.mm needs AppKit), so the' '// upstream QPrintDialog-driven implementation cannot link here.' 'namespace Konsole' '{' 'KonsolePrintManager::KonsolePrintManager(pDrawBackground drawBackground, pDrawContents drawContents, pColorGet colorGet)' '    : _drawBackground(drawBackground)' '    , _drawContents(drawContents)' '    , _backgroundColor(colorGet)' '{' '}' '' 'void KonsolePrintManager::printRequest(pPrintContent pContent, QWidget *parent)' '{' '    Q_UNUSED(pContent)' '    Q_UNUSED(parent)' '}' '' 'void KonsolePrintManager::printContent(QPainter &painter, bool friendly, QPoint columnsLines, pVTFontGet vtFontGet, pVTFontSet vtFontSet)' '{' '    Q_UNUSED(painter)' '    Q_UNUSED(friendly)' '    Q_UNUSED(columnsLines)' '    Q_UNUSED(vtFontGet)' '    Q_UNUSED(vtFontSet)' '}' '} // namespace Konsole' > $(BUILD_WORK)/konsole/src/widgets/KonsolePrintManager.cpp
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/konsole/.build_complete),)
konsole:
	@echo "Using previously built konsole."
else
konsole: konsole-setup kpty
	rm -rf $(BUILD_WORK)/konsole/build
	mkdir -p $(BUILD_WORK)/konsole/build
	cd $(BUILD_WORK)/konsole/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DUSE_DBUS=OFF \
		-DINSTALL_ICONS=OFF \
		-DKONSOLE_BUILD_UNI2CHARACTERWIDTH=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
	+ninja -C $(BUILD_WORK)/konsole/build
	+DESTDIR="$(BUILD_STAGE)/konsole" ninja -C $(BUILD_WORK)/konsole/build install
	$(call AFTER_BUILD,copy)
endif

konsole-package: konsole-stage
	rm -rf $(BUILD_DIST)/konsole
	mkdir -p $(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	for d in bin lib libexec share lib/qt6/plugins; do \
		if [ -e "$(BUILD_STAGE)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p "$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d)"; \
			cp -a "$(BUILD_STAGE)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" \
				"$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/konsole/Applications/KDE/konsole.app" ]; then \
		mkdir -p "$(BUILD_DIST)/konsole$(MEMO_PREFIX)/Applications/KDE"; \
		cp -a "$(BUILD_STAGE)/konsole/Applications/KDE/konsole.app" "$(BUILD_DIST)/konsole$(MEMO_PREFIX)/Applications/KDE/konsole.app"; \
	fi
	if [ -x "$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/konsole" ]; then \
		mkdir -p "$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/konsole" "$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/konsole.real"; \
	fi
	mkdir -p $(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' '#!/bin/sh' 'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' 'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' '# konsole 24.08 profile default Command is qgetenv("SHELL") with no Unix fallback.' 'export SHELL="$${SHELL:-$(MEMO_PREFIX)/bin/bash}"' 'if [ -x "$(MEMO_PREFIX)/Applications/KDE/konsole.app/konsole" ]; then exec $(MEMO_PREFIX)/Applications/KDE/konsole.app/konsole "$$@"; fi' 'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/konsole.real "$$@"' \
		> $(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/konsole
	chmod 0755 $(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/konsole
	rm -rf $(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/konsole/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,konsole,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,konsole,DEB_KONSOLE_V)
	rm -rf $(BUILD_DIST)/konsole

.PHONY: konsole konsole-package
