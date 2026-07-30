ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# OpenAL Soft for Warzone 2100. PulseAudio is the sole device backend on Xios;
# CoreAudio would bind the daemon-side game process to an iOS app lifecycle.

SUBPROJECTS          += openal-soft
OPENAL_SOFT_VERSION  := 1.25.2
DEB_OPENAL_SOFT_V    ?= $(OPENAL_SOFT_VERSION)+ios1

openal-soft-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/kcat/openal-soft/archive/refs/tags/$(OPENAL_SOFT_VERSION).tar.gz)
	$(call EXTRACT_TAR,$(OPENAL_SOFT_VERSION).tar.gz,openal-soft-$(OPENAL_SOFT_VERSION),openal-soft)
	rm -rf $(BUILD_WORK)/openal-soft/build
	mkdir -p $(BUILD_WORK)/openal-soft/build

ifneq ($(wildcard $(BUILD_WORK)/openal-soft/.build_complete),)
openal-soft:
	@echo "Using previously built OpenAL Soft."
else
openal-soft: openal-soft-setup
	cd $(BUILD_WORK)/openal-soft/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
		-DLIBTYPE=SHARED \
		-DALSOFT_DLOPEN=OFF \
		-DALSOFT_ENABLE_MODULES=OFF \
		-DALSOFT_UTILS=OFF \
		-DALSOFT_EXAMPLES=OFF \
		-DALSOFT_TESTS=OFF \
		-DALSOFT_INSTALL_CONFIG=OFF \
		-DALSOFT_INSTALL_HRTF_DATA=OFF \
		-DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
		-DALSOFT_EMBED_HRTF_DATA=OFF \
		-DALSOFT_BACKEND_PIPEWIRE=OFF \
		-DALSOFT_BACKEND_PULSEAUDIO=ON \
		-DALSOFT_REQUIRE_PULSEAUDIO=ON \
		-DALSOFT_BACKEND_ALSA=OFF \
		-DALSOFT_BACKEND_OSS=OFF \
		-DALSOFT_BACKEND_SNDIO=OFF \
		-DALSOFT_BACKEND_JACK=OFF \
		-DALSOFT_BACKEND_COREAUDIO=OFF \
		-DALSOFT_BACKEND_OBOE=OFF \
		-DALSOFT_BACKEND_OPENSL=OFF \
		-DALSOFT_BACKEND_PORTAUDIO=OFF \
		-DALSOFT_BACKEND_SDL3=OFF \
		-DALSOFT_BACKEND_SDL2=OFF \
		-DALSOFT_BACKEND_WAVE=OFF
	+ninja -C $(BUILD_WORK)/openal-soft/build
	+DESTDIR="$(BUILD_STAGE)/openal-soft" ninja -C $(BUILD_WORK)/openal-soft/build install
	$(call AFTER_BUILD,copy)
endif

openal-soft-package: openal-soft-stage
	rm -rf $(BUILD_DIST)/libopenal1 $(BUILD_DIST)/libopenal-dev
	mkdir -p \
		$(BUILD_DIST)/libopenal1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libopenal-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/openal-soft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libopenal*.dylib \
		$(BUILD_DIST)/libopenal1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/openal-soft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libopenal-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	for directory in cmake pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/openal-soft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" ]; then \
			cp -a "$(BUILD_STAGE)/openal-soft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" \
				"$(BUILD_DIST)/libopenal-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/"; \
		fi; \
	done
	$(call SIGN,libopenal1,general.xml)
	$(call PACK,libopenal1,DEB_OPENAL_SOFT_V)
	$(call PACK,libopenal-dev,DEB_OPENAL_SOFT_V)
	rm -rf $(BUILD_DIST)/libopenal1 $(BUILD_DIST)/libopenal-dev

.PHONY: openal-soft openal-soft-package
