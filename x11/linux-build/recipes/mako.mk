ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mako uses the Darwin-ported basu sd-bus provider plus epoll-shim's
# timerfd/signalfd compatibility. iOS has no librt; clock_gettime is in libc.

SUBPROJECTS  += mako
MAKO_VERSION := 1.9.0
DEB_MAKO_V   ?= $(MAKO_VERSION)+ios1

mako-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/emersion/mako/releases/download/v$(MAKO_VERSION)/mako-$(MAKO_VERSION).tar.gz)
	$(call EXTRACT_TAR,mako-$(MAKO_VERSION).tar.gz,mako-$(MAKO_VERSION),mako)
	# iOS has no librt (clock_gettime is in libc); keep the Meson edit in the patch stack.
	$(call DO_PATCH,mako,mako,-p1)
	rm -rf $(BUILD_WORK)/mako/build && mkdir -p $(BUILD_WORK)/mako/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/mako/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/mako/.build_complete),)
mako:
	@echo "Using previously built mako."
else
mako: mako-setup wayland wayland-protocols cairo pango gdk-pixbuf epoll-shim basu
	# protocol/meson.build resolves the native wayland-scanner via pkg-config (WAYLAND_NATIVE_ROOT),
	# same trick as slurp/foot/imv.
	cd $(BUILD_WORK)/mako/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dsd-bus-provider=basu \
		-Dicons=enabled \
		-Dman-pages=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/mako/build
	+DESTDIR="$(BUILD_STAGE)/mako" ninja -C $(BUILD_WORK)/mako/build install
	$(call AFTER_BUILD,copy)
endif

mako-package: mako-stage
	rm -rf $(BUILD_DIST)/mako
	mkdir -p $(BUILD_DIST)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/mako/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,mako,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,mako,DEB_MAKO_V)
	rm -rf $(BUILD_DIST)/mako

.PHONY: mako mako-package
