ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# goffice - spreadsheet/chart support library used by Gnumeric. Build the GTK3
# UI library but skip optional equation/SVG/EPS/introspection/long-double paths
# for the first iOS package.

SUBPROJECTS       += goffice
GOFFICE_MAJOR_V   := 0.10
GOFFICE_VERSION   := $(GOFFICE_MAJOR_V).61
DEB_GOFFICE_V     ?= $(GOFFICE_VERSION)+ios1

goffice-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/goffice/$(GOFFICE_MAJOR_V)/goffice-$(GOFFICE_VERSION).tar.xz)
	$(call EXTRACT_TAR,goffice-$(GOFFICE_VERSION).tar.xz,goffice-$(GOFFICE_VERSION),goffice)

ifneq ($(wildcard $(BUILD_WORK)/goffice/.build_complete),)
goffice:
	@echo "Using previously built goffice."
else
goffice: goffice-setup glib2.0 libgsf libxml2 gtk+3.0 pango cairo gdk-pixbuf libxslt zlib-ng
	cd $(BUILD_WORK)/goffice && rm -f config.cache && \
		PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--with-config-backend=gsettings \
		--with-lasem=no \
		--without-librsvg \
		--without-long-double
	+$(MAKE) -C $(BUILD_WORK)/goffice
	+$(MAKE) -C $(BUILD_WORK)/goffice install DESTDIR=$(BUILD_STAGE)/goffice
	$(call AFTER_BUILD,copy)
endif

goffice-package: goffice-stage
	rm -rf $(BUILD_DIST)/libgoffice-0.10-10 $(BUILD_DIST)/libgoffice-0.10-dev
	mkdir -p $(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libgoffice-0.10-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/goffice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/goffice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/goffice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	rm -rf $(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.la \
		$(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgoffice-0.10.dylib \
		$(BUILD_DIST)/libgoffice-0.10-10/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc

	cp -a $(BUILD_STAGE)/goffice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgoffice-0.10-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/goffice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libgoffice-0.10-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/goffice/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgoffice-0.10.dylib \
		$(BUILD_DIST)/libgoffice-0.10-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	$(call SIGN,libgoffice-0.10-10,general.xml)
	$(call PACK,libgoffice-0.10-10,DEB_GOFFICE_V)
	$(call PACK,libgoffice-0.10-dev,DEB_GOFFICE_V)
	rm -rf $(BUILD_DIST)/libgoffice-0.10-10 $(BUILD_DIST)/libgoffice-0.10-dev

.PHONY: goffice goffice-package
