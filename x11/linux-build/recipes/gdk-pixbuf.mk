ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += gdk-pixbuf
GDK_PIXBUF_MAJOR_V := 2.42
GDK_PIXBUF_VERSION := $(GDK_PIXBUF_MAJOR_V).12
DEB_LIBGDKPIXBUF_V ?= $(GDK_PIXBUF_VERSION)

gdk-pixbuf-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/gdk-pixbuf/$(GDK_PIXBUF_MAJOR_V)/gdk-pixbuf-$(GDK_PIXBUF_VERSION).tar.xz)
	$(call EXTRACT_TAR,gdk-pixbuf-$(GDK_PIXBUF_VERSION).tar.xz,gdk-pixbuf-$(GDK_PIXBUF_VERSION),gdk-pixbuf)
	mkdir -p $(BUILD_WORK)/gdk-pixbuf/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/gdk-pixbuf/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/gdk-pixbuf/.build_complete),)
gdk-pixbuf:
	@echo "Using previously built gdk-pixbuf."
else
gdk-pixbuf: gdk-pixbuf-setup glib2.0 libpng16 libjpeg-turbo libtiff
	cd $(BUILD_WORK)/gdk-pixbuf/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dgtk_doc=false \
		-Dman=false \
		-Dtests=false \
		-Dinstalled_tests=false \
		-Dpng=enabled \
		-Djpeg=enabled \
		-Dtiff=enabled \
		-Dbuiltin_loaders=all \
		-Dgio_sniffing=false \
		..
	cd $(BUILD_WORK)/gdk-pixbuf/build; \
		DESTDIR="$(BUILD_STAGE)/gdk-pixbuf" meson install
	$(call AFTER_BUILD,copy)
endif

gdk-pixbuf-package: gdk-pixbuf-stage
	# gdk-pixbuf.mk Package Structure
	rm -rf $(BUILD_DIST)/libgdk-pixbuf-2.0-0 $(BUILD_DIST)/libgdk-pixbuf-2.0-dev
	mkdir -p $(BUILD_DIST)/libgdk-pixbuf-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgdk-pixbuf-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# gdk-pixbuf.mk Prep libgdk-pixbuf-2.0-0 (runtime dylib + loader dir)
	cp -a $(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*-2.0.0.dylib $(BUILD_DIST)/libgdk-pixbuf-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0" ]; then \
		cp -a $(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/gdk-pixbuf-2.0 $(BUILD_DIST)/libgdk-pixbuf-2.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi

	# gdk-pixbuf.mk Prep libgdk-pixbuf-2.0-dev (headers, symlink, .pc, tools)
	cp -a $(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libgdk-pixbuf-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*-2.0.0.dylib|gdk-pixbuf-2.0) $(BUILD_DIST)/libgdk-pixbuf-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/gdk-pixbuf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/libgdk-pixbuf-2.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# gdk-pixbuf.mk Sign
	$(call SIGN,libgdk-pixbuf-2.0-0,general.xml)
	$(call SIGN,libgdk-pixbuf-2.0-dev,general.xml)

	# gdk-pixbuf.mk Make .debs
	$(call PACK,libgdk-pixbuf-2.0-0,DEB_LIBGDKPIXBUF_V)
	$(call PACK,libgdk-pixbuf-2.0-dev,DEB_LIBGDKPIXBUF_V)

	# gdk-pixbuf.mk Build cleanup
	rm -rf $(BUILD_DIST)/libgdk-pixbuf-2.0-0 $(BUILD_DIST)/libgdk-pixbuf-2.0-dev

.PHONY: gdk-pixbuf gdk-pixbuf-package
