ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libfmt.mk — Ladybird leaf closure. BUMP upstream 7.1.3 -> 12.1.0 (Ladybird pin). Pure CMake +
# headers. Runtime package renamed libfmt7 -> libfmt12 to track the new soname. Dylib names are
# globbed so the recipe is version-agnostic. +ios1 deb marker.

SUBPROJECTS     += libfmt
LIBFMT_VERSION  := 12.1.0
DEB_LIBFMT_V    ?= $(LIBFMT_VERSION)+ios1

libfmt-setup: setup
	$(call GITHUB_ARCHIVE,fmtlib,fmt,$(LIBFMT_VERSION),$(LIBFMT_VERSION),libfmt)
	$(call EXTRACT_TAR,libfmt-$(LIBFMT_VERSION).tar.gz,fmt-$(LIBFMT_VERSION),libfmt)

ifneq ($(wildcard $(BUILD_WORK)/libfmt/.build_complete),)
libfmt:
	@echo "Using previously built libfmt."
else
libfmt: libfmt-setup
	cd $(BUILD_WORK)/libfmt && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DFMT_TEST=OFF \
		-DFMT_DOC=OFF
	+$(MAKE) -C $(BUILD_WORK)/libfmt
	+$(MAKE) -C $(BUILD_WORK)/libfmt install \
		DESTDIR="$(BUILD_STAGE)/libfmt"
	$(call AFTER_BUILD,copy)
endif

libfmt-package: .SHELLFLAGS=-O extglob -c
libfmt-package: libfmt-stage
	# libfmt.mk Package Structure
	rm -rf $(BUILD_DIST)/libfmt{12,-dev}
	mkdir -p $(BUILD_DIST)/libfmt{12,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libfmt.mk Prep libfmt12 (runtime: versioned dylib)
	cp -a $(BUILD_STAGE)/libfmt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfmt.[0-9]*.dylib $(BUILD_DIST)/libfmt12/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libfmt.mk Prep libfmt-dev
	cp -a $(BUILD_STAGE)/libfmt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libfmt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libfmt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libfmt.dylib $(BUILD_DIST)/libfmt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libfmt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libfmt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libfmt/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake $(BUILD_DIST)/libfmt-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libfmt.mk Sign
	$(call SIGN,libfmt12,general.xml)

	# libfmt.mk Make .debs
	$(call PACK,libfmt12,DEB_LIBFMT_V)
	$(call PACK,libfmt-dev,DEB_LIBFMT_V)

	# libfmt.mk Build cleanup
	rm -rf $(BUILD_DIST)/libfmt{12,-dev}

.PHONY: libfmt libfmt-package
