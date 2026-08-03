ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# SDL2 for Xios desktop clients.  This is intentionally the Wayland backend,
# not SDL's UIKit backend: games run as ordinary windows inside iosc and render
# through the existing ANGLE/EGL -> IOSurface path.
#
# VENDORED, NOT SHADOWED. Turning the UIKit backend off means this library
# cannot stand in for Procursus's libsdl2-2.0-0: it exports 836 symbols but
# none of _SDL_UIKitRunApp or _SDL_OnApplicationDidChangeStatusBarOrientation,
# and Procursus packages depend on that name (ffmpeg, libavdevice59, and
# powder, which is a UIKit SDL app). Publishing under the shared name would
# replace theirs repo-wide -- the shape of the openssl incident. So it ships as
# xios-sdl2 in a private library directory, the way ladybird-tls carries its
# own OpenSSL, and the game wrappers point DYLD_LIBRARY_PATH at it.
# Procursus's 2.0.14 also sits at apt priority 1001 against our 100, so the
# shared name would get downgraded out from under the games anyway.

SUBPROJECTS  += sdl2
SDL2_VERSION := 2.32.10
DEB_SDL2_V   ?= $(SDL2_VERSION)+ios3
# Private runtime directory; must match the wrappers in the game recipes.
XIOS_SDL2_LIBDIR := $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/xios-sdl2

sdl2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/libsdl-org/SDL/releases/download/release-$(SDL2_VERSION)/SDL2-$(SDL2_VERSION).tar.gz)
	$(call EXTRACT_TAR,SDL2-$(SDL2_VERSION).tar.gz,SDL2-$(SDL2_VERSION),sdl2)
	$(call DO_PATCH,sdl2,sdl2,-p1)
	rm -rf $(BUILD_WORK)/sdl2/build
	mkdir -p $(BUILD_WORK)/sdl2/build

ifneq ($(wildcard $(BUILD_WORK)/sdl2/.build_complete),)
sdl2:
	@echo "Using previously built SDL2."
else
sdl2: sdl2-setup
	cd $(BUILD_WORK)/sdl2/build && cmake .. \
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
		-DSDL_TEST=OFF \
		-DSDL_TESTS=OFF \
		-DSDL_WAYLAND=ON \
		-DSDL_WAYLAND_SHARED=OFF \
		-DSDL_WAYLAND_LIBDECOR=OFF \
		-DSDL_WAYLAND_QT_TOUCH=OFF \
		-DSDL_X11=OFF \
		-DSDL_KMSDRM=OFF \
		-DSDL_RPI=OFF \
		-DSDL_VIVANTE=OFF \
		-DSDL_OPENGL=OFF \
		-DSDL_OPENGLES=ON \
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
		-DSDL_DISKAUDIO=OFF \
		-DSDL_DUMMYAUDIO=ON \
		-DSDL_DUMMYVIDEO=ON
	+ninja -C $(BUILD_WORK)/sdl2/build
	+DESTDIR="$(BUILD_STAGE)/sdl2" ninja -C $(BUILD_WORK)/sdl2/build install
	$(call AFTER_BUILD,copy)
endif

sdl2-package: sdl2-stage
	rm -rf $(BUILD_DIST)/xios-sdl2 $(BUILD_DIST)/xios-sdl2-dev
	mkdir -p \
		$(BUILD_DIST)/xios-sdl2/$(XIOS_SDL2_LIBDIR) \
		$(BUILD_DIST)/xios-sdl2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# The dylibs keep their SDL2 install name and symlink chain, but land in a
	# private directory so nothing resolves to them by accident -- only the game
	# wrappers, which put this directory on DYLD_LIBRARY_PATH.
	cp -a $(BUILD_STAGE)/sdl2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libSDL2*.dylib \
		$(BUILD_DIST)/xios-sdl2/$(XIOS_SDL2_LIBDIR)/
	cp -a $(BUILD_STAGE)/sdl2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/xios-sdl2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	for directory in cmake pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/sdl2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" ]; then \
			cp -a "$(BUILD_STAGE)/sdl2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" \
				"$(BUILD_DIST)/xios-sdl2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/"; \
		fi; \
	done
	if [ -d "$(BUILD_STAGE)/sdl2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a "$(BUILD_STAGE)/sdl2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" \
			"$(BUILD_DIST)/xios-sdl2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/"; \
	fi

	$(call SIGN,xios-sdl2,general.xml)
	$(call PACK,xios-sdl2,DEB_SDL2_V)
	$(call PACK,xios-sdl2-dev,DEB_SDL2_V)
	rm -rf $(BUILD_DIST)/xios-sdl2 $(BUILD_DIST)/xios-sdl2-dev

.PHONY: sdl2 sdl2-package
