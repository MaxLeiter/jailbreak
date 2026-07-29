ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# MI_INSTALL_TOPLEVEL=ON installs into lib/+include/, not lib/mimalloc-2.2/.
# A10 lacks FEAT_LSE: mimalloc's default -march lowers atomics to LSE instructions, which
# SIGILL at mi_process_init — fixed via MI_OPT_ARCH=OFF + explicit -lse disable (verify
# with llvm-objdump, not plain objdump, which hides LSE ops as `.long`).

SUBPROJECTS        += mimalloc
MIMALLOC_VERSION   := 2.2.7
DEB_MIMALLOC_V     ?= $(MIMALLOC_VERSION)+ios1

mimalloc-setup: setup
	$(call GITHUB_ARCHIVE,microsoft,mimalloc,$(MIMALLOC_VERSION),v$(MIMALLOC_VERSION))
	$(call EXTRACT_TAR,mimalloc-$(MIMALLOC_VERSION).tar.gz,mimalloc-$(MIMALLOC_VERSION),mimalloc)

ifneq ($(wildcard $(BUILD_WORK)/mimalloc/.build_complete),)
mimalloc:
	@echo "Using previously built mimalloc."
else
mimalloc: mimalloc-setup
	cd $(BUILD_WORK)/mimalloc && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DMI_BUILD_TESTS=OFF \
		-DMI_BUILD_OBJECT=OFF \
		-DMI_BUILD_STATIC=ON \
		-DMI_BUILD_SHARED=ON \
		-DMI_INSTALL_TOPLEVEL=ON \
		-DMI_OPT_ARCH=OFF \
		-DMI_OVERRIDE=OFF \
		-DMI_OSX_ZONE=OFF \
		-DMI_OSX_INTERPOSE=OFF \
		-DCMAKE_C_FLAGS="$(CFLAGS) -march=armv8-a -Xclang -target-feature -Xclang -lse" \
		-DCMAKE_CXX_FLAGS="$(CXXFLAGS) -march=armv8-a -Xclang -target-feature -Xclang -lse"
	+$(MAKE) -C $(BUILD_WORK)/mimalloc
	+$(MAKE) -C $(BUILD_WORK)/mimalloc install \
		DESTDIR="$(BUILD_STAGE)/mimalloc"
	$(call AFTER_BUILD,copy)
endif

mimalloc-package: .SHELLFLAGS=-O extglob -c
mimalloc-package: mimalloc-stage
	# mimalloc.mk Package Structure
	rm -rf $(BUILD_DIST)/{libmimalloc,libmimalloc-dev}
	mkdir -p $(BUILD_DIST)/libmimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libmimalloc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib}

	# mimalloc.mk Prep libmimalloc (runtime: versioned dylib)
	cp -a $(BUILD_STAGE)/mimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmimalloc.[0-9]*.dylib $(BUILD_DIST)/libmimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# mimalloc.mk Prep libmimalloc-dev (headers, static, symlink, pkgconfig/cmake)
	cp -a $(BUILD_STAGE)/mimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/* $(BUILD_DIST)/libmimalloc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	-cp -a $(BUILD_STAGE)/mimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmimalloc.dylib $(BUILD_DIST)/libmimalloc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/mimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libmimalloc.a $(BUILD_DIST)/libmimalloc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/mimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libmimalloc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/mimalloc/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake $(BUILD_DIST)/libmimalloc-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# mimalloc.mk Sign
	$(call SIGN,libmimalloc,general.xml)

	# mimalloc.mk Make .debs
	$(call PACK,libmimalloc,DEB_MIMALLOC_V)
	$(call PACK,libmimalloc-dev,DEB_MIMALLOC_V)

	# mimalloc.mk Build cleanup
	rm -rf $(BUILD_DIST)/{libmimalloc,libmimalloc-dev}

.PHONY: mimalloc mimalloc-package
