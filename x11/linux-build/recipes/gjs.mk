ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS   += gjs
GJS_MAJOR_V   := 1.78
GJS_VERSION   := $(GJS_MAJOR_V).0
DEB_GJS_V     ?= $(GJS_VERSION)+ios1

gjs-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/gjs/$(GJS_MAJOR_V)/gjs-$(GJS_VERSION).tar.xz)
	$(call EXTRACT_TAR,gjs-$(GJS_VERSION).tar.xz,gjs-$(GJS_VERSION),gjs)
	$(call DO_PATCH,gjs,gjs,-p1)
	rm -rf $(BUILD_WORK)/gjs/build
	mkdir -p $(BUILD_WORK)/gjs/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gjs/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gjs/.build_complete),)
gjs:
	@echo "Using previously built gjs."
else
gjs: gjs-setup mozjs glib2.0 cairo gobject-introspection readline
	cd $(BUILD_WORK)/gjs/build && meson \
		--cross-file cross.txt \
		-Dprofiler=disabled \
		-Dinstalled_tests=false \
		-Dskip_dbus_tests=true \
		-Dskip_gtk_tests=true \
		-Dbsymbolic_functions=false \
		-Dreadline=disabled \
		..
	+ninja -C $(BUILD_WORK)/gjs/build
	+DESTDIR="$(BUILD_STAGE)/gjs" ninja -C $(BUILD_WORK)/gjs/build install
	$(call AFTER_BUILD,copy)
endif

gjs-package: gjs-stage
	rm -rf $(BUILD_DIST)/libgjs0 $(BUILD_DIST)/gjs $(BUILD_DIST)/libgjs-dev
	mkdir -p $(BUILD_DIST)/libgjs0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/gjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/libgjs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime lib
	cp -a $(BUILD_STAGE)/gjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgjs.*dylib \
		$(BUILD_DIST)/libgjs0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# the gjs / gjs-console interpreter
	cp -a $(BUILD_STAGE)/gjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/* \
		$(BUILD_DIST)/gjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# dev: headers + .pc + symlinks
	cp -a $(BUILD_STAGE)/gjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgjs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) 2>/dev/null || true
	cp -a $(BUILD_STAGE)/gjs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgjs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true

	$(call SIGN,libgjs0,general.xml)
	$(call SIGN,gjs,general.xml)
	$(call PACK,libgjs0,DEB_GJS_V)
	$(call PACK,gjs,DEB_GJS_V)
	$(call PACK,libgjs-dev,DEB_GJS_V)
	rm -rf $(BUILD_DIST)/libgjs0 $(BUILD_DIST)/gjs $(BUILD_DIST)/libgjs-dev

.PHONY: gjs gjs-package
