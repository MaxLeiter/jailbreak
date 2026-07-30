ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += sdl2-image
SDL2_IMAGE_VERSION := 2.8.12
DEB_SDL2_IMAGE_V   ?= $(SDL2_IMAGE_VERSION)+ios1

sdl2-image-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/libsdl-org/SDL_image/releases/download/release-$(SDL2_IMAGE_VERSION)/SDL2_image-$(SDL2_IMAGE_VERSION).tar.gz)
	$(call EXTRACT_TAR,SDL2_image-$(SDL2_IMAGE_VERSION).tar.gz,SDL2_image-$(SDL2_IMAGE_VERSION),sdl2-image)
	rm -rf $(BUILD_WORK)/sdl2-image/build
	mkdir -p $(BUILD_WORK)/sdl2-image/build

ifneq ($(wildcard $(BUILD_WORK)/sdl2-image/.build_complete),)
sdl2-image:
	@echo "Using previously built SDL2_image."
else
sdl2-image: sdl2-image-setup sdl2
	cd $(BUILD_WORK)/sdl2-image/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
		-DSDL2IMAGE_SAMPLES=OFF \
		-DSDL2IMAGE_TESTS=OFF \
		-DSDL2IMAGE_DEPS_SHARED=ON \
		-DSDL2IMAGE_VENDORED=OFF \
		-DSDL2IMAGE_AVIF=OFF \
		-DSDL2IMAGE_BMP=ON \
		-DSDL2IMAGE_GIF=OFF \
		-DSDL2IMAGE_JPG=ON \
		-DSDL2IMAGE_JXL=OFF \
		-DSDL2IMAGE_LBM=OFF \
		-DSDL2IMAGE_PCX=OFF \
		-DSDL2IMAGE_PNG=ON \
		-DSDL2IMAGE_PNM=OFF \
		-DSDL2IMAGE_QOI=OFF \
		-DSDL2IMAGE_SVG=OFF \
		-DSDL2IMAGE_TGA=ON \
		-DSDL2IMAGE_TIF=OFF \
		-DSDL2IMAGE_WEBP=OFF \
		-DSDL2IMAGE_XCF=OFF \
		-DSDL2IMAGE_XPM=OFF \
		-DSDL2IMAGE_XV=OFF
	+ninja -C $(BUILD_WORK)/sdl2-image/build
	+DESTDIR="$(BUILD_STAGE)/sdl2-image" ninja -C $(BUILD_WORK)/sdl2-image/build install
	$(call AFTER_BUILD,copy)
endif

sdl2-image-package: sdl2-image-stage
	rm -rf $(BUILD_DIST)/libsdl2-image-2.0-0 $(BUILD_DIST)/libsdl2-image-dev
	mkdir -p \
		$(BUILD_DIST)/libsdl2-image-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsdl2-image-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/sdl2-image/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libSDL2_image*.dylib \
		$(BUILD_DIST)/libsdl2-image-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/sdl2-image/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libsdl2-image-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	for directory in cmake pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/sdl2-image/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" ]; then \
			cp -a "$(BUILD_STAGE)/sdl2-image/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" \
				"$(BUILD_DIST)/libsdl2-image-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/"; \
		fi; \
	done
	$(call SIGN,libsdl2-image-2.0-0,general.xml)
	$(call PACK,libsdl2-image-2.0-0,DEB_SDL2_IMAGE_V)
	$(call PACK,libsdl2-image-dev,DEB_SDL2_IMAGE_V)
	rm -rf $(BUILD_DIST)/libsdl2-image-2.0-0 $(BUILD_DIST)/libsdl2-image-dev

.PHONY: sdl2-image sdl2-image-package
