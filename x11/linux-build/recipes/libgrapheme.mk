ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libgrapheme.mk — suckless Unicode grapheme/word/line segmentation library, imv's lightweight
# alternative to ICU for its `unicode` backend (imv is built with -Dunicode=grapheme). Plain
# POSIX Makefile (no meson/autotools).
#
# CROSS MECHANISM: libgrapheme code-gens its Unicode lookup tables at build time by compiling
# gen/*.c and RUNNING them on the build host. The Makefile already separates BUILD_CC (host,
# for the gen tools) from CC (target, for the library), so we set BUILD_CC=cc and CC=<cross>:
# the gen tools stay host-native (needs_exe_wrapper safe) and only the library is cross-built.
# The gen tools read data/*.txt (Unicode 15.0.0), which the Makefile fetches with wget at build
# (the driver installs wget). We build ONLY the static archive (libgrapheme.a) and ship it in a
# -dev deb: imv links it statically via cc.find_library('grapheme'), so we avoid porting the
# Makefile's GNU-ld shared-object flags (-Wl,--soname/-nostdlib) to Darwin ld64 entirely.

SUBPROJECTS       += libgrapheme
LIBGRAPHEME_VERSION := 2.0.2
DEB_LIBGRAPHEME_V ?= $(LIBGRAPHEME_VERSION)

libgrapheme-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://dl.suckless.org/libgrapheme/libgrapheme-$(LIBGRAPHEME_VERSION).tar.gz)
	$(call EXTRACT_TAR,libgrapheme-$(LIBGRAPHEME_VERSION).tar.gz,libgrapheme-$(LIBGRAPHEME_VERSION),libgrapheme)

ifneq ($(wildcard $(BUILD_WORK)/libgrapheme/.build_complete),)
libgrapheme:
	@echo "Using previously built libgrapheme."
else
libgrapheme: libgrapheme-setup
	# Static archive only: gen tools with host BUILD_CC (run on host), library with cross CC.
	# The cross clang wrapper injects -arch/-isysroot/-miphoneos-version-min, so CC alone is
	# enough for the target flags; keep libgrapheme's own -Os/-fPIC (SHFLAGS) for the .a objects.
	+$(MAKE) -C $(BUILD_WORK)/libgrapheme libgrapheme.a \
		BUILD_CC=cc \
		CC="$(CC)" AR="$(AR)" RANLIB="$(RANLIB)"
	mkdir -p $(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_WORK)/libgrapheme/libgrapheme.a $(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_WORK)/libgrapheme/grapheme.h $(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	# Synthesize a pkg-config file (upstream only writes one on `make install`), so consumers
	# that prefer pkg-config over find_library still resolve it.
	printf 'prefix=%s\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libgrapheme\nDescription: Unicode string library\nVersion: %s\nLibs: -L$${libdir} -lgrapheme\nCflags: -I$${includedir}\n' \
		"$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" "$(LIBGRAPHEME_VERSION)" \
		> $(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libgrapheme.pc
	$(call AFTER_BUILD,copy)
endif

libgrapheme-package: libgrapheme-stage
	rm -rf $(BUILD_DIST)/libgrapheme-dev
	mkdir -p $(BUILD_DIST)/libgrapheme-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_STAGE)/libgrapheme/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgrapheme-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call PACK,libgrapheme-dev,DEB_LIBGRAPHEME_V)
	rm -rf $(BUILD_DIST)/libgrapheme-dev

.PHONY: libgrapheme libgrapheme-package
