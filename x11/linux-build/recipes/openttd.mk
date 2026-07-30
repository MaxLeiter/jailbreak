ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# OpenTTD is a full desktop simulation game, not a touch-game substitute. Xios
# keeps the Darwin ABI/toolchain while selecting OpenTTD's Unix SDL2 frontend.

SUBPROJECTS    += openttd
OPENTTD_VERSION := 15.3
DEB_OPENTTD_V  ?= $(OPENTTD_VERSION)+ios1
OPENTTD_PATCH_REV := 12

openttd-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://cdn.openttd.org/openttd-releases/$(OPENTTD_VERSION)/openttd-$(OPENTTD_VERSION)-source.tar.xz)
	if [ ! -f "$(BUILD_WORK)/openttd/.xios_setup_$(DEB_OPENTTD_V)_p$(OPENTTD_PATCH_REV)" ]; then \
		rm -rf $(BUILD_WORK)/openttd; \
		cd $(BUILD_WORK) && \
			tar -xf $(BUILD_SOURCE)/openttd-$(OPENTTD_VERSION)-source.tar.xz && \
			mkdir -p openttd && \
			cp -a openttd-$(OPENTTD_VERSION)/. openttd/ && \
			rm -rf openttd-$(OPENTTD_VERSION); \
		$(call DO_PATCH,openttd,openttd,-p1); \
		touch "$(BUILD_WORK)/openttd/.xios_setup_$(DEB_OPENTTD_V)_p$(OPENTTD_PATCH_REV)"; \
	fi
	mkdir -p $(BUILD_WORK)/openttd/build-host $(BUILD_WORK)/openttd/build

ifneq ($(wildcard $(BUILD_WORK)/openttd/.build_complete),)
openttd:
	@echo "Using previously built OpenTTD."
else
openttd: openttd-setup
	if [ ! -f "$(BUILD_WORK)/openttd/build-host/build.ninja" ]; then \
		cd $(BUILD_WORK)/openttd/build-host && \
			env CC=/usr/bin/cc CXX=/usr/bin/c++ CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS= \
			cmake .. -G Ninja \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_C_COMPILER=/usr/bin/cc \
			-DCMAKE_CXX_COMPILER=/usr/bin/c++ \
			-DCMAKE_C_FLAGS:STRING= \
			-DCMAKE_CXX_FLAGS:STRING= \
			-DCMAKE_EXE_LINKER_FLAGS:STRING= \
			-DOPTION_TOOLS_ONLY=ON; \
	fi
	+ninja -C $(BUILD_WORK)/openttd/build-host -j"$${JOBS:-4}" tools
	if [ ! -f "$(BUILD_WORK)/openttd/build/build.ninja" ]; then \
		cd $(BUILD_WORK)/openttd/build && cmake .. -G Ninja \
			$(DEFAULT_CMAKE_FLAGS) \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
			-DCMAKE_PREFIX_PATH="$(BUILD_BASE)/var/jb/usr;$(BUILD_BASE)/var/jb" \
			-DHOST_BINARY_DIR=$(BUILD_WORK)/openttd/build-host \
			-DOPENTTD_XIOS=ON \
			-DOPTION_INSTALL_FHS=ON \
			-DOPTION_USE_ASSERTS=OFF \
			-DCMAKE_DISABLE_FIND_PACKAGE_Allegro=TRUE \
			-DCMAKE_DISABLE_FIND_PACKAGE_Fluidsynth=TRUE \
			-DCMAKE_DISABLE_FIND_PACKAGE_LZO=TRUE \
			-DCMAKE_DISABLE_FIND_PACKAGE_OpusFile=TRUE \
			-DCMAKE_DISABLE_FIND_PACKAGE_unofficial-breakpad=TRUE \
			-DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=TRUE; \
	fi
	+ninja -C $(BUILD_WORK)/openttd/build -j"$${JOBS:-4}"
	+DESTDIR="$(BUILD_STAGE)/openttd" ninja -C $(BUILD_WORK)/openttd/build -j"$${JOBS:-4}" install
	$(call AFTER_BUILD,copy)
endif

openttd-package: openttd-stage
	rm -rf $(BUILD_DIST)/openttd
	mkdir -p $(BUILD_DIST)/openttd$(MEMO_PREFIX)
	cp -a $(BUILD_STAGE)/openttd$(MEMO_PREFIX)/. $(BUILD_DIST)/openttd$(MEMO_PREFIX)/
	if [ -x "$(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/games/openttd" ]; then \
		mkdir -p "$(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games"; \
		mv "$(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/games/openttd" \
			"$(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/openttd.real"; \
	fi
	mkdir -p $(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	printf '%s\n' \
		'#!/bin/sh' \
		'export SDL_VIDEODRIVER="$${SDL_VIDEODRIVER:-wayland}"' \
		'export SDL_AUDIODRIVER="$${SDL_AUDIODRIVER:-pulseaudio}"' \
		'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/openttd.real "$$@"' \
		> $(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/openttd
	chmod 0755 $(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/openttd
	rm -rf $(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/doc \
		$(BUILD_DIST)/openttd/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man
	$(call SIGN,openttd,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,openttd,DEB_OPENTTD_V)
	rm -rf $(BUILD_DIST)/openttd

.PHONY: openttd openttd-package
