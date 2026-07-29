ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# EVERY optional module is on, deliberately. This package name shadows Procursus's
# libxml2, so it must be a strict SUPERSET of it or consumers linked against theirs
# lose symbols at load. 2.13 turned http/ftp/legacy/lzma OFF by default, and +ios1
# took the defaults: that dropped _xmlNanoHTTP* and broke our own libgsf-1-114 (and
# Procursus python3-libxml2) at dyld. See the same lesson in recipes-ladybird/harfbuzz.mk.
# What CANNOT be restored by a flag: the DocBook SAX API (docb*), deleted upstream at
# 2.12 with no option to bring it back.

SUBPROJECTS      += libxml2
LIBXML2_VERSION  := 2.13.8
LIBXML2_MAJMIN   := 2.13
DEB_LIBXML2_V    ?= $(LIBXML2_VERSION)+ios2

libxml2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libxml2/$(LIBXML2_MAJMIN)/libxml2-$(LIBXML2_VERSION).tar.xz)
	# Stale-tree guard (ICU lesson): this volume was cloned from the gtk track, which carries an
	# OLD libxml2 2.9.12 tree in build_work. EXTRACT_TAR no-ops when build_work/libxml2 exists, so
	# without this wipe the 2.9.12 source rebuilds and gets mislabeled $(LIBXML2_VERSION)+ios1.
	if [ -d $(BUILD_WORK)/libxml2 ] && ! grep -q "^PACKAGE_VERSION='$(LIBXML2_VERSION)'" $(BUILD_WORK)/libxml2/configure 2>/dev/null; then \
		echo "libxml2: stale source tree in build_work (not $(LIBXML2_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/libxml2 $(BUILD_STAGE)/libxml2; \
	fi
	$(call EXTRACT_TAR,libxml2-$(LIBXML2_VERSION).tar.xz,libxml2-$(LIBXML2_VERSION),libxml2)

ifneq ($(wildcard $(BUILD_WORK)/libxml2/.build_complete),)
libxml2:
	@echo "Using previously built libxml2."
else
# --with-legacy/http/ftp/lzma are all OFF by default in 2.13 and all three of the first
# are pure ABI surface Procursus's build exports; lzma restores the __libxml2_xz*
# internals. liblzma is already staged in this volume. Python bindings stay off (they
# need a staged target python3); Procursus ships python3-libxml2 separately.
libxml2: libxml2-setup zlib
	cd $(BUILD_WORK)/libxml2 && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
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
		DESTDIR=$(BUILD_STAGE)/libxml2
	$(call AFTER_BUILD,copy)
endif

libxml2-package: .SHELLFLAGS=-O extglob -c
libxml2-package: libxml2-stage
	# libxml2.mk Package Structure (python3-libxml2 dropped)
	rm -rf $(BUILD_DIST)/libxml2{,-dev,-utils}
	mkdir -p $(BUILD_DIST)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,lib,share/man/man1} \
		$(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,share/man/man1}

	# libxml2.mk Prep libxml2 (runtime)
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxml2.[0-9]*.dylib $(BUILD_DIST)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libxml2.mk Prep libxml2-utils (xmllint, xmlcatalog; not xml2-config)
	-cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/!(xml2-config) $(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	-cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/!(xml2-config.1$(MEMO_MANPAGE_SUFFIX)) $(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1

	# libxml2.mk Prep libxml2-dev
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libxml2.[0-9]*.dylib) $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/xml2-config $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# libxml2.mk Sign
	$(call SIGN,libxml2,general.xml)
	$(call SIGN,libxml2-utils,general.xml)

	# libxml2.mk Make .debs
	$(call PACK,libxml2,DEB_LIBXML2_V)
	$(call PACK,libxml2-utils,DEB_LIBXML2_V)
	$(call PACK,libxml2-dev,DEB_LIBXML2_V)

	# libxml2.mk Build cleanup
	rm -rf $(BUILD_DIST)/libxml2{,-dev,-utils}

.PHONY: libxml2 libxml2-package
