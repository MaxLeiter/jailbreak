ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libpeas.mk — libpeas 1.x plugin engine for the Geary 46 lane. Build the core C loader
# only: no Python/Lua loaders, no GTK widgetry, no demos/docs, no generated GIR/VAPI.
# Upstream 1.x still links libgirepository into the core library, so this depends on the
# existing gobject-introspection target/package set.

SUBPROJECTS     += libpeas
LIBPEAS_MAJOR_V := 1.36
LIBPEAS_VERSION := $(LIBPEAS_MAJOR_V).0
DEB_LIBPEAS_V   ?= $(LIBPEAS_VERSION)+ios1

libpeas-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libpeas/$(LIBPEAS_MAJOR_V)/libpeas-$(LIBPEAS_VERSION).tar.xz)
	$(call EXTRACT_TAR,libpeas-$(LIBPEAS_VERSION).tar.xz,libpeas-$(LIBPEAS_VERSION),libpeas)
	rm -rf $(BUILD_WORK)/libpeas/build && mkdir -p $(BUILD_WORK)/libpeas/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libpeas/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libpeas/.build_complete),)
libpeas:
	@echo "Using previously built libpeas."
else
libpeas: libpeas-setup glib2.0 gobject-introspection
	cd $(BUILD_WORK)/libpeas/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dvapi=false \
		-Dlua51=false \
		-Dpython2=false \
		-Dpython3=false \
		-Dwidgetry=false \
		-Dglade_catalog=false \
		-Ddemos=false \
		-Dgtk_doc=false \
		..
	+ninja -C $(BUILD_WORK)/libpeas/build
	+DESTDIR="$(BUILD_STAGE)/libpeas" ninja -C $(BUILD_WORK)/libpeas/build install
	$(call AFTER_BUILD,copy)
endif

libpeas-package: libpeas-stage
	rm -rf $(BUILD_DIST)/libpeas-1.0-0 $(BUILD_DIST)/libpeas-1.0-dev
	mkdir -p $(BUILD_DIST)/libpeas-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpeas-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpeas-1.0.*.dylib \
		$(BUILD_DIST)/libpeas-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpeas-1.0" ]; then \
		cp -a $(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpeas-1.0 \
			$(BUILD_DIST)/libpeas-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/libpeas-1.0" ]; then \
		mkdir -p $(BUILD_DIST)/libpeas-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/libpeas-1.0 \
			$(BUILD_DIST)/libpeas-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	cp -a $(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libpeas-1.0.*.dylib|libpeas-1.0) \
		$(BUILD_DIST)/libpeas-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libpeas/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libpeas-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libpeas-1.0-0,general.xml)
	$(call PACK,libpeas-1.0-0,DEB_LIBPEAS_V)
	$(call PACK,libpeas-1.0-dev,DEB_LIBPEAS_V)
	rm -rf $(BUILD_DIST)/libpeas-1.0-0 $(BUILD_DIST)/libpeas-1.0-dev

.PHONY: libpeas libpeas-package
