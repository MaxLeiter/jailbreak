ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Depends on gtk4 + appstream (libadwaita 1.4 meson.build requires it) + fribidi/glib.
# sassc compiles the SCSS stylesheet at build time and runs on the Linux build host,
# not the target -- add it to the Dockerfile apt line, not as a recipe dep.

SUBPROJECTS        += libadwaita
LIBADWAITA_MAJOR_V := 1.5
LIBADWAITA_VERSION := $(LIBADWAITA_MAJOR_V).0
DEB_LIBADWAITA_V   ?= $(LIBADWAITA_VERSION)+ios1

libadwaita-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libadwaita/$(LIBADWAITA_MAJOR_V)/libadwaita-$(LIBADWAITA_VERSION).tar.xz)
	$(call EXTRACT_TAR,libadwaita-$(LIBADWAITA_VERSION).tar.xz,libadwaita-$(LIBADWAITA_VERSION),libadwaita)
	# Cross file declares system='darwin' (true, it's iOS), so both meson and the C sources'
	# #ifdef __APPLE__ gates would otherwise select the macOS AppKit settings backend, which
	# doesn't exist here. The patch forces those conditions off so the xdg-desktop-portal
	# backend (adw-settings-impl-portal.c) is used instead.
	$(call DO_PATCH,libadwaita,libadwaita,-p1)
	mkdir -p $(BUILD_WORK)/libadwaita/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libadwaita/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libadwaita/.build_complete),)
libadwaita:
	@echo "Using previously built libadwaita."
else
libadwaita: libadwaita-setup gtk4 appstream
	cd $(BUILD_WORK)/libadwaita/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dvapi=false \
		-Dtests=false \
		-Dexamples=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/libadwaita/build
	+DESTDIR="$(BUILD_STAGE)/libadwaita" ninja -C $(BUILD_WORK)/libadwaita/build install
	$(call AFTER_BUILD,copy)
endif

libadwaita-package: libadwaita-stage
	rm -rf $(BUILD_DIST)/libadwaita-1-0 $(BUILD_DIST)/libadwaita-1-dev
	mkdir -p $(BUILD_DIST)/libadwaita-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libadwaita-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libadwaita-1-0 (runtime dylib + any installed data)
	cp -a $(BUILD_STAGE)/libadwaita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libadwaita-1.0.dylib $(BUILD_DIST)/libadwaita-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libadwaita-1-dev (headers, symlink, .pc)
	cp -a $(BUILD_STAGE)/libadwaita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libadwaita-1.0.dylib) $(BUILD_DIST)/libadwaita-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libadwaita/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libadwaita-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libadwaita-1-0,general.xml)
	$(call PACK,libadwaita-1-0,DEB_LIBADWAITA_V)
	$(call PACK,libadwaita-1-dev,DEB_LIBADWAITA_V)
	rm -rf $(BUILD_DIST)/libadwaita-1-0 $(BUILD_DIST)/libadwaita-1-dev

.PHONY: libadwaita libadwaita-package
