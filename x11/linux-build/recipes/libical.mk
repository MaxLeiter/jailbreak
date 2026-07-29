ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Sole new dependency EDS needs beyond the sysroot; its calendar API (libecal) consumes libical-glib.
#
# Native-then-cross CMake build (same family as icu4c.mk): libical-glib's sources are
# generated at build time by ical-glib-src-generator, which must run on the host. A native
# configure+install exports it as a CMake target file; the cross configure imports it via
# -DIMPORT_ICAL_GLIB_SRC_GENERATOR (gated on CMAKE_CROSSCOMPILING). The native half pins
# CMAKE_C_COMPILER=/usr/bin/cc explicitly -- cmake would otherwise pick up the darwin cross
# wrappers from env CC/CXX, the same leak class that broke ICU's native tools. Needs host
# libglib2.0-dev + libxml2-dev + pkg-config (build-eds.sh installs these).
#
# ICU is found via CMake's FindICU with ICU_ROOT into BUILD_BASE, enabling RFC 7529 RSCALE
# (non-Gregorian recurrences). Timezones use system zoneinfo (USE_BUILTIN_TZDATA off) since
# iOS ships a real /usr/share/zoneinfo. 3.0.17 pairs with Ubuntu 24.04's ICU 74.2 / EDS 3.52.

SUBPROJECTS     += libical
LIBICAL_VERSION := 3.0.17
DEB_LIBICAL_V   ?= $(LIBICAL_VERSION)+ios1

libical-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/libical/libical/releases/download/v$(LIBICAL_VERSION)/libical-$(LIBICAL_VERSION).tar.gz)
	$(call EXTRACT_TAR,libical-$(LIBICAL_VERSION).tar.gz,libical-$(LIBICAL_VERSION),libical)

ifneq ($(wildcard $(BUILD_WORK)/libical/.build_complete),)
libical:
	@echo "Using previously built libical."
else
libical: libical-setup glib2.0 libxml2 icu4c
	# cmake pulls CFLAGS/LDFLAGS from the environment; the parent Makefile exports darwin
	# flags (-arch arm64 -isysroot ... -miphoneos-version-min) that make host gcc choke.
	# Pinning the compilers alone isn't enough -- scrub the env too (same leak class as
	# icu4c.mk's MAKEFLAGS note, flags edition).
	rm -rf $(BUILD_WORK)/libical/native $(BUILD_WORK)/libical/native-prefix
	cd $(BUILD_WORK)/libical && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
		-u CC -u CXX -u AR -u RANLIB cmake -B native \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_COMPILER=/usr/bin/cc \
		-DCMAKE_CXX_COMPILER=/usr/bin/c++ \
		-DCMAKE_INSTALL_PREFIX=$(BUILD_WORK)/libical/native-prefix \
		-DICAL_GLIB=true \
		-DWITH_CXX_BINDINGS=false \
		-DICAL_BUILD_DOCS=false \
		-DLIBICAL_BUILD_TESTING=false \
		-DGOBJECT_INTROSPECTION=false \
		-DICAL_GLIB_VAPI=false \
		-DSHARED_ONLY=true
	+$(MAKE) -C $(BUILD_WORK)/libical/native
	+$(MAKE) -C $(BUILD_WORK)/libical/native install
	# CMAKE_SYSTEM_NAME=Darwin (from DEFAULT_CMAKE_FLAGS) makes CMAKE_CROSSCOMPILING true,
	# which flips libical-glib to use the imported native generator. Introspection stays
	# off; typelibs are generated on-device.
	rm -rf $(BUILD_WORK)/libical/build
	cd $(BUILD_WORK)/libical && cmake -B build \
		$(DEFAULT_CMAKE_FLAGS) \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DIMPORT_ICAL_GLIB_SRC_GENERATOR=$(BUILD_WORK)/libical/native-prefix/lib/cmake/LibIcal/IcalGlibSrcGenerator.cmake \
		-DICU_ROOT=$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DICAL_GLIB=true \
		-DWITH_CXX_BINDINGS=false \
		-DICAL_BUILD_DOCS=false \
		-DLIBICAL_BUILD_TESTING=false \
		-DGOBJECT_INTROSPECTION=false \
		-DICAL_GLIB_VAPI=false \
		-DSHARED_ONLY=true
	+$(MAKE) -C $(BUILD_WORK)/libical/build
	+$(MAKE) -C $(BUILD_WORK)/libical/build install \
		DESTDIR="$(BUILD_STAGE)/libical"
	# Cross build also compiles its own (iOS-native, unusable) src-generator into libexec;
	# drop it so it never reaches a deb.
	rm -rf $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec
	$(call AFTER_BUILD,copy)
endif

libical-package: libical-stage
	rm -rf $(BUILD_DIST)/libical{3,-dev}
	mkdir -p $(BUILD_DIST)/libical3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libical-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libical3 folds in libical-glib (unlike Debian) since EDS is the only consumer --
	# one Depends line covers all four runtime dylibs + their symlinks.
	cp -a $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libical*.dylib \
		$(BUILD_DIST)/libical3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libical-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake \
		$(BUILD_DIST)/libical-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libical3,general.xml)

	$(call PACK,libical3,DEB_LIBICAL_V)
	$(call PACK,libical-dev,DEB_LIBICAL_V)

	rm -rf $(BUILD_DIST)/libical{3,-dev}

.PHONY: libical libical-package
