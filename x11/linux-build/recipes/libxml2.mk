ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxml2.mk — OVERRIDE of upstream Procursus libxml2 for the GNOME (build-gnome.sh) track.
# Upstream's recipe ALSO compiles libxml2's optional Python bindings (python/setup.py), which
# requires a staged target python3 (Python.h) AND a host autoconf-archive. Nothing in the GNOME
# app chain (appstream/libadwaita/vte/gnome-console) links the python bindings — they only need
# the C library (already built --without-python). So this override drops the python-bindings
# build step and the python3-libxml2 package, removing the target-python3 dependency entirely.
# Identical otherwise (version, patch, configure flags) to keep ABI matched with the rest.

SUBPROJECTS     += libxml2
LIBXML2_VERSION := 2.9.12
DEB_LIBXML2_V   ?= $(LIBXML2_VERSION)

### Provided by macOS/iOS and only used for tools. Try not to link anything to this.

libxml2-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),http://xmlsoft.org/sources/libxml2-$(LIBXML2_VERSION).tar.gz)
	$(call EXTRACT_TAR,libxml2-$(LIBXML2_VERSION).tar.gz,libxml2-$(LIBXML2_VERSION),libxml2)
	$(call DO_PATCH,libxml2,libxml2,-p1)

ifneq ($(wildcard $(BUILD_WORK)/libxml2/.build_complete),)
libxml2:
	@echo "Using previously built libxml2."
else
libxml2: libxml2-setup xz ncurses readline
	cd $(BUILD_WORK)/libxml2 && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--libdir=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib \
		--with-history \
		--without-python
	+$(MAKE) -C $(BUILD_WORK)/libxml2 install \
		DESTDIR=$(BUILD_STAGE)/libxml2 \
		RDL_LIBS="-lreadline -lhistory -lncursesw"
	$(call AFTER_BUILD)
endif

libxml2-package: libxml2-stage
	# libxml2.mk Package Structure (python3-libxml2 dropped — see header)
	rm -rf $(BUILD_DIST)/libxml2{,-dev,-utils}
	mkdir -p $(BUILD_DIST)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib \
		$(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,$(MEMO_ALT_PREFIX)/lib,share/man/man1} \
		$(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{bin,share/man/man1}

	# libxml2.mk Prep libxml2
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib/libxml2.2.dylib $(BUILD_DIST)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib

	# libxml2.mk Prep libxml2-utils
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/!(xml2-config) $(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/!(xml2-config.1$(MEMO_MANPAGE_SUFFIX)) $(BUILD_DIST)/libxml2-utils/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1

	# libxml2.mk Prep libxml2-dev
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib/!(libxml2.2.dylib) $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)$(MEMO_ALT_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/xml2-config $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1/xml2-config.1$(MEMO_MANPAGE_SUFFIX) $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man1
	cp -a $(BUILD_STAGE)/libxml2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man/man3 $(BUILD_DIST)/libxml2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

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
