ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS    += woff2
WOFF2_VERSION  := 1.0.2
DEB_WOFF2_V    ?= $(WOFF2_VERSION)+ios1

woff2-setup: setup
	$(call GITHUB_ARCHIVE,google,woff2,$(WOFF2_VERSION),v$(WOFF2_VERSION))
	$(call EXTRACT_TAR,woff2-$(WOFF2_VERSION).tar.gz,woff2-$(WOFF2_VERSION),woff2)

ifneq ($(wildcard $(BUILD_WORK)/woff2/.build_complete),)
woff2:
	@echo "Using previously built woff2."
else
woff2: woff2-setup brotli
	cd $(BUILD_WORK)/woff2 && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DCANONICAL_PREFIXES=ON
	+$(MAKE) -C $(BUILD_WORK)/woff2
	+$(MAKE) -C $(BUILD_WORK)/woff2 install \
		DESTDIR="$(BUILD_STAGE)/woff2"
	$(call AFTER_BUILD,copy)
endif

woff2-package: .SHELLFLAGS=-O extglob -c
woff2-package: woff2-stage
	# woff2.mk Package Structure
	rm -rf $(BUILD_DIST)/{woff2,libwoff2-1,libwoff2-dev}
	mkdir -p $(BUILD_DIST)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin \
		$(BUILD_DIST)/libwoff2-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libwoff2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}

	# woff2.mk Prep woff2 (tools)
	-cp -a $(BUILD_STAGE)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/woff2_* $(BUILD_DIST)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin

	# woff2.mk Prep libwoff2-1 (runtime: versioned dylibs)
	cp -a $(BUILD_STAGE)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwoff2@(common|dec|enc).[0-9]*.dylib $(BUILD_DIST)/libwoff2-1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# woff2.mk Prep libwoff2-dev (headers, unversioned symlinks, pkgconfig)
	cp -a $(BUILD_STAGE)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/woff2 $(BUILD_DIST)/libwoff2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwoff2@(common|dec|enc).dylib $(BUILD_DIST)/libwoff2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/woff2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libwoff2*.pc $(BUILD_DIST)/libwoff2-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# woff2.mk Sign
	$(call SIGN,woff2,general.xml)
	$(call SIGN,libwoff2-1,general.xml)

	# woff2.mk Make .debs
	$(call PACK,woff2,DEB_WOFF2_V)
	$(call PACK,libwoff2-1,DEB_WOFF2_V)
	$(call PACK,libwoff2-dev,DEB_WOFF2_V)

	# woff2.mk Build cleanup
	rm -rf $(BUILD_DIST)/{woff2,libwoff2-1,libwoff2-dev}

.PHONY: woff2 woff2-package
