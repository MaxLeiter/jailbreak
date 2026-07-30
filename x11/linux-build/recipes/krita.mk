ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Krita's Qt 6 port is still explicitly marked unstable upstream. Pin the exact
# source commit and preserve "Next" branding so the package cannot be mistaken
# for a stable upstream release.

SUBPROJECTS += krita
KRITA_COMMIT := 5ea9d77087eacc61ce4efa48d60ffe96fd3038ce
KRITA_VERSION := 6.1.0~prealpha+git20260730.5ea9d77
DEB_KRITA_V ?= $(KRITA_VERSION)+ios1

krita-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://invent.kde.org/graphics/krita/-/archive/$(KRITA_COMMIT)/krita-$(KRITA_COMMIT).tar.gz)
	$(call EXTRACT_TAR,krita-$(KRITA_COMMIT).tar.gz,krita-$(KRITA_COMMIT),krita)
	$(call DO_PATCH,krita,krita,-p1)
	for package in libtiff6 libtiff-dev libwebp7 libwebpdemux2 libwebpmux3 libwebp-dev; do \
		deb="$$(find /out -maxdepth 1 -type f -name "$${package}_*_$${XIOS_DEB_ARCH}.deb" \
			-printf '%f\t%p\n' 2>/dev/null | sort -V | tail -1 | cut -f2-)"; \
		[ -n "$$deb" ] || { echo "ERROR: Krita needs current $$package in /out" >&2; exit 1; }; \
		echo "Staging $$deb after Procursus setup"; \
		dpkg-deb -x "$$deb" $(BUILD_BASE); \
	done
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/krita/.build_complete),)
krita:
	@echo "Using previously built Krita."
else
krita: krita-setup
	rm -rf $(BUILD_WORK)/krita/build
	mkdir -p $(BUILD_WORK)/krita/build
	cd $(BUILD_WORK)/krita/build && cmake .. -G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DBUILD_WITH_QT6=ON \
		-DALLOW_UNSTABLE=QT6 \
		-DBRANDING=Next \
		-DXIOS_IOS=ON \
		-DBUILD_TESTING=OFF \
		-DENABLE_UPDATERS=OFF \
		-DFOUNDATION_BUILD=OFF \
		-DBUILD_KRITA_QT_DESIGNER_PLUGINS=OFF \
		-DKRITA_ENABLE_PCH=OFF \
		-DCMAKE_DISABLE_FIND_PACKAGE_PythonLibrary=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_SIP=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_PyQt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_Mlt7=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_OpenColorIO=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_LibMyPaint=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KSeExpr=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_KDcrawQt6=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_GSL=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_OpenEXR=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_HEIF=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_JPEGXL=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_OpenJPEG=TRUE \
		-DCMAKE_DISABLE_FIND_PACKAGE_Poppler=TRUE \
		-DTIFF_HAS_PSD_TAGS=TRUE \
		-DTIFF_CAN_WRITE_PSD_TAGS=TRUE \
		-DUSE_EXTERNAL_RAQM=OFF
	+ninja -C $(BUILD_WORK)/krita/build
	+DESTDIR="$(BUILD_STAGE)/krita" ninja -C $(BUILD_WORK)/krita/build install
	$(call AFTER_BUILD,copy)
endif

krita-package: krita-stage
	rm -rf $(BUILD_DIST)/krita
	mkdir -p $(BUILD_DIST)/krita$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/krita$(MEMO_PREFIX)/. $(BUILD_DIST)/krita$(MEMO_PREFIX)/
	if [ -x "$(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/krita" ]; then \
		mkdir -p "$(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde"; \
		mv "$(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/krita" \
			"$(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/krita.real"; \
	fi
	mkdir -p $(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' \
		'#!/bin/sh' \
		'export QT_QPA_PLATFORM="$${QT_QPA_PLATFORM:-wayland}"' \
		'export QT_WAYLAND_DISABLE_WINDOWDECORATION="$${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"' \
		'export KRITA_NO_STYLE_OVERRIDE="$${KRITA_NO_STYLE_OVERRIDE:-1}"' \
		'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/kde/krita.real "$$@"' \
		> $(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/krita
	chmod 0755 $(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/krita
	rm -rf $(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/krita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,krita,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,krita,DEB_KRITA_V)
	rm -rf $(BUILD_DIST)/krita

.PHONY: krita krita-package
