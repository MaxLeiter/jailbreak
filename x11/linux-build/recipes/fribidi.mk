ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS       += fribidi
FRIBIDI_VERSION   := 1.0.13
# Procursus ships build_info/libfribidi*.control templates keyed on @DEB_LIBFRIBIDI_V@.
DEB_LIBFRIBIDI_V  ?= $(FRIBIDI_VERSION)+ios1

fribidi-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/fribidi/fribidi/releases/download/v$(FRIBIDI_VERSION)/fribidi-$(FRIBIDI_VERSION).tar.xz)
	$(call EXTRACT_TAR,fribidi-$(FRIBIDI_VERSION).tar.xz,fribidi-$(FRIBIDI_VERSION),fribidi)
	rm -rf $(BUILD_WORK)/fribidi/build
	mkdir -p $(BUILD_WORK)/fribidi/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/fribidi/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/fribidi/.build_complete),)
fribidi:
	@echo "Using previously built fribidi."
else
fribidi: fribidi-setup
	cd $(BUILD_WORK)/fribidi/build && meson \
		--cross-file cross.txt \
		-Ddocs=false \
		-Dtests=false \
		-Dbin=false \
		..
	+ninja -C $(BUILD_WORK)/fribidi/build
	+DESTDIR="$(BUILD_STAGE)/fribidi" ninja -C $(BUILD_WORK)/fribidi/build install
	$(call AFTER_BUILD,copy)
endif

fribidi-package: fribidi-stage
	rm -rf $(BUILD_DIST)/libfribidi{0,-dev}
	mkdir -p $(BUILD_DIST)/libfribidi{0,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libfribidi0 (runtime)
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfribidi.0.dylib $(BUILD_DIST)/libfribidi0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libfribidi-dev (headers, symlinks, .pc)
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libfribidi.0.dylib) $(BUILD_DIST)/libfribidi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/fribidi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libfribidi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libfribidi0,general.xml)
	$(call PACK,libfribidi0,DEB_LIBFRIBIDI_V)
	$(call PACK,libfribidi-dev,DEB_LIBFRIBIDI_V)
	rm -rf $(BUILD_DIST)/libfribidi{0,-dev}

.PHONY: fribidi fribidi-package
