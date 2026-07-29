ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# SVG glyphs use the bundled nanosvg (svg-backend=nanosvg) — no librsvg/Rust dependency.
# Bundled Unicode data is code-genned at build time by host env/sh/python3; no target
# execution involved, so needs_exe_wrapper is unaffected.

SUBPROJECTS   += fcft
FCFT_MAJOR_V  := 4
FCFT_VERSION  := 3.3.3
DEB_FCFT_V    ?= $(FCFT_VERSION)+ios1

fcft-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://codeberg.org/dnkl/fcft/releases/download/$(FCFT_VERSION)/fcft-$(FCFT_VERSION).tar.gz)
	$(call EXTRACT_TAR,fcft-$(FCFT_VERSION).tar.gz,fcft-$(FCFT_VERSION),fcft)
	# iOS exposes locale_t/newlocale through <xlocale.h>.
	$(call DO_PATCH,fcft,fcft,-p1)
	mkdir -p $(BUILD_WORK)/fcft/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/fcft/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/fcft/.build_complete),)
fcft:
	@echo "Using previously built fcft."
else
fcft: fcft-setup tllist freetype fontconfig libpixman harfbuzz libutf8proc
	cd $(BUILD_WORK)/fcft/build && meson \
		--cross-file cross.txt \
		-Ddocs=disabled \
		-Dexamples=false \
		-Dtest-text-shaping=false \
		-Dgrapheme-shaping=enabled \
		-Drun-shaping=enabled \
		-Dsvg-backend=nanosvg \
		-Dsystem-nanosvg=disabled \
		..
	+ninja -C $(BUILD_WORK)/fcft/build
	+DESTDIR="$(BUILD_STAGE)/fcft" ninja -C $(BUILD_WORK)/fcft/build install
	$(call AFTER_BUILD,copy)
endif

fcft-package: fcft-stage
	rm -rf $(BUILD_DIST)/libfcft4 $(BUILD_DIST)/libfcft-dev
	mkdir -p $(BUILD_DIST)/libfcft4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libfcft-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/fcft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfcft.*.dylib \
		$(BUILD_DIST)/libfcft4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/fcft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libfcft-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/fcft/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libfcft.*.dylib) \
		$(BUILD_DIST)/libfcft-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libfcft4,general.xml)
	$(call PACK,libfcft4,DEB_FCFT_V)
	$(call PACK,libfcft-dev,DEB_FCFT_V)
	rm -rf $(BUILD_DIST)/libfcft4 $(BUILD_DIST)/libfcft-dev

.PHONY: fcft fcft-package
