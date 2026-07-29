ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Event loop is epoll-based; epoll-shim supplies epoll/timerfd/eventfd on non-Linux. The only
# Linux header still needed is <linux/input-event-codes.h> (BTN_*/KEY_* codes) — same shim used
# by the GTK4 Wayland backend. utmp logging is disabled (no utmp on iOS).

SUBPROJECTS  += foot
FOOT_VERSION := 1.27.0
DEB_FOOT_V   ?= $(FOOT_VERSION)+ios3

foot-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://codeberg.org/dnkl/foot/releases/download/$(FOOT_VERSION)/foot-$(FOOT_VERSION).tar.gz)
	$(call EXTRACT_TAR,foot-$(FOOT_VERSION).tar.gz,foot-$(FOOT_VERSION),foot)
	rm -rf $(BUILD_WORK)/foot/build && mkdir -p $(BUILD_WORK)/foot/build
	# Compat shim (force-included via c_args below): declares reallocarray, defines struct
	# itimerspec + SOCK_CLOEXEC/NONBLOCK, wraps glibc pipe2/accept4/mkostemp over their
	# flagless POSIX variants.
	cp $(BUILD_INFO)/foot-compat.h $(BUILD_WORK)/foot/foot-compat.h
	$(call DO_PATCH,foot,foot,-p1)
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
	c_args = ['-include', '$(BUILD_WORK)/foot/foot-compat.h', '-Wno-error']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/foot/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/foot/.build_complete),)
foot:
	@echo "Using previously built foot."
else
foot: foot-setup wayland wayland-protocols libxkbcommon fcft tllist libpixman fontconfig libutf8proc epoll-shim
	# foot resolves `dependency('wayland-scanner', native:true)` via pkg-config, but there's no
	# wayland-scanner.pc shipped; point a native file at the version-matched scanner the wayland
	# build left in WAYLAND_NATIVE_ROOT.
	cd $(BUILD_WORK)/foot/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Ddocs=disabled \
		-Dthemes=true \
		-Dime=true \
		-Dgrapheme-clustering=enabled \
		-Dtests=false \
		-Dterminfo=enabled \
		-Dutmp-backend=none \
		..
	+ninja -C $(BUILD_WORK)/foot/build
	+DESTDIR="$(BUILD_STAGE)/foot" ninja -C $(BUILD_WORK)/foot/build install
	$(call AFTER_BUILD,copy)
endif

foot-package: foot-stage
	rm -rf $(BUILD_DIST)/foot
	mkdir -p $(BUILD_DIST)/foot/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/foot/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/foot/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/foot/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/foot/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/foot/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,foot,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,foot,DEB_FOOT_V)
	rm -rf $(BUILD_DIST)/foot

.PHONY: foot foot-package
