ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# GTK3 adaptive widgets used by the WebKitGTK 4.1 generation of GNOME Web.
# Keep this as a normal shared package rather than relying on Geary's private,
# older libhandy subproject.

SUBPROJECTS       += libhandy
LIBHANDY_MAJOR_V  := 1.8
LIBHANDY_VERSION  := $(LIBHANDY_MAJOR_V).3
DEB_LIBHANDY_V    ?= $(LIBHANDY_VERSION)+ios1

libhandy-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libhandy/$(LIBHANDY_MAJOR_V)/libhandy-$(LIBHANDY_VERSION).tar.xz)
	$(call EXTRACT_TAR,libhandy-$(LIBHANDY_VERSION).tar.xz,libhandy-$(LIBHANDY_VERSION),libhandy)
	rm -rf $(BUILD_WORK)/libhandy/build
	mkdir -p $(BUILD_WORK)/libhandy/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libhandy/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libhandy/.build_complete),)
libhandy:
	@echo "Using previously built libhandy."
else
libhandy: libhandy-setup gtk+3.0 fribidi
	cd $(BUILD_WORK)/libhandy/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dintrospection=disabled \
		-Dvapi=false \
		-Dgtk_doc=false \
		-Dtests=false \
		-Dexamples=false \
		-Dglade_catalog=disabled \
		..
	+ninja -C $(BUILD_WORK)/libhandy/build
	+DESTDIR="$(BUILD_STAGE)/libhandy" ninja -C $(BUILD_WORK)/libhandy/build install
	$(call AFTER_BUILD,copy)
endif

libhandy-package: libhandy-stage
	rm -rf $(BUILD_DIST)/libhandy-1-0 $(BUILD_DIST)/libhandy-1-dev
	mkdir -p $(BUILD_DIST)/libhandy-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libhandy-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libhandy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libhandy-1.0.dylib \
		$(BUILD_DIST)/libhandy-1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libhandy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libhandy-1.0.dylib) \
		$(BUILD_DIST)/libhandy-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libhandy/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libhandy-1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libhandy-1-0,general.xml)
	$(call PACK,libhandy-1-0,DEB_LIBHANDY_V)
	$(call PACK,libhandy-1-dev,DEB_LIBHANDY_V)
	rm -rf $(BUILD_DIST)/libhandy-1-0 $(BUILD_DIST)/libhandy-1-dev

.PHONY: libhandy libhandy-package
