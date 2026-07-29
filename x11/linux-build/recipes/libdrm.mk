ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Links-only shim: libdrm has no iOS equivalent (no DRM device), but Mutter's Wayland
# backend links it for the dmabuf buffer path. Ships libdrm's real portable headers
# (drm_fourcc.h/drm.h/xf86drm*.h) plus no-op stubs of the referenced drm* symbols so
# libmutter/cogl/clutter link for typelib generation.
# dmabuf itself is inert on iOS; it's replaced by IOSurface in MetaBackendIOS. Stubs
# return 0/NULL and native_backend=false keeps the KMS paths from compiling at all.

SUBPROJECTS   += libdrm
LIBDRM_VERSION := 2.4.120
DEB_LIBDRM_V   ?= $(LIBDRM_VERSION)+ios2

# Symbols Mutter references (grep -roE 'drm[A-Z][A-Za-z0-9_]*\(' mutter/src); never
# actually called on iOS since native_backend is off.
DRM_SYMS := drmFreeVersion drmGetCap drmGetRenderDeviceNameFromFd drmGetVersion drmHandleEvent \
  drmIoctl drmModeAddFB drmModeAddFB2 drmModeAddFB2WithModifiers drmModeAtomicAddProperty \
  drmModeAtomicAlloc drmModeAtomicCommit drmModeAtomicFree drmModeCloseFB drmModeCreatePropertyBlob \
  drmModeCrtcGetGamma drmModeCrtcSetGamma drmModeDestroyPropertyBlob drmModeFreeConnector \
  drmModeFreeCrtc drmModeFreeEncoder drmModeFreeObjectProperties drmModeFreePlane drmModeFreeProperty \
  drmModeFreePropertyBlob drmModeFreeResources drmModeGetConnector drmModeGetCrtc drmModeGetEncoder \
  drmModeGetPlane drmModeGetPlaneResources drmModeGetProperty drmModeGetPropertyBlob \
  drmModeGetResources drmModeMoveCursor drmModeObjectGetProperties drmModeObjectSetProperty \
  drmModePageFlip drmModeRmFB drmModeSetCrtc drmModeSetCursor drmModeSetCursor2 drmPrimeHandleToFD \
  drmSetClientCap drmSyncobjCreate drmSyncobjDestroy drmSyncobjExportSyncFile drmWaitVBlank \
  drmAuthMagic drmSyncobjEventfd drmSyncobjFDToHandle drmSyncobjImportSyncFile \
  drmSyncobjTimelineSignal drmSyncobjTransfer \
  drmGetDevices2 drmFreeDevices drmGetMagic drmModeGetFB2 drmModeFreeFB2 drmModeRevokeLease \
  drmModeCreateLease drmModeListLessees drmModeGetLease drmIsMaster \
  drmFreeDevice drmModeGetConnectorCurrent drmGetDeviceFromDevId drmDevicesEqual \
  drmGetNodeTypeFromFd drmGetDevice2 drmFreeDevice2

libdrm-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://dri.freedesktop.org/libdrm/libdrm-$(LIBDRM_VERSION).tar.xz)
	$(call EXTRACT_TAR,libdrm-$(LIBDRM_VERSION).tar.xz,libdrm-$(LIBDRM_VERSION),libdrm)

ifneq ($(wildcard $(BUILD_WORK)/libdrm/.build_complete),)
libdrm:
	@echo "Using previously built libdrm (shim)."
else
libdrm: libdrm-setup
	# install REAL libdrm public headers (portable) into include/libdrm
	rm -rf $(BUILD_STAGE)/libdrm
	mkdir -p $(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include/libdrm,lib/pkgconfig}
	cp -a $(BUILD_WORK)/libdrm/xf86drm.h $(BUILD_WORK)/libdrm/xf86drmMode.h \
		$(BUILD_WORK)/libdrm/include/drm/*.h \
		$(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libdrm/
	cp -a $(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libdrm/*.h \
		$(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/
	# generate the links-only stub source + compile a stub libdrm.dylib
	printf '/* iOS links-only stub: dmabuf path inert, replaced by IOSurface (MetaBackendIOS). */\n' \
		> $(BUILD_WORK)/libdrm/drm_stub.c
	for s in $(DRM_SYMS); do echo "long $$s(){return 0;}" >> $(BUILD_WORK)/libdrm/drm_stub.c; done
	$(CC) -dynamiclib -install_name @rpath/libdrm.dylib \
		-current_version $(LIBDRM_VERSION) -compatibility_version 2.4.0 \
		-o $(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdrm.dylib \
		$(BUILD_WORK)/libdrm/drm_stub.c
	# libdrm.pc so mutter's dependency('libdrm', version: '>= 2.4.118') resolves
	printf 'prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libdrm\nDescription: iOS links-only shim (dmabuf inert; IOSurface in MetaBackendIOS)\nVersion: $(LIBDRM_VERSION)\nLibs: -L$${libdir} -ldrm\nCflags: -I$${includedir}\n' \
		> $(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libdrm.pc
	$(call AFTER_BUILD,copy)
endif

libdrm-package: libdrm-stage
	rm -rf $(BUILD_DIST)/libdrm{2,-dev}
	mkdir -p $(BUILD_DIST)/libdrm2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libdrm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	cp -a $(BUILD_STAGE)/libdrm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdrm.dylib \
		$(BUILD_DIST)/libdrm2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libdrm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libdrm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/libdrm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include" ]; then \
		cp -a $(BUILD_STAGE)/libdrm/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
			$(BUILD_DIST)/libdrm-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,libdrm2,general.xml)
	$(call PACK,libdrm2,DEB_LIBDRM_V)
	$(call PACK,libdrm-dev,DEB_LIBDRM_V)
	rm -rf $(BUILD_DIST)/libdrm{2,-dev}

.PHONY: libdrm libdrm-package
