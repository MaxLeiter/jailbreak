ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Gnumeric - GTK3 spreadsheet. 1.12.61 requires goffice 0.10.61. This first
# iOS package keeps the core UI, libspreadsheet, common file-format/function
# plugins, schemas and desktop data; optional loaders/runtimes stay disabled.

SUBPROJECTS       += gnumeric
GNUMERIC_MAJOR_V  := 1.12
GNUMERIC_VERSION  := $(GNUMERIC_MAJOR_V).61
DEB_GNUMERIC_V    ?= $(GNUMERIC_VERSION)+ios1

GNUMERIC_PLUGINS  := excel openoffice html dif sylk xbase \
	fn-date fn-financial fn-info fn-logical fn-lookup fn-math fn-stat fn-string

gnumeric-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gnumeric/$(GNUMERIC_MAJOR_V)/gnumeric-$(GNUMERIC_VERSION).tar.xz)
	$(call EXTRACT_TAR,gnumeric-$(GNUMERIC_VERSION).tar.xz,gnumeric-$(GNUMERIC_VERSION),gnumeric)

ifneq ($(wildcard $(BUILD_WORK)/gnumeric/.build_complete),)
gnumeric:
	@echo "Using previously built gnumeric."
else
gnumeric: gnumeric-setup goffice libgsf libxml2 gtk+3.0 pango cairo zlib-ng
	cd $(BUILD_WORK)/gnumeric && rm -f config.cache && \
		CPPFLAGS="$(CPPFLAGS) -DNEEDS_LGAMMA_R_PROTOTYPE=1" \
		PKG_CONFIG=$(BUILD_TOOLS)/cross-pkg-config ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-gtk-doc \
		--disable-introspection \
		--disable-component \
		--enable-plugins="$(GNUMERIC_PLUGINS)" \
		--with-gtk \
		--without-psiconv \
		--without-paradox \
		--without-perl \
		--without-python \
		--without-long-double
	+$(MAKE) -C $(BUILD_WORK)/gnumeric GLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources
	+$(MAKE) -C $(BUILD_WORK)/gnumeric install DESTDIR=$(BUILD_STAGE)/gnumeric GLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources
	$(call AFTER_BUILD,copy)
endif

gnumeric-package: gnumeric-stage
	rm -rf $(BUILD_DIST)/gnumeric
	mkdir -p $(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	cp -a $(BUILD_STAGE)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib $(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	rm -rf $(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.a \
		$(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*.la \
		$(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gtk-doc \
		$(BUILD_DIST)/gnumeric/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man

	$(call SIGN,gnumeric,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,gnumeric,DEB_GNUMERIC_V)
	rm -rf $(BUILD_DIST)/gnumeric

.PHONY: gnumeric gnumeric-package
