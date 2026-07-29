ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# wl-clipboard talks zwlr_data_control_manager_v1 (wlr-data-control), which
# lets it read/write the selection without holding keyboard focus, unlike
# plain wl_data_device. Copies land in the same selection GTK apps see (and
# ride the iOS clipboard bridge).
#
# Vendors its own protocol XML in protocol/, so the native wayland-scanner
# can turn it into C at build time with no extra XML fetch.

SUBPROJECTS       += wl-clipboard
WL_CLIPBOARD_VERSION := 2.2.1
DEB_WL_CLIPBOARD_V   ?= $(WL_CLIPBOARD_VERSION)+ios1

wl-clipboard-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/bugaevc/wl-clipboard/archive/refs/tags/v$(WL_CLIPBOARD_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(WL_CLIPBOARD_VERSION).tar.gz,wl-clipboard-$(WL_CLIPBOARD_VERSION),wl-clipboard)
	mkdir -p $(BUILD_WORK)/wl-clipboard/build
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
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/wl-clipboard/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/wl-clipboard/.build_complete),)
wl-clipboard:
	@echo "Using previously built wl-clipboard."
else
wl-clipboard: wl-clipboard-setup wayland wayland-protocols
	# wl-clipboard runs the native wayland-scanner on its vendored protocol XMLs; point a native
	# file at the version-matched scanner + its .pc (same trick as foot/imv).
	cd $(BUILD_WORK)/wl-clipboard/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dzshcompletiondir=no \
		-Dfishcompletiondir=no \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/wl-clipboard/build
	+DESTDIR="$(BUILD_STAGE)/wl-clipboard" ninja -C $(BUILD_WORK)/wl-clipboard/build install
	$(call AFTER_BUILD,copy)
endif

wl-clipboard-package: wl-clipboard-stage
	rm -rf $(BUILD_DIST)/wl-clipboard
	mkdir -p $(BUILD_DIST)/wl-clipboard/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	# app: bin/{wl-copy,wl-paste} + share (bash completion, any docs)
	cp -a $(BUILD_STAGE)/wl-clipboard/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/wl-clipboard/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/wl-clipboard/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/wl-clipboard/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/wl-clipboard/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,wl-clipboard,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,wl-clipboard,DEB_WL_CLIPBOARD_V)
	rm -rf $(BUILD_DIST)/wl-clipboard

.PHONY: wl-clipboard wl-clipboard-package
