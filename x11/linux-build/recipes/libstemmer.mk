ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libstemmer.mk — Snowball stemming library. Geary 46 vendors libstemmer.vapi, so this
# recipe only needs to provide the C library/header/pkg-config surface.

SUBPROJECTS        += libstemmer
LIBSTEMMER_VERSION := 2.2.0
DEB_LIBSTEMMER_V   ?= $(LIBSTEMMER_VERSION)+ios1

libstemmer-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://snowballstem.org/dist/libstemmer_c-$(LIBSTEMMER_VERSION).tar.gz)
	$(call EXTRACT_TAR,libstemmer_c-$(LIBSTEMMER_VERSION).tar.gz,libstemmer_c-$(LIBSTEMMER_VERSION),libstemmer)

ifneq ($(wildcard $(BUILD_WORK)/libstemmer/.build_complete),)
libstemmer:
	@echo "Using previously built libstemmer."
else
libstemmer: libstemmer-setup
	+$(MAKE) -C $(BUILD_WORK)/libstemmer libstemmer.a CC="$(CC)" AR="$(AR)" CFLAGS="-O2 -fPIC"
	mkdir -p $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}
	$(CC) -dynamiclib -install_name @rpath/libstemmer.0.dylib \
		-compatibility_version 1.0.0 -current_version $(LIBSTEMMER_VERSION) \
		-o $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libstemmer.0.dylib \
		$$(find $(BUILD_WORK)/libstemmer/src_c $(BUILD_WORK)/libstemmer/runtime $(BUILD_WORK)/libstemmer/libstemmer -name '*.o' -print)
	ln -sf libstemmer.0.dylib $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libstemmer.dylib
	cp -a $(BUILD_WORK)/libstemmer/libstemmer.a $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_WORK)/libstemmer/include/libstemmer.h $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	printf 'prefix=%s\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libstemmer\nDescription: Snowball stemming library\nVersion: %s\nLibs: -L$${libdir} -lstemmer\nCflags: -I$${includedir}\n' \
		"$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" "$(LIBSTEMMER_VERSION)" \
		> $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libstemmer.pc
	$(call AFTER_BUILD,copy)
endif

libstemmer-package: libstemmer-stage
	rm -rf $(BUILD_DIST)/libstemmer0d $(BUILD_DIST)/libstemmer-dev
	mkdir -p $(BUILD_DIST)/libstemmer0d/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libstemmer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libstemmer.0.dylib \
		$(BUILD_DIST)/libstemmer0d/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(libstemmer.0.dylib) \
		$(BUILD_DIST)/libstemmer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libstemmer/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libstemmer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	$(call SIGN,libstemmer0d,general.xml)
	$(call PACK,libstemmer0d,DEB_LIBSTEMMER_V)
	$(call PACK,libstemmer-dev,DEB_LIBSTEMMER_V)
	rm -rf $(BUILD_DIST)/libstemmer0d $(BUILD_DIST)/libstemmer-dev

.PHONY: libstemmer libstemmer-package
