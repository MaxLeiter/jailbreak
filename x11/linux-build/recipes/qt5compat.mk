ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qt5compat.mk — Qt6Core5Compat (QTextCodec, QRegExp, the big codec set) + the
# Qt5Compat.GraphicalEffects QML module, cross-built for rootless iOS. Added on the KF6
# K0 audit finding: KIO 6.3 hard-REQUIREs Qt6Core5Compat (QTextCodec), and KIO is
# unavoidable in the KWin-enabling KF6 subset (libplasma + kglobalacceld pull it). The
# QML half is a bonus that matters: Qt5Compat.GraphicalEffects is used all over Plasma
# and Kirigami themes.
#
# LADDER POSITION: after qtdeclarative, NOT qtbase-only — the Core5Compat library itself
# needs only qtbase, but the GraphicalEffects QML module needs the target Qt6Qml/Quick
# cmake packages (build_base) + host qmlcachegen/qsb (QT_HOST_PATH). Building here gets
# both halves in one deb. kf6-frameworks' build-kf6.sh gates kio on
# Qt6Core5CompatConfig.cmake, which our AFTER_BUILD copy stages into build_base.
# Shared Apple/Darwin flags + MACOS-condition fix: qt6-common.mk (rationale in qtbase.mk).

SUBPROJECTS       += qt5compat
QT5COMPAT_VERSION := 6.6.3
DEB_QT5COMPAT_V   ?= $(QT5COMPAT_VERSION)+ios1

qt5compat-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qt5compat))
	$(call EXTRACT_TAR,qt5compat-everywhere-src-$(QT5COMPAT_VERSION).tar.xz,qt5compat-everywhere-src-$(QT5COMPAT_VERSION),qt5compat)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qt5compat)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qt5compat/.build_complete),)
qt5compat:
	@echo "Using previously built qt5compat."
else
# No prereqs on qtbase/qtdeclarative (staged in build_base already; mutter.mk precedent).
# No `rm -rf build` (incremental iteration, qtbase.mk).
qt5compat: qt5compat-setup
	mkdir -p $(BUILD_WORK)/qt5compat/build
	cd $(BUILD_WORK)/qt5compat/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/qt5compat/build
	+DESTDIR="$(BUILD_STAGE)/qt5compat" ninja -C $(BUILD_WORK)/qt5compat/build install
	$(call AFTER_BUILD,copy)
endif

qt5compat-package: qt5compat-stage
	rm -rf $(BUILD_DIST)/qt6-5compat $(BUILD_DIST)/qt6-5compat-dev
	mkdir -p $(BUILD_DIST)/qt6-5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-5compat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: Core5Compat dylib + the Qt5Compat QML module tree (GraphicalEffects)
	cp -a $(BUILD_STAGE)/qt5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/qt5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/qml" ]; then \
		mkdir -p $(BUILD_DIST)/qt6-5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6; \
		cp -a $(BUILD_STAGE)/qt5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/qml \
			$(BUILD_DIST)/qt6-5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/qml; \
	fi

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue (KIO's find_package)
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules; do \
		if [ -e "$(BUILD_STAGE)/qt5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-5compat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qt5compat/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-5compat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-5compat,general.xml)
	$(call PACK,qt6-5compat,DEB_QT5COMPAT_V)
	$(call PACK,qt6-5compat-dev,DEB_QT5COMPAT_V)
	rm -rf $(BUILD_DIST)/qt6-5compat $(BUILD_DIST)/qt6-5compat-dev

.PHONY: qt5compat qt5compat-package
