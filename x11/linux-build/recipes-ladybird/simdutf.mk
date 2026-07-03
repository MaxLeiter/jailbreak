ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# simdutf.mk — NEW recipe for the Ladybird leaf closure (pin simdutf 7.4.0). Single-header-ish
# SIMD unicode lib, CMake. Tests/tools/benchmarks/iconv off. Ships libsimdutf dylib (library
# soversion tracks its own ABI counter, not the release tag). +ios1 marker.

SUBPROJECTS      += simdutf
SIMDUTF_VERSION  := 7.4.0
DEB_SIMDUTF_V    ?= $(SIMDUTF_VERSION)+ios1

simdutf-setup: setup
	$(call GITHUB_ARCHIVE,simdutf,simdutf,$(SIMDUTF_VERSION),v$(SIMDUTF_VERSION))
	$(call EXTRACT_TAR,simdutf-$(SIMDUTF_VERSION).tar.gz,simdutf-$(SIMDUTF_VERSION),simdutf)

ifneq ($(wildcard $(BUILD_WORK)/simdutf/.build_complete),)
simdutf:
	@echo "Using previously built simdutf."
else
simdutf: simdutf-setup
	cd $(BUILD_WORK)/simdutf && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DSIMDUTF_TESTS=OFF \
		-DSIMDUTF_TOOLS=OFF \
		-DSIMDUTF_BENCHMARKS=OFF \
		-DSIMDUTF_ICONV=OFF
	+$(MAKE) -C $(BUILD_WORK)/simdutf
	+$(MAKE) -C $(BUILD_WORK)/simdutf install \
		DESTDIR="$(BUILD_STAGE)/simdutf"
	$(call AFTER_BUILD,copy)
endif

simdutf-package: .SHELLFLAGS=-O extglob -c
simdutf-package: simdutf-stage
	# simdutf.mk Package Structure
	rm -rf $(BUILD_DIST)/{libsimdutf,libsimdutf-dev}
	mkdir -p $(BUILD_DIST)/libsimdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsimdutf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}

	# simdutf.mk Prep libsimdutf (runtime: versioned dylib)
	cp -a $(BUILD_STAGE)/simdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsimdutf.[0-9]*.dylib $(BUILD_DIST)/libsimdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# simdutf.mk Prep libsimdutf-dev
	cp -a $(BUILD_STAGE)/simdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/* $(BUILD_DIST)/libsimdutf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/simdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsimdutf.dylib $(BUILD_DIST)/libsimdutf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/simdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/* $(BUILD_DIST)/libsimdutf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	-cp -a $(BUILD_STAGE)/simdutf/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake $(BUILD_DIST)/libsimdutf-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# simdutf.mk Sign
	$(call SIGN,libsimdutf,general.xml)

	# simdutf.mk Make .debs
	$(call PACK,libsimdutf,DEB_SIMDUTF_V)
	$(call PACK,libsimdutf-dev,DEB_SIMDUTF_V)

	# simdutf.mk Build cleanup
	rm -rf $(BUILD_DIST)/{libsimdutf,libsimdutf-dev}

.PHONY: simdutf simdutf-package
