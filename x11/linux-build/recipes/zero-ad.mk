ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# 0 A.D. 27.1 is intentionally pinned to the SpiderMonkey 115 generation
# already carried by Xios. Release 28 moved to mozjs 128 and would make the JS
# engine, rather than the game, the critical path.

SUBPROJECTS       += zero-ad
ZERO_AD_VERSION    := 0.27.1
DEB_ZERO_AD_V     ?= $(ZERO_AD_VERSION)+ios1

zero-ad-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://releases.wildfiregames.com/0ad-$(ZERO_AD_VERSION)-unix-build.tar.xz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://releases.wildfiregames.com/0ad-$(ZERO_AD_VERSION)-unix-data.tar.xz)
	if [ ! -f "$(BUILD_WORK)/zero-ad/.xios_setup_$(DEB_ZERO_AD_V)" ]; then \
		rm -rf $(BUILD_WORK)/zero-ad $(BUILD_WORK)/0ad-$(ZERO_AD_VERSION); \
		cd $(BUILD_WORK) && \
			tar -xf $(BUILD_SOURCE)/0ad-$(ZERO_AD_VERSION)-unix-build.tar.xz && \
			mkdir -p zero-ad && \
			cp -a 0ad-$(ZERO_AD_VERSION)/. zero-ad/ && \
			rm -rf 0ad-$(ZERO_AD_VERSION); \
		$(call DO_PATCH,zero-ad,0ad,-p1); \
		touch "$(BUILD_WORK)/zero-ad/.xios_setup_$(DEB_ZERO_AD_V)"; \
	fi

ifneq ($(wildcard $(BUILD_WORK)/zero-ad/.build_complete),)
zero-ad:
	@echo "Using previously built 0 A.D."
else
zero-ad: zero-ad-setup sdl2 boost-games enet openal-soft
	cd $(BUILD_WORK)/zero-ad/libraries/source/premake-core && \
		env OS=Linux CC=/usr/bin/cc CXX=/usr/bin/c++ MAKE=/usr/bin/make \
			JOBS=-j$(JOBS) ./build.sh
	cd $(BUILD_WORK)/zero-ad/build/workspaces && \
		env OS=Linux ./update-workspaces.sh \
			--xios \
			--gles \
			--with-system-mozjs \
			--without-atlas \
			--without-lobby \
			--without-miniupnpc \
			--without-nvtt \
			--without-tests \
			--without-pch \
			--bindir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games \
			--datadir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/0ad \
			--libdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/0ad
	+$(MAKE) -C $(BUILD_WORK)/zero-ad/build/workspaces/gcc \
		config=release \
		CC="$(CC)" CXX="$(CXX)" AR="$(AR)" \
		CFLAGS="$(CFLAGS)" CXXFLAGS="$(CXXFLAGS)" LDFLAGS="$(LDFLAGS)" \
		-j$(JOBS)
	rm -rf $(BUILD_STAGE)/zero-ad
	mkdir -p \
		$(BUILD_STAGE)/zero-ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games \
		$(BUILD_STAGE)/zero-ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/0ad
	cp $(BUILD_WORK)/zero-ad/binaries/system/pyrogenesis \
		$(BUILD_STAGE)/zero-ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/0ad.real
	find $(BUILD_WORK)/zero-ad/binaries/system -maxdepth 1 -type f \
		\( -name '*.dylib' -o -name '*.so' \) \
		-exec cp -a {} $(BUILD_STAGE)/zero-ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/0ad/ \;
	$(call AFTER_BUILD,copy)
endif

zero-ad-package: zero-ad-stage
	rm -rf $(BUILD_DIST)/0ad $(BUILD_WORK)/zero-ad-data
	mkdir -p \
		$(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications \
		$(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/0ad \
		$(BUILD_WORK)/zero-ad-data
	cp -a $(BUILD_STAGE)/zero-ad/$(MEMO_PREFIX)/. \
		$(BUILD_DIST)/0ad/$(MEMO_PREFIX)/
	cd $(BUILD_WORK)/zero-ad-data && \
		tar -xf $(BUILD_SOURCE)/0ad-$(ZERO_AD_VERSION)-unix-data.tar.xz
	data_dir="$$(find $(BUILD_WORK)/zero-ad-data -type d -path '*/binaries/data' -print -quit)"; \
		test -n "$$data_dir"; \
		cp -a "$$data_dir"/. \
			$(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/games/0ad/
	printf '%s\n' \
		'#!/bin/sh' \
		'export SDL_VIDEODRIVER="$${SDL_VIDEODRIVER:-wayland}"' \
		'export SDL_AUDIODRIVER="$${SDL_AUDIODRIVER:-pulseaudio}"' \
		'export ALSOFT_DRIVERS="$${ALSOFT_DRIVERS:-pulse}"' \
		'export ANGLE_REAL_LIBEGL="$${ANGLE_REAL_LIBEGL:-/var/jb/lib/angle/libEGL.angle.dylib}"' \
		'# xios-sdl2 is vendored in a private directory so it never stands in for' \
		'# Procursus SDL2. This is the only thing that puts it on the search path.' \
		'export DYLD_LIBRARY_PATH="$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/xios-sdl2$${DYLD_LIBRARY_PATH:+:$$DYLD_LIBRARY_PATH}"' \
		'exec $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/games/0ad.real "$$@"' \
		> $(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/0ad
	chmod 0755 $(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/0ad
	cp $(BUILD_INFO)/0ad.desktop \
		$(BUILD_DIST)/0ad/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/
	$(call SIGN,0ad,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,0ad,DEB_ZERO_AD_V)
	rm -rf $(BUILD_DIST)/0ad $(BUILD_WORK)/zero-ad-data

.PHONY: zero-ad zero-ad-package
