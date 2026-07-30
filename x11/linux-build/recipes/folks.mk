ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Geary uses Folks for its contact aggregator. The first iOS package keeps the
# core and dummy backends while disabling Linux service integrations (EDS,
# BlueZ, oFono and Telepathy). The library itself is Vala and therefore emits
# its C sources, VAPI and GIR without executing target code.

SUBPROJECTS   += folks
FOLKS_VERSION := 0.15.9
DEB_FOLKS_V   ?= $(FOLKS_VERSION)+ios1

folks-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/folks/0.15/folks-$(FOLKS_VERSION).tar.xz)
	$(call EXTRACT_TAR,folks-$(FOLKS_VERSION).tar.xz,folks-$(FOLKS_VERSION),folks)
	$(call DO_PATCH,folks,folks,-p1)
	rm -rf $(BUILD_WORK)/folks/build && mkdir -p $(BUILD_WORK)/folks/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/folks/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/folks/.build_complete),)
folks:
	@echo "Using previously built Folks."
else
folks: folks-setup libgee glib2.0
	cd $(BUILD_WORK)/folks/build && meson \
		--cross-file cross.txt \
		--buildtype=release \
		-Dbluez_backend=false \
		-Deds_backend=false \
		-Dofono_backend=false \
		-Dtelepathy_backend=false \
		-Dimport_tool=false \
		-Dinspect_tool=false \
		-Dtests=false \
		-Dinstalled_tests=false \
		-Ddocs=false \
		..
	cp $(BUILD_WORK)/libgee/gee/Gee-0.8.gir \
		/usr/share/gir-1.0/Gee-0.8.gir
	+ninja -C $(BUILD_WORK)/folks/build
	+DESTDIR="$(BUILD_STAGE)/folks" ninja -C $(BUILD_WORK)/folks/build install
	$(call AFTER_BUILD,copy)
endif

folks-package: folks-stage
	rm -rf $(BUILD_DIST)/libfolks26 $(BUILD_DIST)/libfolks-dev
	mkdir -p \
		$(BUILD_DIST)/libfolks26/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libfolks26/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share \
		$(BUILD_DIST)/libfolks-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libfolks-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share
	cp -a $(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfolks.26.dylib \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfolks-dummy.26.dylib \
		$(BUILD_DIST)/libfolks26/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/folks \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/girepository-1.0 \
		$(BUILD_DIST)/libfolks26/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/GConf \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/glib-2.0 \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale \
		$(BUILD_DIST)/libfolks26/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/
	cp -a $(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libfolks-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	cp -a $(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfolks.dylib \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfolks-dummy.dylib \
		$(BUILD_DIST)/libfolks-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/gir-1.0 \
		$(BUILD_STAGE)/folks/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/vala \
		$(BUILD_DIST)/libfolks-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/
	$(call SIGN,libfolks26)
	$(call PACK,libfolks26,DEB_FOLKS_V)
	$(call PACK,libfolks-dev,DEB_FOLKS_V)
	rm -rf $(BUILD_DIST)/libfolks26 $(BUILD_DIST)/libfolks-dev

.PHONY: folks folks-package
