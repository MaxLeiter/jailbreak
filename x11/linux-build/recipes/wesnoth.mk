ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS     += wesnoth
WESNOTH_VERSION := 1.18.5
DEB_WESNOTH_V   ?= $(WESNOTH_VERSION)+ios1
# Bump when the patch series changes, so an existing source tree is
# re-extracted and re-patched without needing a deb-version bump. Same
# mechanism as OPENTTD_PATCH_REV.
WESNOTH_PATCH_REV := 5

wesnoth-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://downloads.sourceforge.net/project/wesnoth/wesnoth-1.18/wesnoth-$(WESNOTH_VERSION)/wesnoth-$(WESNOTH_VERSION).tar.bz2)
	if [ ! -f "$(BUILD_WORK)/wesnoth/.xios_setup_$(DEB_WESNOTH_V)_p$(WESNOTH_PATCH_REV)" ]; then \
		rm -rf $(BUILD_WORK)/wesnoth $(BUILD_WORK)/wesnoth-$(WESNOTH_VERSION); \
		cd $(BUILD_WORK) && \
			tar -xf $(BUILD_SOURCE)/wesnoth-$(WESNOTH_VERSION).tar.bz2 && \
			mv wesnoth-$(WESNOTH_VERSION) wesnoth; \
		$(call DO_PATCH,wesnoth,wesnoth,-p1); \
		for probe in 'src/tls_root_store.cpp:!defined(__IPHONEOS__)' 'src/desktop/notifications.cpp:!defined(WESNOTH_XIOS)' 'src/desktop/battery_info.cpp:!defined(WESNOTH_XIOS)' 'src/desktop/version.cpp:!defined(WESNOTH_XIOS)' 'src/video.cpp:!defined(WESNOTH_XIOS)'; do \
			grep -q "$${probe#*:}" "$(BUILD_WORK)/wesnoth/$${probe%%:*}" || \
				{ echo "ERROR: wesnoth patch series did not apply to $${probe%%:*}" >&2; exit 1; }; \
		done; \
		touch "$(BUILD_WORK)/wesnoth/.xios_setup_$(DEB_WESNOTH_V)_p$(WESNOTH_PATCH_REV)"; \
	fi
	mkdir -p $(BUILD_WORK)/wesnoth/build

ifneq ($(wildcard $(BUILD_WORK)/wesnoth/.build_complete),)
wesnoth:
	@echo "Using previously built Battle for Wesnoth."
else
wesnoth: wesnoth-setup sdl2-image sdl2-mixer boost-games
	if [ ! -f "$(BUILD_WORK)/wesnoth/build/build.ninja" ]; then \
		cd $(BUILD_WORK)/wesnoth/build && cmake .. -G Ninja \
			$(DEFAULT_CMAKE_FLAGS) \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
			-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
			-DWESNOTH_XIOS=ON \
			-DENABLE_GAME=ON \
			-DENABLE_CAMPAIGN_SERVER=OFF \
			-DENABLE_SERVER=OFF \
			-DENABLE_MYSQL=OFF \
			-DENABLE_TESTS=OFF \
			-DENABLE_NLS=OFF \
			-DENABLE_NOTIFICATIONS=OFF \
			-DENABLE_DESIGN_DOCUMENTS=OFF \
			-DENABLE_DESKTOP_ENTRY=OFF \
			-DENABLE_APPDATA_FILE=OFF \
			-DENABLE_LTO=OFF \
			-DENABLE_STRICT_COMPILATION=OFF \
			-DHARDEN=OFF \
			-DPREFERENCES_DIR=.wesnoth \
			-DDATADIRNAME=wesnoth; \
	fi
	+ninja -C $(BUILD_WORK)/wesnoth/build
	+DESTDIR="$(BUILD_STAGE)/wesnoth" ninja -C $(BUILD_WORK)/wesnoth/build install
	$(call AFTER_BUILD,copy)
endif

wesnoth-package: wesnoth-stage
	rm -rf $(BUILD_DIST)/wesnoth
	mkdir -p $(BUILD_DIST)/wesnoth$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/wesnoth$(MEMO_PREFIX)/. $(BUILD_DIST)/wesnoth$(MEMO_PREFIX)/
	if [ -x "$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/wesnoth" ]; then \
		mkdir -p "$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games"; \
		mv "$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/wesnoth" \
			"$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/wesnoth.real"; \
	fi
	mkdir -p \
		$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications
	printf '%s\n' \
		'#!/bin/sh' \
		'export SDL_VIDEODRIVER="$${SDL_VIDEODRIVER:-wayland}"' \
		'export SDL_AUDIODRIVER="$${SDL_AUDIODRIVER:-pulseaudio}"' \
		'export PANGOCAIRO_BACKEND="$${PANGOCAIRO_BACKEND:-fontconfig}"' \
		'# xios-sdl2 is vendored in a private directory so it never stands in for' \
		'# Procursus SDL2. This is the only thing that puts it on the search path.' \
		'export DYLD_LIBRARY_PATH="$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/xios-sdl2$${DYLD_LIBRARY_PATH:+:$$DYLD_LIBRARY_PATH}"' \
		'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/wesnoth.real "$$@"' \
		> $(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/wesnoth
	chmod 0755 $(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/wesnoth
	cp $(BUILD_INFO)/wesnoth.desktop \
		$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/
	rm -rf $(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/wesnoth/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,wesnoth,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,wesnoth,DEB_WESNOTH_V)
	rm -rf $(BUILD_DIST)/wesnoth

.PHONY: wesnoth wesnoth-package
