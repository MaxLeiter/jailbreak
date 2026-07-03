ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxcvt — tiny pure-C library implementing the VESA CVT timing formula. It is
# the ONE hard new dependency Xwayland (>= 21.1) needs that Procursus doesn't
# already ship (xserver dropped its bundled copy). No system deps; trivial meson.

SUBPROJECTS   += libxcvt
LIBXCVT_VERSION := 0.1.2
DEB_LIBXCVT_V   ?= $(LIBXCVT_VERSION)+ios1

libxcvt-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xorg.freedesktop.org/archive/individual/lib/libxcvt-$(LIBXCVT_VERSION).tar.xz)
	$(call EXTRACT_TAR,libxcvt-$(LIBXCVT_VERSION).tar.xz,libxcvt-$(LIBXCVT_VERSION),libxcvt)
	mkdir -p $(BUILD_WORK)/libxcvt/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libxcvt/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libxcvt/.build_complete),)
libxcvt:
	@echo "Using previously built libxcvt."
else
libxcvt: libxcvt-setup
	cd $(BUILD_WORK)/libxcvt/build && meson \
		--cross-file cross.txt \
		-Ddefault_library=shared \
		..
	+ninja -C $(BUILD_WORK)/libxcvt/build
	+DESTDIR="$(BUILD_STAGE)/libxcvt" ninja -C $(BUILD_WORK)/libxcvt/build install
	$(call AFTER_BUILD,copy)
endif

libxcvt-package: libxcvt-stage
	# libxcvt.mk Package Structure — one runtime deb + a -dev deb (headers/.pc).
	rm -rf $(BUILD_DIST)/libxcvt{0,-dev}
	mkdir -p $(BUILD_DIST)/libxcvt0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxcvt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxcvt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxcvt.*.dylib \
		$(BUILD_DIST)/libxcvt0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxcvt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libxcvt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libxcvt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libxcvt.*.dylib) \
		$(BUILD_DIST)/libxcvt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	$(call SIGN,libxcvt0,general.xml)
	$(call PACK,libxcvt0,DEB_LIBXCVT_V)
	$(call PACK,libxcvt-dev,DEB_LIBXCVT_V)
	rm -rf $(BUILD_DIST)/libxcvt{0,-dev}

.PHONY: libxcvt libxcvt-package
