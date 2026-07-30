ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Header-only functional-programming dependencies and libunibreak used by
# Krita 6's text/vector stack. Keep these as independent packages: Immer, Zug,
# Lager, and Eigen are useful to other C++ ports and should not be hidden in a
# Krita-only sysroot bootstrap.

SUBPROJECTS += krita-support

EIGEN3_VERSION := 5.0.1
BOOST_HEADERS_VERSION := 1.90.0
BOOST_HEADERS_UNDERSCORE := 1_90_0
XSIMD_VERSION := 14.1.0
IMMER_VERSION := 0.9.1
ZUG_VERSION := 0.1.2
LAGER_VERSION := 0.1.1+git20230423.0b6ab3e
LAGER_COMMIT := 0b6ab3e0e880bc36be5da4984d768fde03b7cf19
LIBUNIBREAK_VERSION := 7.0

DEB_EIGEN3_V ?= $(EIGEN3_VERSION)+ios1
DEB_BOOST_HEADERS_V ?= $(BOOST_HEADERS_VERSION)+ios1
DEB_XSIMD_V ?= $(XSIMD_VERSION)+ios1
DEB_IMMER_V ?= $(IMMER_VERSION)+ios1
DEB_ZUG_V ?= $(ZUG_VERSION)+ios1
DEB_LAGER_V ?= $(LAGER_VERSION)+ios1
DEB_LIBUNIBREAK_V ?= $(LIBUNIBREAK_VERSION)+ios1

krita-support-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://gitlab.com/libeigen/eigen/-/archive/$(EIGEN3_VERSION)/eigen-$(EIGEN3_VERSION).tar.gz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://archives.boost.io/release/$(BOOST_HEADERS_VERSION)/source/boost_$(BOOST_HEADERS_UNDERSCORE).tar.bz2)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/xtensor-stack/xsimd/archive/refs/tags/$(XSIMD_VERSION).tar.gz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/arximboldi/immer/archive/refs/tags/v$(IMMER_VERSION).tar.gz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/arximboldi/zug/archive/refs/tags/v$(ZUG_VERSION).tar.gz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/dimula73/lager/archive/$(LAGER_COMMIT).tar.gz)
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/adah1972/libunibreak/releases/download/libunibreak_7_0/libunibreak-$(LIBUNIBREAK_VERSION).tar.gz)
	$(call EXTRACT_TAR,eigen-$(EIGEN3_VERSION).tar.gz,eigen-$(EIGEN3_VERSION),krita-eigen3)
	$(call EXTRACT_TAR,boost_$(BOOST_HEADERS_UNDERSCORE).tar.bz2,boost_$(BOOST_HEADERS_UNDERSCORE),krita-boost-headers)
	$(call EXTRACT_TAR,$(XSIMD_VERSION).tar.gz,xsimd-$(XSIMD_VERSION),krita-xsimd)
	$(call EXTRACT_TAR,v$(IMMER_VERSION).tar.gz,immer-$(IMMER_VERSION),krita-immer)
	$(call EXTRACT_TAR,v$(ZUG_VERSION).tar.gz,zug-$(ZUG_VERSION),krita-zug)
	$(call EXTRACT_TAR,$(LAGER_COMMIT).tar.gz,lager-$(LAGER_COMMIT),krita-lager)
	$(call EXTRACT_TAR,libunibreak-$(LIBUNIBREAK_VERSION).tar.gz,libunibreak-$(LIBUNIBREAK_VERSION),krita-libunibreak)
	$(call DO_PATCH,krita-lager,krita-lager,-p1)

ifneq ($(wildcard $(BUILD_WORK)/krita-support/.build_complete),)
krita-support:
	@echo "Using previously built Krita support libraries."
else
krita-support: krita-support-setup
	rm -rf $(BUILD_STAGE)/krita-support
	for project in krita-eigen3 krita-xsimd krita-immer krita-zug krita-lager; do \
		rm -rf "$(BUILD_WORK)/$$project/build"; \
		mkdir -p "$(BUILD_WORK)/$$project/build"; \
	done
	cd $(BUILD_WORK)/krita-eigen3/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_TESTING=OFF \
		-DEIGEN_BUILD_BLAS=OFF \
		-DEIGEN_BUILD_LAPACK=OFF
	+DESTDIR="$(BUILD_STAGE)/krita-support" ninja -C $(BUILD_WORK)/krita-eigen3/build install
	mkdir -p $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_WORK)/krita-boost-headers/boost \
		$(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	cd $(BUILD_WORK)/krita-xsimd/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_TESTS=OFF \
		-DBUILD_BENCHMARKS=OFF
	+DESTDIR="$(BUILD_STAGE)/krita-support" ninja -C $(BUILD_WORK)/krita-xsimd/build install
	cd $(BUILD_WORK)/krita-immer/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-Dimmer_BUILD_TESTS=OFF \
		-Dimmer_BUILD_EXAMPLES=OFF
	+DESTDIR="$(BUILD_STAGE)/krita-support" ninja -C $(BUILD_WORK)/krita-immer/build install
	cd $(BUILD_WORK)/krita-zug/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-Dzug_BUILD_TESTS=OFF \
		-Dzug_BUILD_EXAMPLES=OFF
	+DESTDIR="$(BUILD_STAGE)/krita-support" ninja -C $(BUILD_WORK)/krita-zug/build install
	cd $(BUILD_WORK)/krita-lager/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_PREFIX_PATH="$(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)" \
		-Dlager_BUILD_DEBUGGER_EXAMPLES=OFF \
		-Dlager_BUILD_TESTS=OFF \
		-Dlager_BUILD_EXAMPLES=OFF \
		-Dlager_BUILD_DOCS=OFF
	+DESTDIR="$(BUILD_STAGE)/krita-support" ninja -C $(BUILD_WORK)/krita-lager/build install
	cd $(BUILD_WORK)/krita-libunibreak && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-static \
		--disable-docs
	+$(MAKE) -C $(BUILD_WORK)/krita-libunibreak
	+$(MAKE) -C $(BUILD_WORK)/krita-libunibreak install DESTDIR=$(BUILD_STAGE)/krita-support
	mkdir -p $(BUILD_WORK)/krita-support
	$(call AFTER_BUILD,copy)
endif

krita-support-package: krita-support-stage
	rm -rf $(BUILD_DIST)/eigen3-dev $(BUILD_DIST)/libboost1.90-dev \
		$(BUILD_DIST)/libxsimd-dev $(BUILD_DIST)/libimmer-dev \
		$(BUILD_DIST)/libzug-dev $(BUILD_DIST)/liblager-dev \
		$(BUILD_DIST)/libunibreak7 $(BUILD_DIST)/libunibreak-dev
	mkdir -p \
		$(BUILD_DIST)/eigen3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libboost1.90-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libimmer-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libzug-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/liblager-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		$(BUILD_DIST)/libunibreak7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libunibreak-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	mkdir -p $(BUILD_DIST)/eigen3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/eigen3 \
		$(BUILD_DIST)/eigen3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	mkdir -p $(BUILD_DIST)/eigen3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/eigen3 \
		$(BUILD_DIST)/eigen3-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/
	mkdir -p $(BUILD_DIST)/libboost1.90-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/boost \
		$(BUILD_DIST)/libboost1.90-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	mkdir -p $(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/cmake \
		$(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/pkgconfig
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/xsimd \
		$(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/cmake/xsimd \
		$(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/cmake/
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/pkgconfig/xsimd.pc \
		$(BUILD_DIST)/libxsimd-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/pkgconfig/
	for mapping in "immer Immer" "zug Zug" "lager Lager"; do \
		set -- $$mapping; package="$$1"; cmake_package="$$2"; \
		mkdir -p "$(BUILD_DIST)/lib$$package-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include" \
			"$(BUILD_DIST)/lib$$package-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake"; \
		cp -a "$(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/$$package" \
			"$(BUILD_DIST)/lib$$package-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/"; \
		cp -a "$(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake/$$cmake_package" \
			"$(BUILD_DIST)/lib$$package-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake/"; \
	done
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libunibreak.*.dylib \
		$(BUILD_DIST)/libunibreak7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	mkdir -p $(BUILD_DIST)/libunibreak-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/unibreak* \
		$(BUILD_DIST)/libunibreak-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/ 2>/dev/null || \
		cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
			$(BUILD_DIST)/libunibreak-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libunibreak.dylib \
		$(BUILD_DIST)/libunibreak-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/krita-support/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libunibreak-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	$(call SIGN,libunibreak7,general.xml)
	$(call PACK,eigen3-dev,DEB_EIGEN3_V)
	$(call PACK,libboost1.90-dev,DEB_BOOST_HEADERS_V)
	$(call PACK,libxsimd-dev,DEB_XSIMD_V)
	$(call PACK,libimmer-dev,DEB_IMMER_V)
	$(call PACK,libzug-dev,DEB_ZUG_V)
	$(call PACK,liblager-dev,DEB_LAGER_V)
	$(call PACK,libunibreak7,DEB_LIBUNIBREAK_V)
	$(call PACK,libunibreak-dev,DEB_LIBUNIBREAK_V)
	rm -rf $(BUILD_DIST)/eigen3-dev $(BUILD_DIST)/libboost1.90-dev \
		$(BUILD_DIST)/libxsimd-dev $(BUILD_DIST)/libimmer-dev \
		$(BUILD_DIST)/libzug-dev $(BUILD_DIST)/liblager-dev \
		$(BUILD_DIST)/libunibreak7 $(BUILD_DIST)/libunibreak-dev

.PHONY: krita-support krita-support-package
