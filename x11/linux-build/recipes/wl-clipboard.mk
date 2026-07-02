ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# wl-clipboard.mk — wl-clipboard, the command-line clipboard for Wayland
# (github.com/bugaevc/wl-clipboard). Ships wl-copy and wl-paste. Pure C, meson.
# It talks the zwlr_data_control_manager_v1 protocol (wlr-data-control), which the
# iosc compositor now serves, so it reads/writes the selection WITHOUT holding
# keyboard focus — the whole reason it exists over plain wl_data_device. Copies
# from wl-copy land in the same selection GTK apps see (and ride the iOS clipboard
# bridge), and wl-paste reads whatever the last app copied.
#
# BUILD-HOST TOOLS (installed by build-wayland-apps.sh): wayland-scanner (protocol
# codegen, native). wl-clipboard VENDORS its own protocol XMLs in protocol/, so no
# extra XML is fetched; wayland-scanner turns them into C at build time.
#
# DEPENDS (target): wayland (libwayland-client), wayland-protocols (build-time, for
# the primary-selection XML wl-clipboard pulls from the shared protocol dir). No
# toolkit, no GPU, no X11. Man pages are only built if scdoc is present, so they are
# skipped here without a knob.

SUBPROJECTS       += wl-clipboard
WL_CLIPBOARD_VERSION := 2.2.1
DEB_WL_CLIPBOARD_V   ?= $(WL_CLIPBOARD_VERSION)

wl-clipboard-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/bugaevc/wl-clipboard/archive/refs/tags/v$(WL_CLIPBOARD_VERSION).tar.gz,wl-clipboard-$(WL_CLIPBOARD_VERSION).tar.gz)
	$(call EXTRACT_TAR,wl-clipboard-$(WL_CLIPBOARD_VERSION).tar.gz,wl-clipboard-$(WL_CLIPBOARD_VERSION),wl-clipboard)
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
	cd $(BUILD_WORK)/wl-clipboard/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dzshcompletiondir=no \
		-Dfishcompletiondir=no \
		..
	+ninja -C $(BUILD_WORK)/wl-clipboard/build
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
