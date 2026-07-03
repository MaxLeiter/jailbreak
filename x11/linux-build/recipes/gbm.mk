ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# gbm.mk — links-only GBM shim for KWin first-light on iOS.
# KWin's nested Wayland backend still compiles its GBM/DRM allocator path. iOS has no
# Mesa GBM device, so this package supplies the small public ABI surface needed to
# configure, compile, and link. All allocation/device entry points return failure.

SUBPROJECTS += gbm
GBM_VERSION := 21.0.0
DEB_GBM_V   ?= $(GBM_VERSION)+ios1

gbm-setup: setup
	rm -rf $(BUILD_WORK)/gbm
	mkdir -p $(BUILD_WORK)/gbm

ifneq ($(wildcard $(BUILD_WORK)/gbm/.build_complete),)
gbm:
	@echo "Using previously built gbm shim."
else
gbm: gbm-setup
	rm -rf $(BUILD_STAGE)/gbm
	mkdir -p $(BUILD_STAGE)/gbm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig}
	cp -v $(BUILD_INFO)/gbm-shim.h $(BUILD_STAGE)/gbm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/gbm.h
	cp -v $(BUILD_INFO)/gbm-shim.c $(BUILD_WORK)/gbm/gbm_stub.c
	$(CC) -dynamiclib -install_name @rpath/libgbm.dylib \
		-current_version $(GBM_VERSION) -compatibility_version 1.0.0 \
		-o $(BUILD_STAGE)/gbm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgbm.dylib \
		$(BUILD_WORK)/gbm/gbm_stub.c
	printf 'prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: gbm\nDescription: iOS links-only GBM shim for KWin bring-up\nVersion: $(GBM_VERSION)\nLibs: -L$${libdir} -lgbm\nCflags: -I$${includedir}\n' \
		> $(BUILD_STAGE)/gbm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/gbm.pc
	$(call AFTER_BUILD,copy)
endif

gbm-package: gbm-stage
	rm -rf $(BUILD_DIST)/libgbm1 $(BUILD_DIST)/libgbm-dev
	mkdir -p $(BUILD_DIST)/libgbm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libgbm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gbm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libgbm.dylib \
		$(BUILD_DIST)/libgbm1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/gbm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libgbm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/gbm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libgbm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	$(call SIGN,libgbm1,general.xml)
	$(call PACK,libgbm1,DEB_GBM_V)
	$(call PACK,libgbm-dev,DEB_GBM_V)
	rm -rf $(BUILD_DIST)/libgbm1 $(BUILD_DIST)/libgbm-dev

.PHONY: gbm gbm-package
