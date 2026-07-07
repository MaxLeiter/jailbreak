ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# swayimg.mk — swayimg, a lightweight Wayland image viewer
# (github.com/artemsen/swayimg). This initial iOS build keeps the native
# Wayland UI, Lua config engine, built-in formats, PNG, and JPEG; heavier
# optional image stacks (EXR/HEIF/AVIF/JP2/JXL/SVG/TIFF/SIXEL/RAW/WebP/GIF)
# and Linux DRM/compositor integration are disabled.
#
# PORTABILITY: the patch stack replaces Linux eventfd/timerfd with pollable
# pipe-backed shims on Apple targets and maps st_mtim to Darwin st_mtime.
# inotify is already optional upstream and compiles out when the header is
# absent.
#
# DEPENDS (target): wayland, libxkbcommon, fontconfig, freetype, luajit,
# libpng, libjpeg-turbo. wayland-protocols is build/data only.

SUBPROJECTS    += swayimg
SWAYIMG_VERSION := 5.4
DEB_SWAYIMG_V   ?= $(SWAYIMG_VERSION)+ios1

swayimg-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/artemsen/swayimg/archive/refs/tags/v$(SWAYIMG_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(SWAYIMG_VERSION).tar.gz,swayimg-$(SWAYIMG_VERSION),swayimg)
	$(call DO_PATCH,swayimg,swayimg,-p1)
	rm -rf $(BUILD_WORK)/swayimg/build && mkdir -p $(BUILD_WORK)/swayimg/build
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
	cpp_args = ['-Wno-error', '-stdlib=libc++', '-isysroot', '$(TARGET_SYSROOT)', '$(PLATFORM_VERSION_MIN)', '-arch', '$(MEMO_ARCH)', '-isystem$(TARGET_SYSROOT)/usr/include/c++/v1', '-isystem$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/c++/v1', '-isystem$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include']\n \
	cpp_link_args = ['-stdlib=libc++', '-isysroot', '$(TARGET_SYSROOT)', '$(PLATFORM_VERSION_MIN)', '-arch', '$(MEMO_ARCH)', '-L$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib', '-Wl,-not_for_dyld_shared_cache', '-liosexec']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/swayimg/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/swayimg/.build_complete),)
swayimg:
	@echo "Using previously built swayimg."
else
swayimg: swayimg-setup wayland wayland-protocols libxkbcommon fontconfig freetype luajit libfmt libpng16 libjpeg-turbo
	cd $(BUILD_WORK)/swayimg/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dversion=$(SWAYIMG_VERSION) \
		-Dwayland=enabled \
		-Ddrm=disabled \
		-Dcompositor=disabled \
		-Dpng=enabled \
		-Djpeg=enabled \
		-Dgif=disabled \
		-Dexr=disabled \
		-Dheif=disabled \
		-Davif=disabled \
		-Djp2=disabled \
		-Djxl=disabled \
		-Dsvg=disabled \
		-Dtiff=disabled \
		-Dsixel=disabled \
		-Draw=disabled \
		-Dwebp=disabled \
		-Dexif=disabled \
		-Dbash=disabled \
		-Dzsh=disabled \
		-Ddesktop=true \
		-Dlicense=true \
		-Ddoc=false \
		-Dluameta=true \
		-Dman=false \
		-Dtests=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/swayimg/build
	+DESTDIR="$(BUILD_STAGE)/swayimg" ninja -C $(BUILD_WORK)/swayimg/build install
	$(call AFTER_BUILD,copy)
endif

swayimg-package: swayimg-stage
	rm -rf $(BUILD_DIST)/swayimg
	mkdir -p $(BUILD_DIST)/swayimg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/swayimg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/swayimg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/swayimg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/swayimg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/swayimg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,swayimg,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,swayimg,DEB_SWAYIMG_V)
	rm -rf $(BUILD_DIST)/swayimg

.PHONY: swayimg swayimg-package
