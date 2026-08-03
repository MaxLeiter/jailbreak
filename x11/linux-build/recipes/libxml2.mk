ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Override of upstream Procursus libxml2 for the GNOME track: upstream also builds the
# optional Python bindings, which need a staged target python3 (Python.h) that nothing in
# the GNOME app chain actually links. This override builds --without-python and drops the
# python3-libxml2 package, removing the target-python3 dependency entirely.
#
# VERSION/FLAGS MUST TRACK recipes-ladybird/libxml2.mk. Both roots build a package named
# libxml2 that shadows Procursus's, and build-libxml2-full.sh copies the ladybird recipe
# over this one, so a divergence here is invisible until the GNOME track builds alone.
# This file sat at 2.9.12 (2021, plaintext http, and a *downgrade* against the published
# 2.13.8+ios2) while the ladybird recipe shipped 2.13.8; build-ladybird-wave4.sh had to
# wipe "the 2.9.12 shadow" every run to compensate. Fixed at the pin instead.
#
# The module flags below are not cosmetic: 2.13 flipped http/ftp/legacy/lzma to
# default-off, and taking those defaults drops _xmlNanoHTTP* (plus the legacy entity API
# and the __libxml2_xz* internals), which breaks our own libgsf-1-114 and Procursus's
# python3-libxml2 at dyld. This package must stay a strict SUPERSET of Procursus's.

SUBPROJECTS     += libxml2
LIBXML2_VERSION := 2.13.8
LIBXML2_MAJMIN  := 2.13
DEB_LIBXML2_V   ?= $(LIBXML2_VERSION)+ios2

### Provided by macOS/iOS and only used for tools. Try not to link anything to this.

libxml2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libxml2/$(LIBXML2_MAJMIN)/libxml2-$(LIBXML2_VERSION).tar.xz)
	# Stale-tree guard (same as the ladybird recipe): EXTRACT_TAR no-ops when
	# build_work/libxml2 exists, so a volume carrying the old 2.9.12 tree would rebuild
	# 2.9.12 and mislabel it $(LIBXML2_VERSION).
	if [ -d $(BUILD_WORK)/libxml2 ] && ! grep -q "^PACKAGE_VERSION='$(LIBXML2_VERSION)'" $(BUILD_WORK)/libxml2/configure 2>/dev/null; then \
		echo "libxml2: stale source tree in build_work (not $(LIBXML2_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/libxml2 $(BUILD_STAGE)/libxml2; \
	fi
	$(call EXTRACT_TAR,libxml2-$(LIBXML2_VERSION).tar.xz,libxml2-$(LIBXML2_VERSION),libxml2)

ifneq ($(wildcard $(BUILD_WORK)/libxml2/.build_complete),)
libxml2:
	@echo "Using previously built libxml2."
else
libxml2: libxml2-setup xz zlib ncurses readline
	cd $(BUILD_WORK)/libxml2 && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--libdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib \
		--with-history \
		--without-python \
		--with-lzma \
		--with-zlib \
		--with-threads \
		--with-iconv \
		--with-legacy \
		--with-http \
		--with-ftp \
		--with-sax1 \
		--with-output
	+$(MAKE) -C $(BUILD_WORK)/libxml2 install \
		DESTDIR=$(BUILD_STAGE)/libxml2 \
		RDL_LIBS="-lreadline -lhistory -lncursesw"
	$(call AFTER_BUILD)
endif

libxml2-package: libxml2-stage
	rm -rf $(BUILD_DIST)/libxml2{,-dev,-utils}
	mkdir -p $(BUILD_DIST)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib \
		$(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,$(MEMO_ALT_PREFIX)/lib,share/man/man1} \
		$(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,share/man/man1}

	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib/libxml2.2.dylib $(BUILD_DIST)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/!(xml2-config) $(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/!(xml2-config.1$(MEMO_MANPAGE_SUFFIX)) $(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1

	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib/!(libxml2.2.dylib) $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/xml2-config $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/xml2-config.1$(MEMO_MANPAGE_SUFFIX) $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man3 $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	$(call SIGN,libxml2,general.xml)
	$(call SIGN,libxml2-utils,general.xml)

	$(call PACK,libxml2,DEB_LIBXML2_V)
	$(call PACK,libxml2-utils,DEB_LIBXML2_V)
	$(call PACK,libxml2-dev,DEB_LIBXML2_V)

	rm -rf $(BUILD_DIST)/libxml2{,-dev,-utils}

.PHONY: libxml2 libxml2-package
