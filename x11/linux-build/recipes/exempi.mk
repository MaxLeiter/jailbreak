ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Pinned to 2.5.2: exempi 2.6.0+ re-synced to a newer Adobe SDK that pulls in Boost at build
# time. 2.5.2 needs only expat/zlib/iconv (Boost there is confined to the disabled unit tests).
# libtool CURRENT=8, so SONAME is libexempi.8 (-> libexempi8), matching Debian's package name.
#
# configure's platform switch keys on $build_vendor, not $host, so cross-building from Linux
# takes the generic UNIX path (fine — no -framework CoreServices, which iOS lacks anyway) but
# that path never sets a C++ standard, so add -std=c++11 by hand.

SUBPROJECTS      += exempi
EXEMPI_VERSION   := 2.5.2
EXEMPI_SOV       := 8
DEB_EXEMPI_V     ?= $(EXEMPI_VERSION)+ios1

exempi-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://libopenraw.freedesktop.org/download/exempi-$(EXEMPI_VERSION).tar.bz2)
	$(call EXTRACT_TAR,exempi-$(EXEMPI_VERSION).tar.bz2,exempi-$(EXEMPI_VERSION),exempi)
	# The 2020 tarball's config.sub predates the aarch64-apple-darwin triple — refresh it
	# with the host's modern copy.
	find $(BUILD_WORK)/exempi -name config.sub  -exec cp -f /usr/share/misc/config.sub  {} \; || true
	find $(BUILD_WORK)/exempi -name config.guess -exec cp -f /usr/share/misc/config.guess {} \; || true
	$(call DO_PATCH,exempi,exempi,-p1)

ifneq ($(wildcard $(BUILD_WORK)/exempi/.build_complete),)
exempi:
	@echo "Using previously built exempi."
else
# No make-level deps: expat/zlib/iconv are pre-staged in build_base and have no standalone
# recipe targets.
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

	cp -a $(BUILD_STAGE)/exempi/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexempi.*.dylib \
		$(BUILD_DIST)/libexempi$(EXEMPI_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# The bin/exempi CLI is not needed by Papers; drop it.
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
