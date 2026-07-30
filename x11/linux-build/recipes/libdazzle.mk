ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# GTK3 utility widgets used by GNOME Web 43.

SUBPROJECTS        += libdazzle
LIBDAZZLE_MAJOR_V  := 3.44
LIBDAZZLE_VERSION  := $(LIBDAZZLE_MAJOR_V).0
DEB_LIBDAZZLE_V    ?= $(LIBDAZZLE_VERSION)+ios1

libdazzle-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libdazzle/$(LIBDAZZLE_MAJOR_V)/libdazzle-$(LIBDAZZLE_VERSION).tar.xz)
	$(call EXTRACT_TAR,libdazzle-$(LIBDAZZLE_VERSION).tar.xz,libdazzle-$(LIBDAZZLE_VERSION),libdazzle)
	$(call DO_PATCH,libdazzle,libdazzle,-p1)
	rm -rf $(BUILD_WORK)/libdazzle/build
	mkdir -p $(BUILD_WORK)/libdazzle/build
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
	c_link_args = ['-lobjc']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libdazzle/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libdazzle/.build_complete),)
libdazzle:
	@echo "Using previously built libdazzle."
else
libdazzle: libdazzle-setup gtk+3.0
	cd $(BUILD_WORK)/libdazzle/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dwith_introspection=false \
		-Dwith_vapi=false \
		-Denable_tools=false \
		-Denable_gtk_doc=false \
		-Denable_tests=false \
		..
	+ninja -C $(BUILD_WORK)/libdazzle/build
	+DESTDIR="$(BUILD_STAGE)/libdazzle" ninja -C $(BUILD_WORK)/libdazzle/build install
	$(call AFTER_BUILD,copy)
endif

libdazzle-package: libdazzle-stage
	rm -rf $(BUILD_DIST)/libdazzle-1.0-0 $(BUILD_DIST)/libdazzle-1.0-dev
	mkdir -p $(BUILD_DIST)/libdazzle-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libdazzle-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libdazzle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdazzle-1.0.0.dylib \
		$(BUILD_DIST)/libdazzle-1.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdazzle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libdazzle-1.0.0.dylib) \
		$(BUILD_DIST)/libdazzle-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdazzle/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libdazzle-1.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libdazzle-1.0-0,general.xml)
	$(call PACK,libdazzle-1.0-0,DEB_LIBDAZZLE_V)
	$(call PACK,libdazzle-1.0-dev,DEB_LIBDAZZLE_V)
	rm -rf $(BUILD_DIST)/libdazzle-1.0-0 $(BUILD_DIST)/libdazzle-1.0-dev

.PHONY: libdazzle libdazzle-package
