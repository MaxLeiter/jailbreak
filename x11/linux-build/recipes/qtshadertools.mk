ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# First rung of the Qt module ladder: qtdeclarative's QtQuick needs the HOST qsb at build
# time (via QT_HOST_PATH) and the TARGET Qt6ShaderTools cmake package at configure time —
# this recipe provides the target half. glslang + SPIRV-Cross are bundled by Qt.

SUBPROJECTS           += qtshadertools
QTSHADERTOOLS_VERSION := 6.6.3
DEB_QTSHADERTOOLS_V   ?= $(QTSHADERTOOLS_VERSION)+ios1

qtshadertools-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtshadertools))
	$(call EXTRACT_TAR,qtshadertools-everywhere-src-$(QTSHADERTOOLS_VERSION).tar.xz,qtshadertools-everywhere-src-$(QTSHADERTOOLS_VERSION),qtshadertools)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtshadertools)
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/qtshadertools/.build_complete),)
qtshadertools:
	@echo "Using previously built qtshadertools."
else
# NOT a prereq on qtbase: it's already staged in build_base by qtbase.mk's AFTER_BUILD
# copy — listing it would re-trigger that build.
qtshadertools: qtshadertools-setup
	mkdir -p $(BUILD_WORK)/qtshadertools/build
	cd $(BUILD_WORK)/qtshadertools/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/qtshadertools/build
	+DESTDIR="$(BUILD_STAGE)/qtshadertools" ninja -C $(BUILD_WORK)/qtshadertools/build install
	$(call AFTER_BUILD,copy)
endif

qtshadertools-package: qtshadertools-stage
	rm -rf $(BUILD_DIST)/qt6-shadertools $(BUILD_DIST)/qt6-shadertools-dev
	mkdir -p $(BUILD_DIST)/qt6-shadertools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-shadertools-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: the ShaderTools dylibs
	cp -a $(BUILD_STAGE)/qtshadertools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-shadertools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	# dev: headers + cmake packages + .pc + metatypes + module .pri glue + any target tools
	# (bin/qsb, if the cross build produced one — harmless either way, guarded copies)
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules bin lib/qt6/libexec; do \
		if [ -e "$(BUILD_STAGE)/qtshadertools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-shadertools-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtshadertools/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-shadertools-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-shadertools,general.xml)
	$(call SIGN,qt6-shadertools-dev,general.xml)
	$(call PACK,qt6-shadertools,DEB_QTSHADERTOOLS_V)
	$(call PACK,qt6-shadertools-dev,DEB_QTSHADERTOOLS_V)
	rm -rf $(BUILD_DIST)/qt6-shadertools $(BUILD_DIST)/qt6-shadertools-dev

.PHONY: qtshadertools qtshadertools-package
