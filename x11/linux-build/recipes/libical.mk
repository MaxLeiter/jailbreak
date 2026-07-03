ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libical.mk — iCalendar parser/generator (libical + libicalss + libicalvcal + libical-glib).
# Sole NEW target dependency of evolution-data-server (everything else EDS needs is already
# in the sysroot); EDS's calendar API (libecal) is a libical-glib consumer.
#
# CROSS PATTERN (same native-then-cross family as recipes/icu4c.mk, but CMake): libical-glib's
# sources are GENERATED at build time by ical-glib-src-generator, a glib/libxml2 tool that must
# RUN on the build host. libical has first-class support for this: a NATIVE configure+install
# exports the generator as a CMake target file, and the cross configure imports it via
# -DIMPORT_ICAL_GLIB_SRC_GENERATOR (src/libical-glib/CMakeLists.txt gates on CMAKE_CROSSCOMPILING).
# The native half pins CMAKE_C_COMPILER=/usr/bin/cc explicitly — cmake would otherwise take the
# darwin cross wrappers from env CC/CXX (the exact leak class that broke ICU's native tools).
# The native half needs HOST libglib2.0-dev + libxml2-dev + pkg-config (build-eds.sh installs).
#
# ICU: found via CMake's FindICU with ICU_ROOT pointed into BUILD_BASE (our libicu74) — enables
# RFC 7529 RSCALE (non-Gregorian recurrences). Timezones: system zoneinfo (USE_BUILTIN_TZDATA
# off); iOS ships a real /usr/share/zoneinfo, so the baked default path works on-device.
# 3.0.17 = the Ubuntu 24.04 pairing, matching ICU 74.2 / EDS 3.52.

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
	# Native half: only exists to produce ical-glib-src-generator + its CMake export file
	# (installed to native-prefix/lib/cmake/LibIcal/IcalGlibSrcGenerator.cmake). Compilers
	# pinned to the real host toolchain; host pkg-config resolves host glib/libxml2.
	# env -u: cmake initializes CMAKE_C_FLAGS / linker flags from the ENVIRONMENT, and the
	# parent Makefile exports the darwin CFLAGS/LDFLAGS (-arch arm64 -isysroot iPhoneOS.sdk
	# -miphoneos-version-min...) — host gcc chokes ("unrecognized command-line option
	# '-arch'"). Same leak class as icu4c.mk's MAKEFLAGS note, flags edition: scrub the
	# cross env for the native configure; pinning the compilers alone is NOT enough.
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
	# Cross half: CMAKE_SYSTEM_NAME=Darwin (DEFAULT_CMAKE_FLAGS) makes CMAKE_CROSSCOMPILING
	# true, which flips libical-glib to the imported native generator. glib/libxml2 resolve
	# through cross-pkg-config; introspection stays off (typelibs are an on-device pass).
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
	# The cross build also compiles its own (iOS-native, unusable-here) src-generator into
	# libexec/libical — drop it from the stage so it never reaches a deb.
	rm -rf $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec
	$(call AFTER_BUILD,copy)
endif

libical-package: libical-stage
	# libical.mk Package Structure
	rm -rf $(BUILD_DIST)/libical{3,-dev}
	mkdir -p $(BUILD_DIST)/libical3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libical-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libical.mk Prep libical3 (all four runtime dylibs + their symlinks; unlike Debian we
	# fold libical-glib into the same deb — EDS is the only consumer, one Depends line)
	cp -a $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libical*.dylib \
		$(BUILD_DIST)/libical3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libical.mk Prep libical-dev (headers + pkgconfig + cmake configs)
	cp -a $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libical-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/libical/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake \
		$(BUILD_DIST)/libical-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libical.mk Sign
	$(call SIGN,libical3,general.xml)

	# libical.mk Make .debs
	$(call PACK,libical3,DEB_LIBICAL_V)
	$(call PACK,libical-dev,DEB_LIBICAL_V)

	# libical.mk Build cleanup
	rm -rf $(BUILD_DIST)/libical{3,-dev}

.PHONY: libical libical-package
