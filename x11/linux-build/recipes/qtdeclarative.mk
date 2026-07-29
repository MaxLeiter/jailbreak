ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# FEATURE_qml_jit=OFF, hard: QV4 runs bytecode through its interpreter. The JIT would need
# per-process W^X juggling we don't want in fakesigned processes, and Q_OS_IOS disables it
# at runtime anyway. Software scenegraph (QT_QUICK_BACKEND=software, QPainter raster) is the
# first-light fallback over wayland-shm; QtQuick's OpenGL path also resolves EGL/GLES through
# ANGLE/Metal for accelerated Wayland clients.

SUBPROJECTS           += qtdeclarative
QTDECLARATIVE_VERSION := 6.6.3
DEB_QTDECLARATIVE_V   ?= $(QTDECLARATIVE_VERSION)+ios3

qtdeclarative-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtdeclarative))
	$(call EXTRACT_TAR,qtdeclarative-everywhere-src-$(QTDECLARATIVE_VERSION).tar.xz,qtdeclarative-everywhere-src-$(QTDECLARATIVE_VERSION),qtdeclarative)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtdeclarative)
	bash /work/recipes/qtdeclarative-ios-fixes.sh $(BUILD_WORK)/qtdeclarative
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qtdeclarative/.build_complete),)
qtdeclarative:
	@echo "Using previously built qtdeclarative."
else
qtdeclarative: qtdeclarative-setup
	mkdir -p $(BUILD_WORK)/qtdeclarative/build
# qml_profiler/qml_preview's tools/ subdirs pass the `NOT IOS` gate (we masquerade as
# Darwin), but a cross build hard-requires every gated tool to also exist in the HOST
# Qt6QmlTools package — build-qt-modules.sh's host_module build passes the matching
# -DFEATURE_qml_profiler/preview=ON so both sides agree.
# qmltestrunner has the same gate shape but Qt6Test is absent from build_base, so
# QuickTest never appears — left off.
	cd $(BUILD_WORK)/qtdeclarative/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DFEATURE_qml_jit=OFF \
		-DFEATURE_qml_profiler=ON \
		-DFEATURE_qml_preview=ON
# OOM guard (7.7GiB Docker VM, 16-way default ninja): qmldom TUs are the memory
# hogs; full-speed pass keeps its survivors, -j2 retry finishes the stragglers.
	+ninja -C $(BUILD_WORK)/qtdeclarative/build || ninja -C $(BUILD_WORK)/qtdeclarative/build -j2
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
	# qt6-declarative-dev carries the target `qml` runtime launcher used for the
	# on-device GL smoke test. That executable creates the ANGLE Metal display, so
	# it needs the GPU entitlement set and must skip general.xml/no-container.
	$(call SIGN,qt6-declarative-dev,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,qt6-declarative,DEB_QTDECLARATIVE_V)
	$(call PACK,qt6-declarative-dev,DEB_QTDECLARATIVE_V)
	rm -rf $(BUILD_DIST)/qt6-declarative $(BUILD_DIST)/qt6-declarative-dev

.PHONY: qtdeclarative qtdeclarative-package
