ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# simdjson.mk — NEW recipe for the Ladybird leaf closure (pin simdjson 4.2.4). Single-file
# amalgamation, CMake. Developer mode off (no tests). Ships libsimdjson dylib. +ios1 marker.

SUBPROJECTS       += simdjson
SIMDJSON_VERSION  := 4.2.4
DEB_SIMDJSON_V    ?= $(SIMDJSON_VERSION)+ios1

simdjson-setup: setup
	$(call GITHUB_ARCHIVE,simdjson,simdjson,$(SIMDJSON_VERSION),v$(SIMDJSON_VERSION))
	$(call EXTRACT_TAR,simdjson-$(SIMDJSON_VERSION).tar.gz,simdjson-$(SIMDJSON_VERSION),simdjson)

ifneq ($(wildcard $(BUILD_WORK)/simdjson/.build_complete),)
simdjson:
	@echo "Using previously built simdjson."
else
simdjson: simdjson-setup
	cd $(BUILD_WORK)/simdjson && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DSIMDJSON_DEVELOPER_MODE=OFF \
		-DSIMDJSON_ENABLE_THREADS=ON
	+$(MAKE) -C $(BUILD_WORK)/simdjson
	+$(MAKE) -C $(BUILD_WORK)/simdjson install \
		DESTDIR="$(BUILD_STAGE)/simdjson"
	$(call AFTER_BUILD,copy)
endif

simdjson-package: .SHELLFLAGS=-O extglob -c
simdjson-package: simdjson-stage
	# simdjson.mk Package Structure
	rm -rf $(BUILD_DIST)/{libsimdjson,libsimdjson-dev}
	mkdir -p $(BUILD_DIST)/libsimdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsimdjson-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}

	# simdjson.mk Prep libsimdjson (runtime: versioned dylib)
	cp -a $(BUILD_STAGE)/simdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsimdjson.[0-9]*.dylib $(BUILD_DIST)/libsimdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# simdjson.mk Prep libsimdjson-dev
	cp -a $(BUILD_STAGE)/simdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/* $(BUILD_DIST)/libsimdjson-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/simdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsimdjson.dylib $(BUILD_DIST)/libsimdjson-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	-cp -a $(BUILD_STAGE)/simdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/* $(BUILD_DIST)/libsimdjson-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	-cp -a $(BUILD_STAGE)/simdjson/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/cmake $(BUILD_DIST)/libsimdjson-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# simdjson.mk Sign
	$(call SIGN,libsimdjson,general.xml)

	# simdjson.mk Make .debs
	$(call PACK,libsimdjson,DEB_SIMDJSON_V)
	$(call PACK,libsimdjson-dev,DEB_SIMDJSON_V)

	# simdjson.mk Build cleanup
	rm -rf $(BUILD_DIST)/{libsimdjson,libsimdjson-dev}

.PHONY: simdjson simdjson-package
