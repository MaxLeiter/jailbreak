ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# 0 A.D. 27.1 is intentionally pinned to the SpiderMonkey 115 generation
# already carried by Xios. Release 28 moved to mozjs 128 and would make the JS
# engine, rather than the game, the critical path.

SUBPROJECTS       += zero-ad
ZERO_AD_VERSION    := 0.27.1
DEB_ZERO_AD_V     ?= $(ZERO_AD_VERSION)+ios1
# Bump when the patch series changes, so an existing source tree is
# re-extracted and re-patched. Same mechanism as OPENTTD_PATCH_REV.
ZERO_AD_PATCH_REV := 2

# Everything needed to keep a HOST build free of the cross toolchain. Procursus
# exports the cross compiler, flags and binutils, so a host tool picks them up
# silently and fails somewhere that looks unrelated to cross-compilation.
XIOS_HOST_TOOLCHAIN := \
	CC=/usr/bin/cc CXX=/usr/bin/c++ CPP=/usr/bin/cpp \
	AR=/usr/bin/ar RANLIB=/usr/bin/ranlib NM=/usr/bin/nm \
	STRIP=/usr/bin/strip LD=/usr/bin/ld OBJDUMP=/usr/bin/objdump \
	CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS=

zero-ad-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://releases.wildfiregames.com/0ad-$(ZERO_AD_VERSION)-unix-build.tar.xz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://releases.wildfiregames.com/0ad-$(ZERO_AD_VERSION)-unix-data.tar.xz)
	if [ ! -f "$(BUILD_WORK)/zero-ad/.xios_setup_$(DEB_ZERO_AD_V)_p$(ZERO_AD_PATCH_REV)" ]; then \
		rm -rf $(BUILD_WORK)/zero-ad $(BUILD_WORK)/0ad-$(ZERO_AD_VERSION); \
		cd $(BUILD_WORK) && \
			tar -xf $(BUILD_SOURCE)/0ad-$(ZERO_AD_VERSION)-unix-build.tar.xz && \
			mkdir -p zero-ad && \
			cp -a 0ad-$(ZERO_AD_VERSION)/. zero-ad/ && \
			rm -rf 0ad-$(ZERO_AD_VERSION); \
		$(call DO_PATCH,0ad,zero-ad,-p1); \
		grep -q 'trigger = "xios"' $(BUILD_WORK)/zero-ad/build/premake/premake5.lua || \
			{ echo "ERROR: 0ad patch series did not apply" >&2; exit 1; }; \
		touch "$(BUILD_WORK)/zero-ad/.xios_setup_$(DEB_ZERO_AD_V)_p$(ZERO_AD_PATCH_REV)"; \
	fi

ifneq ($(wildcard $(BUILD_WORK)/zero-ad/.build_complete),)
zero-ad:
	@echo "Using previously built 0 A.D."
else
zero-ad: zero-ad-setup sdl2 boost-games enet openal-soft
	# premake and update-workspaces build HOST tools, so they must use the host
	# compiler. Setting it in the environment is not enough: this recipe runs
	# with CC=/CXX= as make COMMAND-LINE variables, which travel through
	# MAKEFLAGS into every nested make and outrank the environment there. The
	# bootstrap therefore compiled premake with the iOS cross clang and died on
	# "'system' is unavailable: not available on iOS" -- a host tool failing a
	# target restriction, which reads as a source problem rather than a leak.
	# Clearing MAKEFLAGS/MFLAGS is what actually makes CC=/usr/bin/cc stick.
	# The cross toolchain reaches these host steps through three separate
	# channels, and fixing one only exposes the next: CC/CXX via MAKEFLAGS,
	# CFLAGS/LDFLAGS via the environment, and AR/RANLIB via the environment as
	# well -- the last produced host archives indexed by the Darwin ranlib, so
	# liblua-lib.a and friends had an empty table of contents and premake5
	# failed to link against its own bundled Lua. Pin the whole host toolchain
	# rather than wait to discover a fourth channel.
	cd $(BUILD_WORK)/zero-ad/libraries/source/premake-core && \
		env -u MAKEFLAGS -u MFLAGS $(XIOS_HOST_TOOLCHAIN) \
			OS=Linux MAKE=/usr/bin/make \
			JOBS=-j$(JOBS) ./build.sh
	# update-workspaces runs premake (a HOST tool) but queries pkg-config for
	# TARGET libraries. 0 A.D. calls bare `pkg-config`, which has none of the
	# cross wrapper's configuration, so every lookup missed the sysroot and
	# mozjs came back not-found. Mirror what build_tools/*-pkg-config exports.
	cd $(BUILD_WORK)/zero-ad/build/workspaces && \
		env -u MAKEFLAGS -u MFLAGS $(XIOS_HOST_TOOLCHAIN) \
			PKG_CONFIG_LIBDIR=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
			PKG_CONFIG_SYSROOT_DIR=$(BUILD_BASE) \
			OS=Linux ./update-workspaces.sh \
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
