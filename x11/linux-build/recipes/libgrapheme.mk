ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# imv's lightweight alternative to ICU for its unicode backend (-Dunicode=grapheme).
# Plain POSIX Makefile, no meson/autotools.
#
# The Makefile code-gens its Unicode lookup tables at build time by compiling gen/*.c and
# running them on the build host; it already separates BUILD_CC (host) from CC (target), so
# we just set BUILD_CC=cc and CC=<cross>. We ship only the static archive (libgrapheme.a):
# imv links it statically via find_library('grapheme'), so the Makefile's GNU-ld shared-object
# flags (-Wl,--soname/-nostdlib) never need porting to Darwin ld64.

SUBPROJECTS       += libgrapheme
LIBGRAPHEME_VERSION := 2.0.2
DEB_LIBGRAPHEME_V ?= $(LIBGRAPHEME_VERSION)+ios1

libgrapheme-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://dl.suckless.org/libgrapheme/libgrapheme-$(LIBGRAPHEME_VERSION).tar.gz)
	$(call EXTRACT_TAR,libgrapheme-$(LIBGRAPHEME_VERSION).tar.gz,libgrapheme-$(LIBGRAPHEME_VERSION),libgrapheme)

ifneq ($(wildcard $(BUILD_WORK)/libgrapheme/.build_complete),)
libgrapheme:
	@echo "Using previously built libgrapheme."
else
libgrapheme: libgrapheme-setup
	# Cross clang wrapper already injects -arch/-isysroot/-miphoneos-version-min, so CC alone
	# carries the target flags; keep libgrapheme's own -Os/-fPIC (SHFLAGS) for the .a objects.
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
