ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += sdl2-mixer
SDL2_MIXER_VERSION := 2.8.2
DEB_SDL2_MIXER_V   ?= $(SDL2_MIXER_VERSION)+ios1

sdl2-mixer-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/libsdl-org/SDL_mixer/releases/download/release-$(SDL2_MIXER_VERSION)/SDL2_mixer-$(SDL2_MIXER_VERSION).tar.gz)
	$(call EXTRACT_TAR,SDL2_mixer-$(SDL2_MIXER_VERSION).tar.gz,SDL2_mixer-$(SDL2_MIXER_VERSION),sdl2-mixer)
	rm -rf $(BUILD_WORK)/sdl2-mixer/build
	mkdir -p $(BUILD_WORK)/sdl2-mixer/build

ifneq ($(wildcard $(BUILD_WORK)/sdl2-mixer/.build_complete),)
sdl2-mixer:
	@echo "Using previously built SDL2_mixer."
else
sdl2-mixer: sdl2-mixer-setup sdl2
	cd $(BUILD_WORK)/sdl2-mixer/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
		-DSDL2MIXER_SAMPLES=OFF \
		-DSDL2MIXER_DEPS_SHARED=ON \
		-DSDL2MIXER_VENDORED=OFF \
		-DSDL2MIXER_CMD=OFF \
		-DSDL2MIXER_FLAC=OFF \
		-DSDL2MIXER_GME=OFF \
		-DSDL2MIXER_MOD=OFF \
		-DSDL2MIXER_MP3=OFF \
		-DSDL2MIXER_MIDI=OFF \
		-DSDL2MIXER_OPUS=OFF \
		-DSDL2MIXER_VORBIS=VORBISFILE \
		-DSDL2MIXER_WAVE=ON \
		-DSDL2MIXER_WAVPACK=OFF
	+ninja -C $(BUILD_WORK)/sdl2-mixer/build
	+DESTDIR="$(BUILD_STAGE)/sdl2-mixer" ninja -C $(BUILD_WORK)/sdl2-mixer/build install
	$(call AFTER_BUILD,copy)
endif

sdl2-mixer-package: sdl2-mixer-stage
	rm -rf $(BUILD_DIST)/libsdl2-mixer-2.0-0 $(BUILD_DIST)/libsdl2-mixer-dev
	mkdir -p \
		$(BUILD_DIST)/libsdl2-mixer-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsdl2-mixer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/sdl2-mixer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libSDL2_mixer*.dylib \
		$(BUILD_DIST)/libsdl2-mixer-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/sdl2-mixer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libsdl2-mixer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	for directory in cmake pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/sdl2-mixer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" ]; then \
			cp -a "$(BUILD_STAGE)/sdl2-mixer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" \
				"$(BUILD_DIST)/libsdl2-mixer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/"; \
		fi; \
	done
	$(call SIGN,libsdl2-mixer-2.0-0,general.xml)
	$(call PACK,libsdl2-mixer-2.0-0,DEB_SDL2_MIXER_V)
	$(call PACK,libsdl2-mixer-dev,DEB_SDL2_MIXER_V)
	rm -rf $(BUILD_DIST)/libsdl2-mixer-2.0-0 $(BUILD_DIST)/libsdl2-mixer-dev

.PHONY: sdl2-mixer sdl2-mixer-package
