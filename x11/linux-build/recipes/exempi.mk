ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# exempi.mk — Exempi, the freedesktop port of the Adobe XMP SDK (libexempi). Papers 46.2 lists
# `exempi-2.0 (>= 2.0)` as an UNCONDITIONAL dependency (PDF XMP metadata), so the GTK4 viewer
# cannot link without it. Autotools/automake C++ project; its only external deps are expat,
# zlib and iconv — all already in our tree (expat.pc/zlib.pc in the base, libiconv is the
# system C library) — so it adds NO new sub-deps.
#
# VERSION 2.5.2 deliberately: exempi 2.6.0+ re-synced to a newer Adobe SDK that pulls in
# Boost at build time. 2.5.2 is the last release before that, needing only expat/zlib/iconv,
# and Boost there is confined to the (disabled) unit tests. libtool CURRENT=8, so the SONAME
# is libexempi.8 (-> libexempi8), matching Debian's package name; pkg-config still advertises
# exempi-2.0, satisfying Papers' `>= 2.0`.
#
# CROSS NOTE: configure's platform switch keys on $build_vendor, not $host — cross-building
# FROM Linux it takes the generic UNIX_ENV path (no `-framework CoreServices`, which the Mac
# path would add and iOS lacks). The UNIX platform code is POSIX; add -std=c++11 by hand since
# only the (unused) Mac branch sets the C++ standard.

SUBPROJECTS      += exempi
EXEMPI_VERSION   := 2.5.2
EXEMPI_SOV       := 8
DEB_EXEMPI_V     ?= $(EXEMPI_VERSION)+ios1

exempi-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://libopenraw.freedesktop.org/download/exempi-$(EXEMPI_VERSION).tar.bz2)
	$(call EXTRACT_TAR,exempi-$(EXEMPI_VERSION).tar.bz2,exempi-$(EXEMPI_VERSION),exempi)
	# The 2020 tarball's config.sub predates the aarch64-apple-darwin triple — refresh it
	# with the host's modern copy (librsvg/mozjs precedent).
	find $(BUILD_WORK)/exempi -name config.sub  -exec cp -f /usr/share/misc/config.sub  {} \; || true
	find $(BUILD_WORK)/exempi -name config.guess -exec cp -f /usr/share/misc/config.guess {} \; || true
	# Drop unshipped sample programs and the unavailable librt edge through the
	# port patch stack.
	$(call DO_PATCH,exempi,exempi,-p1)

ifneq ($(wildcard $(BUILD_WORK)/exempi/.build_complete),)
exempi:
	@echo "Using previously built exempi."
else
# Deps (expat/zlib/iconv) are pre-staged in build_base (mutter/kcoreaddons precedent); no
# make-level prereqs — the volume is warmed and base libs have no standalone recipe targets.
exempi: exempi-setup
	cd $(BUILD_WORK)/exempi && CXXFLAGS="$(CXXFLAGS) -std=c++11" ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-unittest
	+$(MAKE) -C $(BUILD_WORK)/exempi
	+$(MAKE) -C $(BUILD_WORK)/exempi install DESTDIR="$(BUILD_STAGE)/exempi"
	$(call AFTER_BUILD,copy)
endif

exempi-package: exempi-stage
	rm -rf $(BUILD_DIST)/libexempi$(EXEMPI_SOV) $(BUILD_DIST)/libexempi-dev
	mkdir -p $(BUILD_DIST)/libexempi$(EXEMPI_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libexempi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime dylib (real file + soname symlink)
	cp -a $(BUILD_STAGE)/exempi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexempi.*.dylib \
		$(BUILD_DIST)/libexempi$(EXEMPI_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# -dev: headers, .pc, bare symlink. The bin/exempi CLI is not needed by Papers; drop it.
	cp -a $(BUILD_STAGE)/exempi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libexempi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/exempi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexempi.dylib \
		$(BUILD_DIST)/libexempi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/exempi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig" ]; then \
		cp -a $(BUILD_STAGE)/exempi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
			$(BUILD_DIST)/libexempi-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi

	$(call SIGN,libexempi$(EXEMPI_SOV),general.xml)
	$(call PACK,libexempi$(EXEMPI_SOV),DEB_EXEMPI_V)
	$(call PACK,libexempi-dev,DEB_EXEMPI_V)
	rm -rf $(BUILD_DIST)/libexempi$(EXEMPI_SOV) $(BUILD_DIST)/libexempi-dev

.PHONY: exempi exempi-package
