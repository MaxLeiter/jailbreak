ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libpsl.mk — Public Suffix List library; required by libsoup3 (cookie domain checks).
# Built with the BUILTIN list and no IDNA runtime to avoid pulling libidn2 + libunistring.
# Pure C. GTK-independent.
#
# DRAFT — Phase 1, NOT built/verified. Mirrors recipes/pango.mk style.

SUBPROJECTS    += libpsl
LIBPSL_VERSION := 0.21.5
DEB_LIBPSL_V   ?= $(LIBPSL_VERSION)+ios1

libpsl-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/rockdaboot/libpsl/releases/download/$(LIBPSL_VERSION)/libpsl-$(LIBPSL_VERSION).tar.gz)
	$(call EXTRACT_TAR,libpsl-$(LIBPSL_VERSION).tar.gz,libpsl-$(LIBPSL_VERSION),libpsl)
	mkdir -p $(BUILD_WORK)/libpsl/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libpsl/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libpsl/.build_complete),)
libpsl:
	@echo "Using previously built libpsl."
else
libpsl: libpsl-setup
	cd $(BUILD_WORK)/libpsl/build && meson \
		--cross-file cross.txt \
		-Druntime=no \
		-Dbuiltin=true \
		-Dtests=false \
		..
	+ninja -C $(BUILD_WORK)/libpsl/build
	+DESTDIR="$(BUILD_STAGE)/libpsl" ninja -C $(BUILD_WORK)/libpsl/build install
	$(call AFTER_BUILD,copy)
endif

libpsl-package: libpsl-stage
	rm -rf $(BUILD_DIST)/libpsl5 $(BUILD_DIST)/libpsl-dev
	mkdir -p $(BUILD_DIST)/libpsl5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpsl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libpsl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpsl.5.dylib $(BUILD_DIST)/libpsl5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libpsl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libpsl.5.dylib) $(BUILD_DIST)/libpsl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libpsl/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libpsl-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libpsl5,general.xml)
	$(call PACK,libpsl5,DEB_LIBPSL_V)
	$(call PACK,libpsl-dev,DEB_LIBPSL_V)
	rm -rf $(BUILD_DIST)/libpsl5 $(BUILD_DIST)/libpsl-dev

.PHONY: libpsl libpsl-package
