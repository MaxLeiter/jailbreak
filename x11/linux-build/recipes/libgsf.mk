ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libgsf - GNOME structured file library. Gnumeric/goffice need libgsf-1;
# keep this first iOS cut lean: no introspection, no gdk-pixbuf thumbnailer,
# and no optional bzip2 wrapper.

SUBPROJECTS       += libgsf
LIBGSF_MAJOR_V    := 1.14
LIBGSF_VERSION    := $(LIBGSF_MAJOR_V).58
DEB_LIBGSF_V      ?= $(LIBGSF_VERSION)+ios1

libgsf-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libgsf/$(LIBGSF_MAJOR_V)/libgsf-$(LIBGSF_VERSION).tar.xz)
	$(call EXTRACT_TAR,libgsf-$(LIBGSF_VERSION).tar.xz,libgsf-$(LIBGSF_VERSION),libgsf)

ifneq ($(wildcard $(BUILD_WORK)/libgsf/.build_complete),)
libgsf:
	@echo "Using previously built libgsf."
else
libgsf: libgsf-setup glib2.0 libxml2 zlib-ng
	cd $(BUILD_WORK)/libgsf && rm -f config.cache && \
		PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--without-bz2 \
		--without-gdk-pixbuf
	+$(MAKE) -C $(BUILD_WORK)/libgsf
	+$(MAKE) -C $(BUILD_WORK)/libgsf install DESTDIR=$(BUILD_STAGE)/libgsf
	$(call AFTER_BUILD,copy)
endif

libgsf-package: libgsf-stage
	rm -rf $(BUILD_DIST)/libgsf-1-114 $(BUILD_DIST)/libgsf-1-dev
	mkdir -p $(BUILD_DIST)/libgsf-1-114/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgsf-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libgsf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgsf-1.114.dylib \
		$(BUILD_DIST)/libgsf-1-114/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libgsf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgsf-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libgsf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libgsf-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libgsf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgsf-1.dylib \
		$(BUILD_DIST)/libgsf-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libgsf-1-114,general.xml)
	$(call PACK,libgsf-1-114,DEB_LIBGSF_V)
	$(call PACK,libgsf-1-dev,DEB_LIBGSF_V)
	rm -rf $(BUILD_DIST)/libgsf-1-114 $(BUILD_DIST)/libgsf-1-dev

.PHONY: libgsf libgsf-package
