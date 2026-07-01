ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gweather4.mk — libgweather-4, weather/location library. gnome-shell imports gi://GWeather
# (version 4.0) in dateMenu.js at panel boot, so the GWeather-4.0 typelib + dylib are
# boot-critical. glib + libxml2 + geocode-glib + libsoup3 (all present/built). Introspection
# off (GWeather-4.0 typelib generated on-device); vala/tests/docs off. Weather is inert without
# a geoclue location daemon, but the typelib must exist for the static import.

SUBPROJECTS       += gweather4
GWEATHER4_VERSION := 4.4.2
DEB_GWEATHER4_V   ?= $(GWEATHER4_VERSION)

gweather4-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libgweather/$(shell echo $(GWEATHER4_VERSION) | cut -f-2 -d.)/libgweather-$(GWEATHER4_VERSION).tar.xz)
	$(call EXTRACT_TAR,libgweather-$(GWEATHER4_VERSION).tar.xz,libgweather-$(GWEATHER4_VERSION),gweather4)
	rm -rf $(BUILD_WORK)/gweather4/build && mkdir -p $(BUILD_WORK)/gweather4/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gweather4/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gweather4/.build_complete),)
gweather4:
	@echo "Using previously built gweather4."
else
gweather4: gweather4-setup glib2.0 libxml2 geocode-glib libsoup3
	cd $(BUILD_WORK)/gweather4/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Denable_vala=false \
		-Dtests=false \
		-Dgtk_doc=false \
		-Dsoup2=false \
		..
	+ninja -C $(BUILD_WORK)/gweather4/build
	+DESTDIR="$(BUILD_STAGE)/gweather4" ninja -C $(BUILD_WORK)/gweather4/build install
	$(call AFTER_BUILD,copy)
endif

gweather4-package: gweather4-stage
	rm -rf $(BUILD_DIST)/libgweather-4-0 $(BUILD_DIST)/libgweather-4-dev
	mkdir -p $(BUILD_DIST)/libgweather-4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgweather-4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# runtime: dylib + the location/timezone data + gschema the lib reads at runtime
	cp -a $(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgweather-4*.dylib \
		$(BUILD_DIST)/libgweather-4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	if [ -d "$(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/libgweather-4" ]; then \
		mkdir -p $(BUILD_DIST)/libgweather-4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/libgweather-4 \
			$(BUILD_DIST)/libgweather-4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/; \
	fi
	if [ -d "$(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0/schemas" ]; then \
		mkdir -p $(BUILD_DIST)/libgweather-4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0; \
		cp -a $(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0/schemas \
			$(BUILD_DIST)/libgweather-4-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0/; \
	fi
	# dev: headers, pkgconfig, unversioned symlink
	cp -a $(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgweather-4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/ 2>/dev/null || true
	cp -a $(BUILD_STAGE)/gweather4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgweather-4-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/ 2>/dev/null || true
	$(call SIGN,libgweather-4-0,general.xml)
	$(call PACK,libgweather-4-0,DEB_GWEATHER4_V)
	$(call PACK,libgweather-4-dev,DEB_GWEATHER4_V)
	rm -rf $(BUILD_DIST)/libgweather-4-0 $(BUILD_DIST)/libgweather-4-dev

.PHONY: gweather4 gweather4-package
