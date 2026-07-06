ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxslt - XSLT support library required by goffice/Gnumeric. Keep this first
# iOS cut lean: no Python bindings, crypto extension, debugger, or plugins.

SUBPROJECTS       += libxslt
LIBXSLT_VERSION   := 1.1.43
DEB_LIBXSLT_V     ?= $(LIBXSLT_VERSION)+ios1

libxslt-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libxslt/1.1/libxslt-$(LIBXSLT_VERSION).tar.xz)
	$(call EXTRACT_TAR,libxslt-$(LIBXSLT_VERSION).tar.xz,libxslt-$(LIBXSLT_VERSION),libxslt)

ifneq ($(wildcard $(BUILD_WORK)/libxslt/.build_complete),)
libxslt:
	@echo "Using previously built libxslt."
else
libxslt: libxslt-setup libxml2
	cd $(BUILD_WORK)/libxslt && rm -f config.cache && \
		PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--without-python \
		--without-crypto \
		--without-debug \
		--without-debugger \
		--without-plugins
	+$(MAKE) -C $(BUILD_WORK)/libxslt
	+$(MAKE) -C $(BUILD_WORK)/libxslt install DESTDIR=$(BUILD_STAGE)/libxslt
	$(call AFTER_BUILD,copy)
endif

libxslt-package: libxslt-stage
	rm -rf $(BUILD_DIST)/libxslt1.1 $(BUILD_DIST)/libxslt1-dev
	mkdir -p $(BUILD_DIST)/libxslt1.1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxslt1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxslt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxslt.1.dylib \
		$(BUILD_DIST)/libxslt1.1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxslt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexslt.0.dylib \
		$(BUILD_DIST)/libxslt1.1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxslt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxslt1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libxslt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libxslt1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxslt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxslt.dylib \
		$(BUILD_DIST)/libxslt1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxslt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libexslt.dylib \
		$(BUILD_DIST)/libxslt1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libxslt1.1,general.xml)
	$(call PACK,libxslt1.1,DEB_LIBXSLT_V)
	$(call PACK,libxslt1-dev,DEB_LIBXSLT_V)
	rm -rf $(BUILD_DIST)/libxslt1.1 $(BUILD_DIST)/libxslt1-dev

.PHONY: libxslt libxslt-package
