ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libdrm.mk — *** LINKS-ONLY SHIM for iOS. *** libdrm is a Linux kernel DRM/KMS interface; it
# CANNOT exist on iOS (no DRM device). Mutter's Wayland backend links libdrm for the Linux dmabuf
# buffer path (DRM fourcc/modifiers). This shim provides libdrm's REAL, portable public headers
# (drm_fourcc.h/drm.h/xf86drm*.h — they support non-Linux by design) plus a links-only stub of the
# drm* symbols Mutter references, so libmutter/cogl/clutter COMPILE and LINK for typelib generation.
#
#   *** THE dmabuf BUFFER PATH IS NON-FUNCTIONAL ON iOS. *** It is replaced by IOSurface in the
#   *** MetaBackendIOS compositor backend (coordinated with the iosc track). These stubs return 0/
#   *** NULL; with native_backend=false the KMS paths are not compiled, and the Wayland dmabuf path
#   *** is inert. DO NOT mistake this for a working buffer path.

SUBPROJECTS   += libdrm
LIBDRM_VERSION := 2.4.120
DEB_LIBDRM_V   ?= $(LIBDRM_VERSION)

# drm* symbols Mutter references (from `grep -roE 'drm[A-Z][A-Za-z0-9_]*\(' mutter/src`). Stubbed
# as no-ops so libmutter links; never actually called on iOS (native off, dmabuf path inert).
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
	# generate the links-only stub source + compile a stub libdrm.dylib
	printf '/* iOS links-only stub: dmabuf path inert, replaced by IOSurface (MetaBackendIOS). */\n' \
		> $(BUILD_WORK)/libdrm/drm_stub.c
	for s in $(DRM_SYMS); do echo "long $$s(){return 0;}" >> $(BUILD_WORK)/libdrm/drm_stub.c; done
	$(CC) -dynamiclib -install_name @rpath/libdrm.dylib \
		-current_version $(LIBDRM_VERSION) -compatibility_version 2.4.0 \
		-o $(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libdrm.dylib \
		$(BUILD_WORK)/libdrm/drm_stub.c
	# libdrm.pc so mutter's dependency('libdrm', version: '>= 2.4.118') resolves
	printf 'prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: libdrm\nDescription: iOS links-only shim (dmabuf inert; IOSurface in MetaBackendIOS)\nVersion: $(LIBDRM_VERSION)\nLibs: -L$${libdir} -ldrm\nCflags: -I$${includedir}/libdrm\n' \
		> $(BUILD_STAGE)/libdrm$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libdrm.pc
	$(call AFTER_BUILD,copy)
endif

libdrm-package: libdrm-stage
	# libdrm.mk Package Structure — ship the links-only shim so consumers that link
	# @rpath/libdrm.dylib (Xwayland, mutter) resolve it on-device. Runtime deb
	# (libdrm2) + a -dev deb (header shims + libdrm.pc). Still INERT (dmabuf path
	# replaced by IOSurface); this only satisfies the dyld/link reference.
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
