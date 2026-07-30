ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# SDL3 for Xios desktop clients. Warzone 2100 4.7 uses SDL3 and has a complete
# GLES3 renderer and native SDL touch controls, making this the first game lane.

SUBPROJECTS  += sdl3
SDL3_VERSION := 3.2.30
DEB_SDL3_V   ?= $(SDL3_VERSION)+ios2

sdl3-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/libsdl-org/SDL/releases/download/release-$(SDL3_VERSION)/SDL3-$(SDL3_VERSION).tar.gz)
	$(call EXTRACT_TAR,SDL3-$(SDL3_VERSION).tar.gz,SDL3-$(SDL3_VERSION),sdl3)
	$(call DO_PATCH,sdl3,sdl3,-p1)
	rm -rf $(BUILD_WORK)/sdl3/build
	mkdir -p $(BUILD_WORK)/sdl3/build

ifneq ($(wildcard $(BUILD_WORK)/sdl3/.build_complete),)
sdl3:
	@echo "Using previously built SDL3."
else
sdl3: sdl3-setup
	cd $(BUILD_WORK)/sdl3/build && cmake .. \
		-G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
		-DWAYLAND_SCANNER=/usr/local/bin/wayland-scanner \
		-DSDL_XIOS_WAYLAND=ON \
		-DSDL_SHARED=ON \
		-DSDL_STATIC=OFF \
		-DSDL_INSTALL=ON \
		-DSDL_UNINSTALL=OFF \
		-DSDL_TESTS=OFF \
		-DSDL_TEST_LIBRARY=OFF \
		-DSDL_WAYLAND=ON \
		-DSDL_WAYLAND_SHARED=OFF \
		-DSDL_WAYLAND_LIBDECOR=OFF \
		-DSDL_X11=OFF \
		-DSDL_KMSDRM=OFF \
		-DSDL_RPI=OFF \
		-DSDL_ROCKCHIP=OFF \
		-DSDL_VIVANTE=OFF \
		-DSDL_OPENGL=OFF \
		-DSDL_OPENGLES=ON \
		-DSDL_VULKAN=OFF \
		-DSDL_METAL=OFF \
		-DSDL_RENDER_METAL=OFF \
		-DSDL_ALSA=OFF \
		-DSDL_JACK=OFF \
		-DSDL_PIPEWIRE=OFF \
		-DSDL_PULSEAUDIO=ON \
		-DSDL_PULSEAUDIO_SHARED=OFF \
		-DSDL_SNDIO=OFF \
		-DSDL_OSS=OFF \
		-DSDL_HIDAPI=OFF \
		-DSDL_JOYSTICK=OFF \
		-DSDL_HAPTIC=OFF \
		-DSDL_SENSOR=OFF \
		-DSDL_POWER=OFF \
		-DSDL_CAMERA=OFF \
		-DSDL_DIALOG=OFF \
		-DSDL_DISKAUDIO=OFF \
		-DSDL_DUMMYAUDIO=ON \
		-DSDL_DUMMYVIDEO=ON
	+ninja -C $(BUILD_WORK)/sdl3/build
	+DESTDIR="$(BUILD_STAGE)/sdl3" ninja -C $(BUILD_WORK)/sdl3/build install
	$(call AFTER_BUILD,copy)
endif

sdl3-package: sdl3-stage
	rm -rf $(BUILD_DIST)/libsdl3-0 $(BUILD_DIST)/libsdl3-dev
	mkdir -p \
		$(BUILD_DIST)/libsdl3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsdl3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/sdl3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libSDL3*.dylib \
		$(BUILD_DIST)/libsdl3-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/sdl3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libsdl3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	for directory in cmake pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/sdl3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" ]; then \
			cp -a "$(BUILD_STAGE)/sdl3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" \
				"$(BUILD_DIST)/libsdl3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/"; \
		fi; \
	done

	$(call SIGN,libsdl3-0,general.xml)
	$(call PACK,libsdl3-0,DEB_SDL3_V)
	$(call PACK,libsdl3-dev,DEB_SDL3_V)
	rm -rf $(BUILD_DIST)/libsdl3-0 $(BUILD_DIST)/libsdl3-dev

.PHONY: sdl3 sdl3-package
