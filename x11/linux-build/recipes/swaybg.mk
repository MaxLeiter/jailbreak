ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# iOS has no librt (clock_gettime lives in libc); the meson librt lookup is
# made non-required in the DO_PATCH step below.

SUBPROJECTS    += swaybg
SWAYBG_VERSION := 1.2.2
DEB_SWAYBG_V   ?= $(SWAYBG_VERSION)+ios1

swaybg-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/swaywm/swaybg/releases/download/v$(SWAYBG_VERSION)/swaybg-$(SWAYBG_VERSION).tar.gz)
	$(call EXTRACT_TAR,swaybg-$(SWAYBG_VERSION).tar.gz,swaybg-$(SWAYBG_VERSION),swaybg)
	$(call DO_PATCH,swaybg,swaybg,-p1)
	rm -rf $(BUILD_WORK)/swaybg/build && mkdir -p $(BUILD_WORK)/swaybg/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/swaybg/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/swaybg/.build_complete),)
swaybg:
	@echo "Using previously built swaybg."
else
swaybg: swaybg-setup wayland wayland-protocols cairo
	cd $(BUILD_WORK)/swaybg/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dgdk-pixbuf=disabled \
		-Dman-pages=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/swaybg/build
	+DESTDIR="$(BUILD_STAGE)/swaybg" ninja -C $(BUILD_WORK)/swaybg/build install
	$(call AFTER_BUILD,copy)
endif

swaybg-package: swaybg-stage
	rm -rf $(BUILD_DIST)/swaybg
	mkdir -p $(BUILD_DIST)/swaybg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/swaybg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/swaybg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/swaybg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/swaybg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/swaybg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,swaybg,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,swaybg,DEB_SWAYBG_V)
	rm -rf $(BUILD_DIST)/swaybg

.PHONY: swaybg swaybg-package
