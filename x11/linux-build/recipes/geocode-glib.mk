ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# geocode-glib.mk — geocoding/reverse-geocoding client library. A build dep of libgweather-4
# (which gnome-shell imports at boot). GDBus/HTTP client on glib + json-glib + libsoup3.
# Introspection off (GeocodeGlib typelib generated on-device with the rest).

SUBPROJECTS         += geocode-glib
GEOCODE-GLIB_VERSION := 3.26.4
DEB_GEOCODE-GLIB_V  ?= $(GEOCODE-GLIB_VERSION)

geocode-glib-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/geocode-glib/$(shell echo $(GEOCODE-GLIB_VERSION) | cut -f-2 -d.)/geocode-glib-$(GEOCODE-GLIB_VERSION).tar.xz)
	$(call EXTRACT_TAR,geocode-glib-$(GEOCODE-GLIB_VERSION).tar.xz,geocode-glib-$(GEOCODE-GLIB_VERSION),geocode-glib)
	rm -rf $(BUILD_WORK)/geocode-glib/build && mkdir -p $(BUILD_WORK)/geocode-glib/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/geocode-glib/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/geocode-glib/.build_complete),)
geocode-glib:
	@echo "Using previously built geocode-glib."
else
geocode-glib: geocode-glib-setup glib2.0 json-glib libsoup3
	cd $(BUILD_WORK)/geocode-glib/build && meson \
		--cross-file cross.txt \
		-Denable-introspection=false \
		-Denable-installed-tests=false \
		-Denable-gtk-doc=false \
		-Dsoup2=false \
		..
	+ninja -C $(BUILD_WORK)/geocode-glib/build
	+DESTDIR="$(BUILD_STAGE)/geocode-glib" ninja -C $(BUILD_WORK)/geocode-glib/build install
	$(call AFTER_BUILD,copy)
endif

geocode-glib-package: geocode-glib-stage
	rm -rf $(BUILD_DIST)/libgeocode-glib0 $(BUILD_DIST)/libgeocode-glib-dev
	mkdir -p $(BUILD_DIST)/libgeocode-glib0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgeocode-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/geocode-glib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgeocode-glib*.dylib \
		$(BUILD_DIST)/libgeocode-glib0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/geocode-glib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgeocode-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/geocode-glib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgeocode-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	$(call SIGN,libgeocode-glib0,general.xml)
	$(call PACK,libgeocode-glib0,DEB_GEOCODE-GLIB_V)
	$(call PACK,libgeocode-glib-dev,DEB_GEOCODE-GLIB_V)
	rm -rf $(BUILD_DIST)/libgeocode-glib0 $(BUILD_DIST)/libgeocode-glib-dev

.PHONY: geocode-glib geocode-glib-package
