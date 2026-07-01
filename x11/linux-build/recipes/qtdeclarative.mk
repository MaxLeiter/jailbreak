ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qtdeclarative.mk — QML + QtQuick for rootless iOS; the big one (Plasma Mobile is
# QML-heavy: plasmashell, kirigami, most of KF6's UI). Cross-build shape:
#   - HOST tools via QT_HOST_PATH: qmlcachegen/qmlimportscanner (from the HOST qtdeclarative,
#     build-qt-modules.sh stage 1), qsb (host qtshadertools), qmltyperegistrar (in qtbase
#     since 6.3). The module compiles its own QML (QtQuick.Controls etc.) at build time
#     with these — this is why there is NO introspection/on-device-scan wall here, unlike
#     the gjs/GNOME track.
#   - TARGET dep: Qt6ShaderTools cmake package from build_base (qtshadertools.mk must have
#     built+staged first; driver runs targets in ladder order, no make-level prereq).
#   - JIT: FEATURE_qml_jit=OFF, hard. QV4 executes bytecode through its interpreter; the
#     JIT would need per-process W^X juggling we don't want in fakesigned processes, and
#     Q_OS_IOS disables it at runtime anyway. Turning the feature off also drops the
#     assembler from the build. NO SpiderMonkey-style wall — this is the reason the KDE
#     track is structurally easier than GNOME (x11-distribution-chooser memory).
#   - Rendering: qtbase round 1 is built with opengl OFF, so QtQuick's RHI has no GL; the
#     always-built SOFTWARE scenegraph adaptation (QT_QUICK_BACKEND=software, QPainter
#     raster) is the first-light path over wayland-shm. GL-on-ANGLE lands with qtbase
#     round 2 (docs/kde-plasma-plan.md, phase Q4).
# Shared Apple/Darwin flags + MACOS-condition fix: qt6-common.mk (rationale in qtbase.mk).

SUBPROJECTS           += qtdeclarative
QTDECLARATIVE_VERSION := 6.6.3
DEB_QTDECLARATIVE_V   ?= $(QTDECLARATIVE_VERSION)

qtdeclarative-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtdeclarative))
	$(call EXTRACT_TAR,qtdeclarative-everywhere-src-$(QTDECLARATIVE_VERSION).tar.xz,qtdeclarative-everywhere-src-$(QTDECLARATIVE_VERSION),qtdeclarative)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtdeclarative)

ifneq ($(wildcard $(BUILD_WORK)/qtdeclarative/.build_complete),)
qtdeclarative:
	@echo "Using previously built qtdeclarative."
else
# No prereqs on qtbase/qtshadertools (staged in build_base already; mutter.mk precedent).
# No `rm -rf build` (incremental iteration, qtbase.mk).
qtdeclarative: qtdeclarative-setup
	mkdir -p $(BUILD_WORK)/qtdeclarative/build
	cd $(BUILD_WORK)/qtdeclarative/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DFEATURE_qml_jit=OFF
	+ninja -C $(BUILD_WORK)/qtdeclarative/build
	+DESTDIR="$(BUILD_STAGE)/qtdeclarative" ninja -C $(BUILD_WORK)/qtdeclarative/build install
	$(call AFTER_BUILD,copy)
endif

qtdeclarative-package: qtdeclarative-stage
	rm -rf $(BUILD_DIST)/qt6-declarative $(BUILD_DIST)/qt6-declarative-dev
	mkdir -p $(BUILD_DIST)/qt6-declarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-declarative-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: Qml/Quick dylibs + the whole QML module tree (qmldir + plugin dylibs +
	# compiled QML) + plugins (qmltooling debug connectors). Nested plugin dylibs are
	# fine for SIGN: it find(1)s every Mach-O in the dist dir.
	cp -a $(BUILD_STAGE)/qtdeclarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-declarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	for d in lib/qt6/qml lib/qt6/plugins; do \
		if [ -d "$(BUILD_STAGE)/qtdeclarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-declarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtdeclarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-declarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue + target tools/apps
	# (bin holds the `qml` runtime launcher — the on-device QML smoke-test binary — plus
	# qmllint and friends when the cross build produces them).
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules bin lib/qt6/libexec; do \
		if [ -e "$(BUILD_STAGE)/qtdeclarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-declarative-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtdeclarative/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-declarative-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-declarative,general.xml)
	$(call SIGN,qt6-declarative-dev,general.xml)
	$(call PACK,qt6-declarative,DEB_QTDECLARATIVE_V)
	$(call PACK,qt6-declarative-dev,DEB_QTDECLARATIVE_V)
	rm -rf $(BUILD_DIST)/qt6-declarative $(BUILD_DIST)/qt6-declarative-dev

.PHONY: qtdeclarative qtdeclarative-package
