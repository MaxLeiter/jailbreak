ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# slurp.mk — slurp, a Wayland region selector (github.com/emersion/slurp). You drag a box and
# it prints the geometry; paired with grim it's the standard "screenshot a region" tool. Pure C,
# no toolkit: it draws the selection overlay with cairo into wl_shm buffers and maps itself as a
# zwlr_layer_surface_v1 (overlay layer, all-outputs) so the box floats over everything.
#
# PROTOCOLS (served by the iosc compositor): wlr-layer-shell-unstable-v1 (bundled in slurp's own
# tree — it is a wlroots protocol, not part of wayland-protocols) to map the overlay surface;
# plus xdg-shell, cursor-shape-v1, tablet-unstable-v2 and xdg-output-unstable-v1 from
# wayland-protocols (>=1.32; the gtk-calc volume ships 1.38). slurp needs layer-shell to actually
# put a surface on screen and xdg-output to learn each output's logical geometry.
#
# PORTABILITY: slurp is clean on Darwin except `cc.find_library('rt')` (no librt on iOS —
# clock_gettime lives in libc; make it non-required) and main.c's <linux/input-event-codes.h>
# for BTN_* codes (the driver ships the same lightweight shim foot/imv use). The wl_shm pool is
# backed by shm_open (portable), not memfd. Protocol code is generated at build time by the host
# wayland-scanner (native, via WAYLAND_NATIVE_ROOT) over the wayland-protocols XML in build_base.
#
# DEPENDS (target): cairo, wayland(-client/-cursor), libxkbcommon, wayland-protocols(build/data).

SUBPROJECTS   += slurp
SLURP_VERSION := 1.5.0
DEB_SLURP_V   ?= $(SLURP_VERSION)+ios1

slurp-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/emersion/slurp/releases/download/v$(SLURP_VERSION)/slurp-$(SLURP_VERSION).tar.gz)
	$(call EXTRACT_TAR,slurp-$(SLURP_VERSION).tar.gz,slurp-$(SLURP_VERSION),slurp)
	# iOS has no librt (clock_gettime is in libc); make the lookup non-fatal. The not-found dep
	# stays in the executable() dependencies list — meson silently ignores unfound libraries.
	$(call DO_PATCH,slurp,slurp,-p1)
	rm -rf $(BUILD_WORK)/slurp/build && mkdir -p $(BUILD_WORK)/slurp/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/slurp/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/slurp/.build_complete),)
slurp:
	@echo "Using previously built slurp."
else
slurp: slurp-setup wayland wayland-protocols libxkbcommon cairo
	# protocol/meson.build resolves `dependency('wayland-scanner', native:true)` via pkg-config then
	# runs it; Debian's libwayland-bin ships no wayland-scanner.pc, so point a native file at the
	# version-matched native scanner the wayland build left in WAYLAND_NATIVE_ROOT (same trick as
	# foot/imv). PATH also carries that native scanner so find_program() resolves it.
	cd $(BUILD_WORK)/slurp/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dman-pages=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/slurp/build
	+DESTDIR="$(BUILD_STAGE)/slurp" ninja -C $(BUILD_WORK)/slurp/build install
	$(call AFTER_BUILD,copy)
endif

slurp-package: slurp-stage
	rm -rf $(BUILD_DIST)/slurp
	mkdir -p $(BUILD_DIST)/slurp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/slurp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/slurp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/slurp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/slurp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/slurp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,slurp,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,slurp,DEB_SLURP_V)
	rm -rf $(BUILD_DIST)/slurp

.PHONY: slurp slurp-package
