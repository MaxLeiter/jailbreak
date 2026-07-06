ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# tofi.mk — tofi, a tiny Wayland dmenu/rofi-style launcher
# (github.com/philj56/tofi). It draws with cairo/pangocairo or harfbuzz into
# wl_shm and maps through wlr-layer-shell.
#
# PORTABILITY: upstream already makes librt/libm optional. The iOS patch drops
# the test subdir from cross builds and makes wayland-protocols a target/data
# dependency instead of a native dependency so the staged iOS protocol XML path
# is used while wayland-scanner itself remains native.
#
# DEPENDS (target): wayland, libxkbcommon, cairo, pango/pangocairo, harfbuzz,
# freetype, glib/gio-unix. wayland-protocols is build/data only.

SUBPROJECTS  += tofi
TOFI_VERSION := 0.9.1
DEB_TOFI_V   ?= $(TOFI_VERSION)+ios1

tofi-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/philj56/tofi/archive/refs/tags/v$(TOFI_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(TOFI_VERSION).tar.gz,tofi-$(TOFI_VERSION),tofi)
	$(call DO_PATCH,tofi,tofi,-p1)
	rm -rf $(BUILD_WORK)/tofi/build && mkdir -p $(BUILD_WORK)/tofi/build
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
	c_args = ['-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/tofi/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/tofi/.build_complete),)
tofi:
	@echo "Using previously built tofi."
else
tofi: tofi-setup wayland wayland-protocols libxkbcommon cairo pango harfbuzz freetype glib2.0
	cd $(BUILD_WORK)/tofi/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Db_lto=false \
		-Dman-pages=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/tofi/build
	+DESTDIR="$(BUILD_STAGE)/tofi" ninja -C $(BUILD_WORK)/tofi/build install
	$(call AFTER_BUILD,copy)
endif

tofi-package: tofi-stage
	rm -rf $(BUILD_DIST)/tofi
	mkdir -p $(BUILD_DIST)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc" ]; then \
		cp -a $(BUILD_STAGE)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/tofi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,tofi,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,tofi,DEB_TOFI_V)
	rm -rf $(BUILD_DIST)/tofi

.PHONY: tofi tofi-package
