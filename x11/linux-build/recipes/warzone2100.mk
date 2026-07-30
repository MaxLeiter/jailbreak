ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += warzone2100
WARZONE2100_VERSION := 4.7.0
DEB_WARZONE2100_V  ?= $(WARZONE2100_VERSION)+ios1

warzone2100-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/Warzone2100/warzone2100/releases/download/$(WARZONE2100_VERSION)/warzone2100_src.tar.xz)
	if [ ! -f "$(BUILD_WORK)/warzone2100/.xios_setup_$(DEB_WARZONE2100_V)" ]; then \
		rm -rf $(BUILD_WORK)/warzone2100; \
		cd $(BUILD_WORK) && tar -xf $(BUILD_SOURCE)/warzone2100_src.tar.xz; \
		$(call DO_PATCH,warzone2100,warzone2100,-p1); \
		touch "$(BUILD_WORK)/warzone2100/.xios_setup_$(DEB_WARZONE2100_V)"; \
	fi
	mkdir -p $(BUILD_WORK)/warzone2100/build

ifneq ($(wildcard $(BUILD_WORK)/warzone2100/.build_complete),)
warzone2100:
	@echo "Using previously built Warzone 2100."
else
warzone2100: warzone2100-setup sdl3 openal-soft physfs
	if [ ! -f "$(BUILD_WORK)/warzone2100/build/build.ninja" ]; then \
		cd $(BUILD_WORK)/warzone2100/build && cmake .. -G Ninja \
			$(DEFAULT_CMAKE_FLAGS) \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
			-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
			-DCMAKE_PROGRAM_PATH=/usr/bin \
			-DWZ_XIOS=ON \
			-DWZ_DISTRIBUTOR=Xios \
			-DWZ_ENABLE_WARNINGS=OFF \
			-DWZ_ENABLE_WARNINGS_AS_ERRORS=OFF \
			-DWZ_ENABLE_BACKEND_VULKAN=OFF \
			-DWZ_ENABLE_BASIS_UNIVERSAL=OFF \
			-DWZ_DEBUG_GFX_API_LEAKS=OFF \
			-DENABLE_GNS_NETWORK_BACKEND=OFF \
			-DENABLE_DISCORD=OFF \
			-DENABLE_DOCS=OFF \
			-DENABLE_NLS=OFF \
			-DWZ_INCLUDE_TERRAIN_HIGH=OFF \
			-DWZ_DOWNLOAD_PREBUILT_PACKAGES=OFF; \
	fi
	+ninja -C $(BUILD_WORK)/warzone2100/build
	+DESTDIR="$(BUILD_STAGE)/warzone2100" ninja -C $(BUILD_WORK)/warzone2100/build install
	$(call AFTER_BUILD,copy)
endif

warzone2100-package: warzone2100-stage
	rm -rf $(BUILD_DIST)/warzone2100
	mkdir -p $(BUILD_DIST)/warzone2100$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/warzone2100$(MEMO_PREFIX)/. $(BUILD_DIST)/warzone2100$(MEMO_PREFIX)/
	if [ -x "$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/warzone2100" ]; then \
		mkdir -p "$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games"; \
		mv "$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/warzone2100" \
			"$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/warzone2100.real"; \
	fi
	mkdir -p \
		$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications
	printf '%s\n' \
		'#!/bin/sh' \
		'export SDL_VIDEODRIVER="$${SDL_VIDEODRIVER:-wayland}"' \
		'export SDL_AUDIODRIVER="$${SDL_AUDIODRIVER:-pulseaudio}"' \
		'export ALSOFT_DRIVERS="$${ALSOFT_DRIVERS:-pulse}"' \
		'export ANGLE_REAL_LIBEGL="$${ANGLE_REAL_LIBEGL:-/var/jb/lib/angle/libEGL.angle.dylib}"' \
		'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/warzone2100.real "$$@"' \
		> $(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/warzone2100
	chmod 0755 $(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/warzone2100
	cp $(BUILD_INFO)/warzone2100.desktop \
		$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/
	rm -rf $(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/warzone2100/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,warzone2100,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,warzone2100,DEB_WARZONE2100_V)
	rm -rf $(BUILD_DIST)/warzone2100

.PHONY: warzone2100 warzone2100-package
