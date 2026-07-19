ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# json-glib.mk — JSON parser/generator built on GLib types. Needed by tracker (and broadly
# useful across GNOME). glib only; trivial. GTK-independent.
#
# BUILT/PUBLISHED — libjson-glib-1.0-0 1.8.0+ios1.

SUBPROJECTS       += json-glib
JSON-GLIB_MAJOR_V := 1.8
JSON-GLIB_VERSION := $(JSON-GLIB_MAJOR_V).0
DEB_JSON-GLIB_V   ?= $(JSON-GLIB_VERSION)+ios1

json-glib-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/json-glib/$(JSON-GLIB_MAJOR_V)/json-glib-$(JSON-GLIB_VERSION).tar.xz)
	$(call EXTRACT_TAR,json-glib-$(JSON-GLIB_VERSION).tar.xz,json-glib-$(JSON-GLIB_VERSION),json-glib)
	mkdir -p $(BUILD_WORK)/json-glib/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/json-glib/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/json-glib/.build_complete),)
json-glib:
	@echo "Using previously built json-glib."
else
json-glib: json-glib-setup glib2.0
	cd $(BUILD_WORK)/json-glib/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dgtk_doc=disabled \
		-Dtests=false \
		..
	+ninja -C $(BUILD_WORK)/json-glib/build
	+DESTDIR="$(BUILD_STAGE)/json-glib" ninja -C $(BUILD_WORK)/json-glib/build install
	$(call AFTER_BUILD,copy)
endif

json-glib-package: json-glib-stage
	rm -rf $(BUILD_DIST)/libjson-glib-1.0-0 $(BUILD_DIST)/libjson-glib-dev
	mkdir -p $(BUILD_DIST)/libjson-glib-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libjson-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/json-glib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjson-glib-1.0.0.dylib $(BUILD_DIST)/libjson-glib-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/json-glib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libjson-glib-1.0.0.dylib) $(BUILD_DIST)/libjson-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/json-glib/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libjson-glib-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libjson-glib-1.0-0,general.xml)
	$(call PACK,libjson-glib-1.0-0,DEB_JSON-GLIB_V)
	$(call PACK,libjson-glib-dev,DEB_JSON-GLIB_V)
	rm -rf $(BUILD_DIST)/libjson-glib-1.0-0 $(BUILD_DIST)/libjson-glib-dev

.PHONY: json-glib json-glib-package
