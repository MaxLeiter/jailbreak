ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Only here because AppStream needs it, which libadwaita 1.4 needs.

SUBPROJECTS    += libxmlb
LIBXMLB_VERSION := 0.3.14
DEB_LIBXMLB_V  ?= $(LIBXMLB_VERSION)+ios1

libxmlb-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/hughsie/libxmlb/releases/download/$(LIBXMLB_VERSION)/libxmlb-$(LIBXMLB_VERSION).tar.xz)
	$(call EXTRACT_TAR,libxmlb-$(LIBXMLB_VERSION).tar.xz,libxmlb-$(LIBXMLB_VERSION),libxmlb)
	mkdir -p $(BUILD_WORK)/libxmlb/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libxmlb/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libxmlb/.build_complete),)
libxmlb:
	@echo "Using previously built libxmlb."
else
libxmlb: libxmlb-setup glib2.0
	cd $(BUILD_WORK)/libxmlb/build && meson \
		--cross-file cross.txt \
		-Dintrospection=false \
		-Dgtkdoc=false \
		-Dstemmer=false \
		-Dcli=false \
		-Dtests=false \
		..
	+ninja -C $(BUILD_WORK)/libxmlb/build
	+DESTDIR="$(BUILD_STAGE)/libxmlb" ninja -C $(BUILD_WORK)/libxmlb/build install
	$(call AFTER_BUILD,copy)
endif

libxmlb-package: libxmlb-stage
	rm -rf $(BUILD_DIST)/libxmlb2 $(BUILD_DIST)/libxmlb-dev
	mkdir -p $(BUILD_DIST)/libxmlb2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libxmlb-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxmlb/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxmlb.2.dylib $(BUILD_DIST)/libxmlb2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libxmlb/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libxmlb.2.dylib) $(BUILD_DIST)/libxmlb-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxmlb/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libxmlb-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libxmlb2,general.xml)
	$(call PACK,libxmlb2,DEB_LIBXMLB_V)
	$(call PACK,libxmlb-dev,DEB_LIBXMLB_V)
	rm -rf $(BUILD_DIST)/libxmlb2 $(BUILD_DIST)/libxmlb-dev

.PHONY: libxmlb libxmlb-package
