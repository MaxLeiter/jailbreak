ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libsoup3.mk — HTTP client/server library (libsoup-3.0). Needed by gnome-calculator (currency
# rate fetch) and many GNOME apps. Pure C. nghttp2 + sqlite3 + libxml2 are prebuilt in Procursus;
# libpsl is our recipe. glib-networking (a runtime GIO TLS module) is a RUNTIME-optional dep —
# without it the lib loads but HTTPS fails; the app still launches.
#
# VAPI: built `-Dvapi=false` (vapi gen would need GIR/g-ir-scanner on-target). The Vala apps that
# use libsoup get `libsoup-3.0.vapi` from the vendored vapidir (see linux-build/vapi/README.md).
#
# BUILT/PUBLISHED — libsoup-3.0-0 3.4.4+ios1.

SUBPROJECTS      += libsoup3
LIBSOUP3_MAJOR_V := 3.4
LIBSOUP3_VERSION := $(LIBSOUP3_MAJOR_V).4
DEB_LIBSOUP3_V   ?= $(LIBSOUP3_VERSION)+ios1

libsoup3-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://download.gnome.org/sources/libsoup/$(LIBSOUP3_MAJOR_V)/libsoup-$(LIBSOUP3_VERSION).tar.xz)
	$(call EXTRACT_TAR,libsoup-$(LIBSOUP3_VERSION).tar.xz,libsoup-$(LIBSOUP3_VERSION),libsoup3)
	rm -rf $(BUILD_WORK)/libsoup3/build && mkdir -p $(BUILD_WORK)/libsoup3/build
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
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/libsoup3/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/libsoup3/.build_complete),)
libsoup3:
	@echo "Using previously built libsoup3."
else
libsoup3: libsoup3-setup glib2.0 libpsl libxml2 nghttp2 sqlite3 brotli
	cd $(BUILD_WORK)/libsoup3/build && meson \
		--cross-file cross.txt \
		-Dintrospection=disabled \
		-Dvapi=disabled \
		-Dtests=false \
		-Ddocs=disabled \
		-Dsysprof=disabled \
		-Dtls_check=false \
		-Dbrotli=enabled \
		-Dntlm=disabled \
		-Dgssapi=disabled \
		..
	+ninja -C $(BUILD_WORK)/libsoup3/build
	+DESTDIR="$(BUILD_STAGE)/libsoup3" ninja -C $(BUILD_WORK)/libsoup3/build install
	$(call AFTER_BUILD,copy)
endif

libsoup3-package: libsoup3-stage
	rm -rf $(BUILD_DIST)/libsoup-3.0-0 $(BUILD_DIST)/libsoup-3.0-dev
	mkdir -p $(BUILD_DIST)/libsoup-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsoup-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libsoup3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsoup-3.0.0.dylib $(BUILD_DIST)/libsoup-3.0-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libsoup3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libsoup-3.0.0.dylib) $(BUILD_DIST)/libsoup-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libsoup3/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libsoup-3.0-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libsoup-3.0-0,general.xml)
	$(call PACK,libsoup-3.0-0,DEB_LIBSOUP3_V)
	$(call PACK,libsoup-3.0-dev,DEB_LIBSOUP3_V)
	rm -rf $(BUILD_DIST)/libsoup-3.0-0 $(BUILD_DIST)/libsoup-3.0-dev

.PHONY: libsoup3 libsoup3-package
