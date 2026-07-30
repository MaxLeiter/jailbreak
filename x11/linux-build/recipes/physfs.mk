ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS      += physfs
PHYSFS_VERSION   := 3.2.0
DEB_PHYSFS_V     ?= $(PHYSFS_VERSION)+ios1

physfs-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/icculus/physfs/archive/refs/tags/release-$(PHYSFS_VERSION).tar.gz)
	$(call EXTRACT_TAR,release-$(PHYSFS_VERSION).tar.gz,physfs-release-$(PHYSFS_VERSION),physfs)
	rm -rf $(BUILD_WORK)/physfs/build
	mkdir -p $(BUILD_WORK)/physfs/build

ifneq ($(wildcard $(BUILD_WORK)/physfs/.build_complete),)
physfs:
	@echo "Using previously built PhysicsFS."
else
physfs: physfs-setup
	cd $(BUILD_WORK)/physfs/build && cmake .. -G Ninja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		-DPHYSFS_BUILD_SHARED=ON \
		-DPHYSFS_BUILD_STATIC=OFF \
		-DPHYSFS_BUILD_TEST=OFF \
		-DPHYSFS_BUILD_DOCS=OFF
	+ninja -C $(BUILD_WORK)/physfs/build
	+DESTDIR="$(BUILD_STAGE)/physfs" ninja -C $(BUILD_WORK)/physfs/build install
	$(call AFTER_BUILD,copy)
endif

physfs-package: physfs-stage
	rm -rf $(BUILD_DIST)/libphysfs1 $(BUILD_DIST)/libphysfs-dev
	mkdir -p \
		$(BUILD_DIST)/libphysfs1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libphysfs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/physfs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libphysfs*.dylib \
		$(BUILD_DIST)/libphysfs1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/
	cp -a $(BUILD_STAGE)/physfs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libphysfs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/
	for directory in cmake pkgconfig; do \
		if [ -d "$(BUILD_STAGE)/physfs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" ]; then \
			cp -a "$(BUILD_STAGE)/physfs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/$$directory" \
				"$(BUILD_DIST)/libphysfs-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/"; \
		fi; \
	done
	$(call SIGN,libphysfs1,general.xml)
	$(call PACK,libphysfs1,DEB_PHYSFS_V)
	$(call PACK,libphysfs-dev,DEB_PHYSFS_V)
	rm -rf $(BUILD_DIST)/libphysfs1 $(BUILD_DIST)/libphysfs-dev

.PHONY: physfs physfs-package
