ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# grim (git.sr.ht/~emersion/grim) grabs pixels via wlr-screencopy-unstable-v1 into a wl_shm
# buffer. It only produces pixels if the compositor actually implements screencopy frame
# copy: advertising the global is not enough, it must service .copy / .copy_with_damage
# and deliver a wl_buffer-ready + flags/ready sequence.

SUBPROJECTS  += grim
GRIM_VERSION := 1.4.1
DEB_GRIM_V   ?= $(GRIM_VERSION)+ios1

grim-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://git.sr.ht/~emersion/grim/archive/v$(GRIM_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(GRIM_VERSION).tar.gz,grim-v$(GRIM_VERSION),grim)
	# iOS has no librt (clock_gettime is in libc); patch drops the meson find_library('rt') requirement.
	$(call DO_PATCH,grim,grim,-p1)
	# wordexp()/wordfree() are unavailable on iOS; force-include a minimal replacement.
	cp $(BUILD_INFO)/grim-compat.h $(BUILD_WORK)/grim/grim-compat.h
	rm -rf $(BUILD_WORK)/grim/build && mkdir -p $(BUILD_WORK)/grim/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	c_args = ['-include', '$(BUILD_WORK)/grim/grim-compat.h', '-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/grim/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/grim/.build_complete),)
grim:
	@echo "Using previously built grim."
else
grim: grim-setup wayland wayland-protocols libpixman libpng16 libjpeg-turbo
	# grim's protocol/meson.build uses find_program('wayland-scanner'); put the native scanner
	# the wayland build produced on PATH (same trick as foot/imv).
	cd $(BUILD_WORK)/grim/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Djpeg=enabled \
		-Dman-pages=disabled \
		-Dfish-completions=false \
		-Dbash-completions=false \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/grim/build
	+DESTDIR="$(BUILD_STAGE)/grim" ninja -C $(BUILD_WORK)/grim/build install
	$(call AFTER_BUILD,copy)
endif

grim-package: grim-stage
	rm -rf $(BUILD_DIST)/grim
	mkdir -p $(BUILD_DIST)/grim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/grim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/grim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/grim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/grim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/grim/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,grim,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,grim,DEB_GRIM_V)
	rm -rf $(BUILD_DIST)/grim

.PHONY: grim grim-package
