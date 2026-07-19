ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libplasma.mk — libplasma for rootless iOS (Plasma Desktop shell-layer P0).
# This is the first missing package above the completed KF6/KWin tier. It builds
# Plasma's shared C++ libraries, QML imports, and desktop theme data, but it does
# not build plasmashell, plasma-workspace, plasma-desktop, plasma-mobile, or
# plasma-nano. X11 support is disabled; nested Wayland is the first-light path.

SUBPROJECTS += libplasma
LIBPLASMA_VERSION = $(PLASMA_VERSION)
DEB_LIBPLASMA_V ?= $(LIBPLASMA_VERSION)+ios2

libplasma-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),$(call PLASMA_URL,libplasma))
	$(call EXTRACT_TAR,libplasma-$(PLASMA_VERSION).tar.xz,libplasma-$(PLASMA_VERSION),libplasma)
	bash /work/recipes/libplasma-ios-fixes.sh $(BUILD_WORK)/libplasma
	sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' $(BUILD_WORK)/libplasma/CMakeLists.txt
	$(call QT6_WRITE_IOSEXEC_FIXUP)
	$(call QT6_RM_SHADOW_HEADERS)

ifneq ($(wildcard $(BUILD_WORK)/libplasma/.build_complete),)
libplasma:
	@echo "Using previously built libplasma."
else
libplasma: libplasma-setup
	rm -rf $(BUILD_WORK)/libplasma/build
	mkdir -p $(BUILD_WORK)/libplasma/build
	cd $(BUILD_WORK)/libplasma/build && cmake .. \
		-G Ninja \
		$(KF6_CMAKE_FLAGS) \
		-DWITHOUT_X11=ON \
		-DBUILD_QCH=OFF \
		-DBUILD_EXAMPLES=OFF
	+ninja -C $(BUILD_WORK)/libplasma/build
	+DESTDIR="$(BUILD_STAGE)/libplasma" ninja -C $(BUILD_WORK)/libplasma/build install
	$(call AFTER_BUILD,copy)
endif

libplasma-package: libplasma-stage
	rm -rf $(BUILD_DIST)/libplasma $(BUILD_DIST)/libplasma-dev
	$(call KF6_COPY_RUNTIME,libplasma,libplasma)
	$(call KF6_COPY_DEV,libplasma,libplasma)
	$(call SIGN,libplasma,general.xml)
	$(call SIGN,libplasma-dev,general.xml)
	$(call PACK,libplasma,DEB_LIBPLASMA_V)
	$(call PACK,libplasma-dev,DEB_LIBPLASMA_V)
	rm -rf $(BUILD_DIST)/libplasma $(BUILD_DIST)/libplasma-dev

.PHONY: libplasma libplasma-package
