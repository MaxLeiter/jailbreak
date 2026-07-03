ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libdisplay-info.mk — minimal EDID parser shim for KWin on iOS.
# KWin hard-requires libdisplay-info for monitor metadata. For first-light iOS
# bring-up we only need the ABI to compile/link; the parser returns unsupported
# metadata until a real libdisplay-info port lands.

SUBPROJECTS += libdisplay-info
LIBDISPLAYINFO_VERSION := 0.1.1
DEB_LIBDISPLAYINFO_V   ?= $(LIBDISPLAYINFO_VERSION)+ios1

libdisplay-info-setup: setup
	rm -rf $(BUILD_WORK)/libdisplay-info
	mkdir -p $(BUILD_WORK)/libdisplay-info

ifneq ($(wildcard $(BUILD_WORK)/libdisplay-info/.build_complete),)
libdisplay-info:
	@echo "Using previously built libdisplay-info shim."
else
libdisplay-info: libdisplay-info-setup
	rm -rf $(BUILD_STAGE)/libdisplay-info
	mkdir -p $(BUILD_STAGE)/libdisplay-info$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include/libdisplay-info,lib/pkgconfig}
	cp -v $(BUILD_INFO)/libdisplay-info-info-shim.h $(BUILD_STAGE)/libdisplay-info$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libdisplay-info/info.h
	cp -v $(BUILD_INFO)/libdisplay-info-edid-shim.h $(BUILD_STAGE)/libdisplay-info$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libdisplay-info/edid.h
	cp -v $(BUILD_INFO)/libdisplay-info-cta-shim.h $(BUILD_STAGE)/libdisplay-info$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libdisplay-info/cta.h
	cp -v $(BUILD_INFO)/libdisplay-info-shim.c $(BUILD_WORK)/libdisplay-info/libdisplay_info_stub.c
	$(CC) -dynamiclib -install_name @rpath/libdisplay-info.dylib \
		-current_version $(LIBDISPLAYINFO_VERSION) -compatibility_version 0.1.0 \
		-o $(BUILD_STAGE)/libdisplay-info$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdisplay-info.dylib \
		$(BUILD_WORK)/libdisplay-info/libdisplay_info_stub.c
	printf 'prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libdisplay-info\nDescription: iOS EDID parser shim for KWin bring-up\nVersion: $(LIBDISPLAYINFO_VERSION)\nLibs: -L$${libdir} -ldisplay-info\nCflags: -I$${includedir}\n' \
		> $(BUILD_STAGE)/libdisplay-info$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libdisplay-info.pc
	$(call AFTER_BUILD,copy)
endif

libdisplay-info-package: libdisplay-info-stage
	rm -rf $(BUILD_DIST)/libdisplay-info1 $(BUILD_DIST)/libdisplay-info-dev
	mkdir -p $(BUILD_DIST)/libdisplay-info1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libdisplay-info-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdisplay-info.dylib \
		$(BUILD_DIST)/libdisplay-info1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libdisplay-info-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libdisplay-info/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libdisplay-info-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	$(call SIGN,libdisplay-info1,general.xml)
	$(call PACK,libdisplay-info1,DEB_LIBDISPLAYINFO_V)
	$(call PACK,libdisplay-info-dev,DEB_LIBDISPLAYINFO_V)
	rm -rf $(BUILD_DIST)/libdisplay-info1 $(BUILD_DIST)/libdisplay-info-dev

.PHONY: libdisplay-info libdisplay-info-package
