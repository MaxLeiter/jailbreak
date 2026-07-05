ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS    += pango
PANGO_MAJOR_V  := 1.50
PANGO_VERSION  := $(PANGO_MAJOR_V).14
DEB_LIBPANGO_V ?= $(PANGO_VERSION)+ios1

pango-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ftp.gnome.org/pub/gnome/sources/pango/$(PANGO_MAJOR_V)/pango-$(PANGO_VERSION).tar.xz)
	$(call EXTRACT_TAR,pango-$(PANGO_VERSION).tar.xz,pango-$(PANGO_VERSION),pango)
	# On darwin pango auto-enables its CoreText backend, which pulls the macOS-only
	# ApplicationServices framework (absent from the iOS SDK). Make those framework
	# deps non-required so CoreText stays off and pango uses fontconfig/freetype/cairo.
	$(call DO_PATCH,pango,pango,-p1)
	rm -rf $(BUILD_WORK)/pango/build
	mkdir -p $(BUILD_WORK)/pango/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/pango/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/pango/.build_complete),)
pango:
	@echo "Using previously built pango."
else
pango: pango-setup glib2.0 cairo harfbuzz fribidi fontconfig freetype
	cd $(BUILD_WORK)/pango/build && meson \
		--cross-file cross.txt \
		-Dgtk_doc=false \
		-Dintrospection=disabled \
		-Dinstall-tests=false \
		-Dfontconfig=enabled \
		-Dfreetype=enabled \
		-Dcairo=enabled \
		-Dxft=disabled \
		-Dlibthai=disabled \
		-Dsysprof=disabled \
		..
	cd $(BUILD_WORK)/pango/build; \
		DESTDIR="$(BUILD_STAGE)/pango" meson install
	$(call AFTER_BUILD,copy)
endif

pango-package: pango-stage
	# pango.mk Package Structure
	rm -rf $(BUILD_DIST)/libpango-1.0-0 $(BUILD_DIST)/libpango1.0-dev
	mkdir -p $(BUILD_DIST)/libpango-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpango1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# pango.mk Prep libpango-1.0-0 (runtime dylibs)
	cp -a $(BUILD_STAGE)/pango/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/*-1.0.0.dylib $(BUILD_DIST)/libpango-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# pango.mk Prep libpango1.0-dev (headers, symlinks, .pc, tools)
	cp -a $(BUILD_STAGE)/pango/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libpango1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/pango/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*-1.0.0.dylib) $(BUILD_DIST)/libpango1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/pango/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin" ]; then \
		cp -a $(BUILD_STAGE)/pango/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/libpango1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	# pango.mk Sign
	$(call SIGN,libpango-1.0-0,general.xml)
	$(call SIGN,libpango1.0-dev,general.xml)

	# pango.mk Make .debs
	$(call PACK,libpango-1.0-0,DEB_LIBPANGO_V)
	$(call PACK,libpango1.0-dev,DEB_LIBPANGO_V)

	# pango.mk Build cleanup
	rm -rf $(BUILD_DIST)/libpango-1.0-0 $(BUILD_DIST)/libpango1.0-dev

.PHONY: pango pango-package
