ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# FEATURE_qml_jit=ON since +ios2: QV4's baseline JIT (and the Yarr regexp JIT) run on the device.
# Upstream never got there on our build for two reasons, neither of them an iOS rule:
#  1. configure.cmake only allows arm64 JIT for ANDROID/LINUX/IOS/..., and we configure as Darwin
#     (CMake IOS is false), so -DFEATURE_qml_jit=ON was refused.
#  2. OSAllocatorPosix maps JIT chunks with MAP_JIT on Darwin and canAllocateExecutableMemory() probes
#     with MAP_JIT. MAP_JIT is EINVAL for our fakesigned processes, so the engine silently fell back to
#     the interpreter.
# qtdeclarative-ios-jit.patch adds an APPLE arm64 entry to the feature condition, drops MAP_JIT on iOS
# (JIT pages are plain RW anonymous memory; the assembler's existing W^X flip mprotects each linked range
# RW -> RX, which iOS allows), and replaces the probe with a real execute test run once per process under
# a SIGBUS/SIGSEGV/SIGILL guard: if it faults, QV4 interprets as before. QV4_JIT_PROBE_LOG=1 logs the
# verdict and every new code chunk; QV4_FORCE_INTERPRETER=1 turns the JIT off. No entitlement needed.
# Software scenegraph (QT_QUICK_BACKEND=software, QPainter raster) is the first-light fallback over
# wayland-shm; QtQuick's OpenGL path also resolves EGL/GLES through ANGLE/Metal for accelerated clients.

SUBPROJECTS           += qtdeclarative
QTDECLARATIVE_VERSION := 6.10.3
DEB_QTDECLARATIVE_V   ?= $(QTDECLARATIVE_VERSION)+ios2

qtdeclarative-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtdeclarative))
	$(call EXTRACT_TAR,qtdeclarative-everywhere-src-$(QTDECLARATIVE_VERSION).tar.xz,qtdeclarative-everywhere-src-$(QTDECLARATIVE_VERSION),qtdeclarative)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtdeclarative)
	$(call QT6_APPLY_CVE,qtdeclarative)
	bash /work/recipes/qtdeclarative-ios-fixes.sh $(BUILD_WORK)/qtdeclarative
	if [ ! -e $(BUILD_WORK)/qtdeclarative/.xios-jit-applied ]; then \
		patch -p1 -N --no-backup-if-mismatch -d $(BUILD_WORK)/qtdeclarative < /work/recipes/qtdeclarative-ios-jit.patch && \
		touch $(BUILD_WORK)/qtdeclarative/.xios-jit-applied; \
	fi
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qtdeclarative/.build_complete),)
qtdeclarative:
	@echo "Using previously built qtdeclarative."
else
qtdeclarative: qtdeclarative-setup
	mkdir -p $(BUILD_WORK)/qtdeclarative/build
# 6.10 lane: qml_profiler/qml_preview are OFF on host AND target (they require QtNetwork+qml_network, which the host
# Qt does not build; neither tool is useful on device). Historical note for 6.6: qml_profiler/qml_preview's tools/ subdirs pass the `NOT IOS` gate (we masquerade as
# Darwin), but a cross build hard-requires every gated tool to also exist in the HOST
# Qt6QmlTools package — build-qt-modules.sh's host_module build passes the matching
# -DFEATURE_qml_profiler/preview=ON so both sides agree.
# qmltestrunner has the same gate shape. +ios1 built before anything staged Qt6Test into build_base,
# so QuickTest never appeared; Qt6Test is staged now, and QuickTest would pull in qmltestrunner, which
# the host Qt6QmlTools lacks. Qt6Svg is the same story (staged after +ios1; with it, quick_vectorimage
# turns on and wants the host svgtoqml). Disabling both finds (and the feature, so a stale cache
# cannot force it back) keeps the +ios1 module set.
	cd $(BUILD_WORK)/qtdeclarative/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS) \
		-DFEATURE_qml_jit=ON \
		-DFEATURE_quickcontrols2_macos=OFF \
		-DFEATURE_quickcontrols2_windows=OFF \
		-DFEATURE_qml_profiler=OFF \
		-DFEATURE_qml_preview=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_Qt6Test=ON \
		-DCMAKE_DISABLE_FIND_PACKAGE_Qt6Svg=ON \
		-DFEATURE_quick_vectorimage=OFF
# OOM guard (7.7GiB Docker VM, 16-way default ninja): qmldom TUs are the memory
# hogs; full-speed pass keeps its survivors, -j2 retry finishes the stragglers.
	+ninja -j12 -C $(BUILD_WORK)/qtdeclarative/build || ninja -C $(BUILD_WORK)/qtdeclarative/build -j2
	+DESTDIR="$(BUILD_STAGE)/qtdeclarative" ninja -j12 -C $(BUILD_WORK)/qtdeclarative/build install
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
