ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# qtsvg.mk — SVG rendering for rootless iOS: libQt6Svg/libQt6SvgWidgets + the qsvg image
# format plugin + the qsvgicon icon engine. Plasma/KF6 theming is SVG-everywhere (Breeze
# icons, plasma themes via KSvg), so this is a hard KDE-flavor dependency despite being a
# small module. Deps: qtbase only (zlib from build_base). Shared Apple/Darwin flags +
# MACOS-condition fix: qt6-common.mk (rationale in qtbase.mk).

SUBPROJECTS   += qtsvg
QTSVG_VERSION := 6.6.3
DEB_QTSVG_V   ?= $(QTSVG_VERSION)

qtsvg-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call QT6_MODULE_URL,qtsvg))
	$(call EXTRACT_TAR,qtsvg-everywhere-src-$(QTSVG_VERSION).tar.xz,qtsvg-everywhere-src-$(QTSVG_VERSION),qtsvg)
	$(call QT6_DISABLE_MACOS_CONDITIONS,qtsvg)

ifneq ($(wildcard $(BUILD_WORK)/qtsvg/.build_complete),)
qtsvg:
	@echo "Using previously built qtsvg."
else
# No prereq on qtbase (staged in build_base already; mutter.mk precedent).
# No `rm -rf build` (incremental iteration, qtbase.mk).
qtsvg: qtsvg-setup
	mkdir -p $(BUILD_WORK)/qtsvg/build
	cd $(BUILD_WORK)/qtsvg/build && cmake .. \
		-G Ninja \
		$(QT6_MODULE_CMAKE_FLAGS)
	+ninja -C $(BUILD_WORK)/qtsvg/build
	+DESTDIR="$(BUILD_STAGE)/qtsvg" ninja -C $(BUILD_WORK)/qtsvg/build install
	$(call AFTER_BUILD,copy)
endif

qtsvg-package: qtsvg-stage
	rm -rf $(BUILD_DIST)/qt6-svg $(BUILD_DIST)/qt6-svg-dev
	mkdir -p $(BUILD_DIST)/qt6-svg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/qt6-svg-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# runtime: Svg dylibs + plugins (imageformats/libqsvg, iconengines/libqsvgicon)
	cp -a $(BUILD_STAGE)/qtsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libQt6*.dylib \
		$(BUILD_DIST)/qt6-svg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/qtsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins" ]; then \
		mkdir -p $(BUILD_DIST)/qt6-svg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6; \
		cp -a $(BUILD_STAGE)/qtsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins \
			$(BUILD_DIST)/qt6-svg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/qt6/plugins; \
	fi

	# dev: headers + cmake + .pc + metatypes + mkspecs/modules glue
	for d in include lib/cmake lib/pkgconfig lib/metatypes lib/qt6/mkspecs lib/qt6/modules; do \
		if [ -e "$(BUILD_STAGE)/qtsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d" ]; then \
			mkdir -p $(BUILD_DIST)/qt6-svg-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$(dirname $$d); \
			cp -a $(BUILD_STAGE)/qtsvg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d \
				$(BUILD_DIST)/qt6-svg-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/$$d; fi; \
	done

	$(call SIGN,qt6-svg,general.xml)
	$(call PACK,qt6-svg,DEB_QTSVG_V)
	$(call PACK,qt6-svg-dev,DEB_QTSVG_V)
	rm -rf $(BUILD_DIST)/qt6-svg $(BUILD_DIST)/qt6-svg-dev

.PHONY: qtsvg qtsvg-package
