ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Overrides Procursus's disabled recipe, pinned to 1.78 (pairs with glib 2.78 / gjs 1.78).
#
# This recipe cross-builds only libgirepository (the runtime loader) + g-ir-scanner/
# g-ir-compiler/g-ir-generate (the tools), with -Dbuild_introspection_data=false so it
# doesn't try to scan glib itself (that scan compiles+runs an iOS probe binary, which a
# Linux cross host can't do). The actual typelib data (gir1.2-glib-2.0 etc.) is generated
# on-device instead (../gir-ondevice.sh), since g-ir-scanner has to run natively to
# produce real typelibs.

SUBPROJECTS                   += gobject-introspection
GOBJECT-INTROSPECTION_VERSION := 1.78.0
DEB_GOBJECT-INTROSPECTION_V   ?= $(GOBJECT-INTROSPECTION_VERSION)+ios1

gobject-introspection-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/gobject-introspection/$(shell echo $(GOBJECT-INTROSPECTION_VERSION) | cut -f-2 -d.)/gobject-introspection-$(GOBJECT-INTROSPECTION_VERSION).tar.xz)
	$(call EXTRACT_TAR,gobject-introspection-$(GOBJECT-INTROSPECTION_VERSION).tar.xz,gobject-introspection-$(GOBJECT-INTROSPECTION_VERSION),gobject-introspection)
	rm -rf $(BUILD_WORK)/gobject-introspection/build
	mkdir -p $(BUILD_WORK)/gobject-introspection/build
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
	python = '$(shell command -v python3)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gobject-introspection/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gobject-introspection/.build_complete),)
gobject-introspection:
	@echo "Using previously built gobject-introspection."
else
gobject-introspection: gobject-introspection-setup glib2.0 libffi python3
	cd $(BUILD_WORK)/gobject-introspection/build && meson \
		--cross-file cross.txt \
		-Dbuild_introspection_data=false \
		-Dcairo=disabled -Ddoctool=disabled -Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/gobject-introspection/build
	+DESTDIR="$(BUILD_STAGE)/gobject-introspection" ninja -C $(BUILD_WORK)/gobject-introspection/build install
	# point the scanner shebangs at the on-device python3
	sed -i "1s|#!.*python3|#!$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/python3|" \
		$(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/g-ir-* 2>/dev/null || true
	$(call AFTER_BUILD,copy)
endif

gobject-introspection-package: gobject-introspection-stage
	rm -rf $(BUILD_DIST)/libgirepository-1.0-{1,dev} $(BUILD_DIST)/gobject-introspection
	mkdir -p $(BUILD_DIST)/libgirepository-1.0-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgirepository-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib,share} \
		$(BUILD_DIST)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib,share}

	# libgirepository-1.0-1 (runtime loader)
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgirepository-1.0.1.dylib \
		$(BUILD_DIST)/libgirepository-1.0-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libgirepository-1.0-dev (headers, .pc, the gir XML templates)
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{libgirepository-1.0.dylib,pkgconfig} \
		$(BUILD_DIST)/libgirepository-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgirepository-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gir-1.0 \
		$(BUILD_DIST)/libgirepository-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share 2>/dev/null || true

	# gobject-introspection (the tools + python giscanner module)
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gobject-introspection \
		$(BUILD_DIST)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gobject-introspection-1.0 \
		$(BUILD_DIST)/gobject-introspection/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share 2>/dev/null || true

	$(call SIGN,libgirepository-1.0-1,general.xml)
	$(call SIGN,gobject-introspection,general.xml)
	$(call PACK,libgirepository-1.0-1,DEB_GOBJECT-INTROSPECTION_V)
	$(call PACK,libgirepository-1.0-dev,DEB_GOBJECT-INTROSPECTION_V)
	$(call PACK,gobject-introspection,DEB_GOBJECT-INTROSPECTION_V)
	# NOTE: gir1.2-glib-2.0 (the GLib/GObject/Gio/GModule/GIRepository typelibs) is NOT built
	# here — generate it on-device with `gir-ondevice.sh bootstrap` (it scans glib natively).

	rm -rf $(BUILD_DIST)/libgirepository-1.0-{1,dev} $(BUILD_DIST)/gobject-introspection

.PHONY: gobject-introspection gobject-introspection-package
