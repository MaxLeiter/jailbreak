ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Crispy Doom is a desktop Doom source port, run here as a normal Xios Wayland
# client: SDL2 video through the vendored xios-sdl2 (Wayland + GLES via ANGLE),
# SDL2_mixer + PulseAudio sound, and Doom music through Crispy's in-tree OPL
# emulator (SDL2_mixer is built with MIDI off). The Darwin ABI/toolchain stays;
# Crispy's sources already take their generic Unix paths on the iOS target, so
# the port patches only SDL's entry point (see ports/crispy-doom/patches).
#
# Optional features: SDL2_net is off (not built for Xios; Crispy compiles its
# networking out), libsamplerate and FluidSynth are off (not built for Xios),
# libpng is on (already shipped as libpng16-16; used for PNG screenshots).
#
# Only the crispy-doom binary is built. Upstream's CMake also builds Heretic,
# Hexen, Strife, the setup tool and the dedicated server, none of which this
# package ships, and it has no install rules, so packaging is done by hand.

SUBPROJECTS          += crispy-doom
CRISPY_DOOM_VERSION  := 7.1
DEB_CRISPY_DOOM_V    ?= $(CRISPY_DOOM_VERSION)+ios3
# GitHub's tag archive for crispy-doom-7.1 (upstream publishes no source
# tarball). Pinned so a re-rolled or truncated download fails loudly.
CRISPY_DOOM_SHA256   := f0eb02afb81780165ddc81583ed5648cbee8b3205bcc27e181b3f61eb26f8416
CRISPY_DOOM_TARBALL  := crispy-doom-$(CRISPY_DOOM_VERSION).tar.gz
# Every staged patch feeds the setup stamp. Adding or editing a patch (for
# example a later 0100+ touch-controls patch) therefore re-extracts a pristine
# tree, re-applies the whole series and rebuilds, instead of reusing a tree
# and a .build_complete that predate it.
CRISPY_DOOM_PATCH_ID := $(shell cat $(BUILD_PATCH)/crispy-doom/*.patch 2>/dev/null | sha256sum | cut -c1-12)
CRISPY_DOOM_STAMP    := .xios_setup_$(DEB_CRISPY_DOOM_V)_$(CRISPY_DOOM_PATCH_ID)

crispy-doom-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/fabiangreffrath/crispy-doom/archive/refs/tags/$(CRISPY_DOOM_TARBALL))
	if ! echo "$(CRISPY_DOOM_SHA256)  $(BUILD_SOURCE)/$(CRISPY_DOOM_TARBALL)" | sha256sum -c --status -; then \
		echo "ERROR: $(CRISPY_DOOM_TARBALL) checksum mismatch, removing it for a refetch" >&2; \
		rm -f "$(BUILD_SOURCE)/$(CRISPY_DOOM_TARBALL)"; \
		exit 1; \
	fi
	if [ ! -f "$(BUILD_WORK)/crispy-doom/$(CRISPY_DOOM_STAMP)" ]; then \
		rm -rf $(BUILD_WORK)/crispy-doom $(BUILD_WORK)/crispy-doom-crispy-doom-$(CRISPY_DOOM_VERSION); \
		{ cd $(BUILD_WORK) && \
			tar -xf $(BUILD_SOURCE)/$(CRISPY_DOOM_TARBALL) && \
			mv crispy-doom-crispy-doom-$(CRISPY_DOOM_VERSION) crispy-doom; } || exit 1; \
		$(call DO_PATCH,crispy-doom,crispy-doom,-p1); \
		for patch in $(BUILD_PATCH)/crispy-doom/*.patch; do \
			if [ ! -f "$(BUILD_WORK)/crispy-doom/$$(basename $$patch).done" ]; then \
				echo "ERROR: $$(basename $$patch) did not apply to Crispy Doom $(CRISPY_DOOM_VERSION)" >&2; \
				exit 1; \
			fi; \
		done; \
		cp $(BUILD_WORK)/crispy-doom/COPYING.md $(BUILD_WORK)/crispy-doom/COPYING; \
		touch "$(BUILD_WORK)/crispy-doom/$(CRISPY_DOOM_STAMP)"; \
	fi
	mkdir -p $(BUILD_WORK)/crispy-doom/build

ifneq ($(wildcard $(BUILD_WORK)/crispy-doom/.build_complete),)
ifneq ($(wildcard $(BUILD_WORK)/crispy-doom/$(CRISPY_DOOM_STAMP)),)
CRISPY_DOOM_BUILT := 1
endif
endif

ifeq ($(CRISPY_DOOM_BUILT),1)
crispy-doom:
	@echo "Using previously built Crispy Doom."
else
crispy-doom: crispy-doom-setup
	if [ ! -f "$(BUILD_WORK)/crispy-doom/build/build.ninja" ]; then \
		cd $(BUILD_WORK)/crispy-doom/build && cmake .. -G Ninja \
			$(DEFAULT_CMAKE_FLAGS) \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
			-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
			-DCRISPY_XIOS=ON \
			-DENABLE_SDL2_MIXER=ON \
			-DENABLE_SDL2_NET=OFF \
			-DCMAKE_DISABLE_FIND_PACKAGE_SampleRate=TRUE \
			-DCMAKE_DISABLE_FIND_PACKAGE_FluidSynth=TRUE; \
	fi
	+ninja -C $(BUILD_WORK)/crispy-doom/build -j"$${JOBS:-4}" crispy-doom
	rm -rf $(BUILD_STAGE)/crispy-doom
	mkdir -p \
		$(BUILD_STAGE)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games \
		$(BUILD_STAGE)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/icons/hicolor/128x128/apps
	install -m 0755 $(BUILD_WORK)/crispy-doom/build/src/crispy-doom \
		$(BUILD_STAGE)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/crispy-doom.real
	install -m 0644 $(BUILD_WORK)/crispy-doom/data/doom.png \
		$(BUILD_STAGE)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/icons/hicolor/128x128/apps/crispy-doom.png
	$(call AFTER_BUILD)
endif

crispy-doom-package: crispy-doom-stage
	rm -rf $(BUILD_DIST)/crispy-doom
	mkdir -p $(BUILD_DIST)/crispy-doom$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/crispy-doom$(MEMO_PREFIX)/. $(BUILD_DIST)/crispy-doom$(MEMO_PREFIX)/
	mkdir -p \
		$(BUILD_DIST)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications
	printf '%s\n' \
		'#!/bin/sh' \
		'export SDL_VIDEODRIVER="$${SDL_VIDEODRIVER:-wayland}"' \
		'# profile.d/xios-audio.sh (xios-audio-server) exports SDL_AUDIODRIVER=coreaudio' \
		'# to every login shell, including the session app launcher. xios-sdl2 has no' \
		'# CoreAudio driver, so that value makes SDL_Init(AUDIO) fail and the game runs' \
		'# silent. Treat it like unset; any other explicit choice is respected.' \
		'case "$${SDL_AUDIODRIVER:-}" in ""|coreaudio) SDL_AUDIODRIVER=pulseaudio ;; esac' \
		'export SDL_AUDIODRIVER' \
		'# SDL2 has no executable-name lookup on this target, so its Wayland app_id' \
		'# would be "SDL_App". Native iPadOS mode hands a window to its Home Screen host' \
		'# by app_id, which must match the desktop entry (crispy-doom.desktop).' \
		'export SDL_VIDEO_WAYLAND_WMCLASS="$${SDL_VIDEO_WAYLAND_WMCLASS:-crispy-doom}"' \
		'# xios-sdl2 is vendored in a private directory so it never stands in for' \
		'# Procursus SDL2. This is the only thing that puts it on the search path.' \
		'export DYLD_LIBRARY_PATH="$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/xios-sdl2$${DYLD_LIBRARY_PATH:+:$$DYLD_LIBRARY_PATH}"' \
		'# IWADs (the freedoom package, or your own doom.wad/doom2.wad) live here.' \
		'export DOOMWADDIR="$${DOOMWADDIR:-$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/doom}"' \
		'export DOOMWADPATH="$${DOOMWADPATH:+$$DOOMWADPATH:}$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/doom"' \
		'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/crispy-doom.real "$$@"' \
		> $(BUILD_DIST)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/crispy-doom
	chmod 0755 $(BUILD_DIST)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/crispy-doom
	install -m 0644 $(BUILD_INFO)/crispy-doom.desktop \
		$(BUILD_DIST)/crispy-doom/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/crispy-doom.desktop
	$(call SIGN,crispy-doom,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,crispy-doom,DEB_CRISPY_DOOM_V)
	rm -rf $(BUILD_DIST)/crispy-doom

.PHONY: crispy-doom crispy-doom-package
