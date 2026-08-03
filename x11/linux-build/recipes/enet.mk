ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS    += enet
ENET_VERSION    := 1.3.18
DEB_ENET_V     ?= $(ENET_VERSION)+ios1

enet-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/lsalzman/enet/archive/refs/tags/v$(ENET_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(ENET_VERSION).tar.gz,enet-$(ENET_VERSION),enet)
	# ENet 1.3.18 hardcodes STATIC, so BUILD_SHARED_LIBS never reaches the
	# target and packaging finds no dylib. Take the library kind from the
	# cache variable instead and carry the libtool 7:4:0 soname that the
	# libenet7 package name already assumes.
	sed -E -i 's|^add_library\(enet STATIC$$|add_library(enet|' \
		$(BUILD_WORK)/enet/CMakeLists.txt
	grep -q 'set_target_properties(enet PROPERTIES' $(BUILD_WORK)/enet/CMakeLists.txt || \
		sed -E -i 's|^install\(TARGETS enet$$|set_target_properties(enet PROPERTIES VERSION 7.0.0 SOVERSION 7)\n\ninstall(TARGETS enet|' \
			$(BUILD_WORK)/enet/CMakeLists.txt
	grep -q '^add_library(enet$$' $(BUILD_WORK)/enet/CMakeLists.txt
	grep -q 'SOVERSION 7' $(BUILD_WORK)/enet/CMakeLists.txt
	rm -rf $(BUILD_WORK)/enet/build
	mkdir -p $(BUILD_WORK)/enet/build

ifneq ($(wildcard $(BUILD_WORK)/enet/.build_complete),)
enet:
	@echo "Using previously built ENet."
else
enet: enet-setup
	cd $(BUILD_WORK)/enet/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DBUILD_SHARED_LIBS=ON \
		-DENET_BUILD_TESTS=OFF
	+ninja -C $(BUILD_WORK)/enet/build
	+DESTDIR="$(BUILD_STAGE)/enet" ninja -C $(BUILD_WORK)/enet/build install
	$(call AFTER_BUILD,copy)
endif

enet-package: enet-stage
	rm -rf $(BUILD_DIST)/libenet7 $(BUILD_DIST)/libenet-dev
	mkdir -p \
		$(BUILD_DIST)/libenet7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libenet-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/enet/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libenet.*.dylib \
		$(BUILD_DIST)/libenet7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/enet/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libenet-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	mkdir -p $(BUILD_DIST)/libenet-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/enet/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libenet.dylib \
		$(BUILD_DIST)/libenet-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	if [ -d "$(BUILD_STAGE)/enet/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig" ]; then \
		cp -a $(BUILD_STAGE)/enet/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
			$(BUILD_DIST)/libenet-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/; \
	fi
	$(call SIGN,libenet7,general.xml)
	$(call PACK,libenet7,DEB_ENET_V)
	$(call PACK,libenet-dev,DEB_ENET_V)
	rm -rf $(BUILD_DIST)/libenet7 $(BUILD_DIST)/libenet-dev

.PHONY: enet enet-package
