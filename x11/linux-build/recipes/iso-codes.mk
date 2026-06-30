ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# iso-codes.mk — ISO country/language/currency code lists + translations. Data-only (no
# compiled code); a hard dependency of gnome-desktop-4 (GnomeLanguages). GTK-independent.
#
# NOTE: iso-codes lives on Debian salsa; the archive tarball has no pre-generated configure,
# so we autoreconf first (needs autoconf/automake/gettext on the build host). If a release
# dist tarball (with ./configure) is mirrored, drop the autoreconf line and adjust the URL.
#
# DRAFT — Phase 1, NOT built/verified.

SUBPROJECTS        += iso-codes
ISO-CODES_VERSION  := 4.15.0
DEB_ISO-CODES_V    ?= $(ISO-CODES_VERSION)

iso-codes-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://salsa.debian.org/iso-codes-team/iso-codes/-/archive/v$(ISO-CODES_VERSION)/iso-codes-v$(ISO-CODES_VERSION).tar.gz)
	$(call EXTRACT_TAR,iso-codes-v$(ISO-CODES_VERSION).tar.gz,iso-codes-v$(ISO-CODES_VERSION),iso-codes)

ifneq ($(wildcard $(BUILD_WORK)/iso-codes/.build_complete),)
iso-codes:
	@echo "Using previously built iso-codes."
else
iso-codes: iso-codes-setup
	cd $(BUILD_WORK)/iso-codes && [ -f configure ] || autoreconf -fi
	cd $(BUILD_WORK)/iso-codes && ./configure -C $(DEFAULT_CONFIGURE_FLAGS)
	+$(MAKE) -C $(BUILD_WORK)/iso-codes
	+$(MAKE) -C $(BUILD_WORK)/iso-codes install DESTDIR=$(BUILD_STAGE)/iso-codes
	$(call AFTER_BUILD,copy)
endif

iso-codes-package: iso-codes-stage
	# data-only: share/xml/iso-codes, share/locale, share/pkgconfig/iso-codes.pc
	rm -rf $(BUILD_DIST)/iso-codes
	mkdir -p $(BUILD_DIST)/iso-codes/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/iso-codes/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/iso-codes/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,iso-codes,general.xml)
	$(call PACK,iso-codes,DEB_ISO-CODES_V)
	rm -rf $(BUILD_DIST)/iso-codes

.PHONY: iso-codes iso-codes-package
