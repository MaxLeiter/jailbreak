ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libxshmfence — shared-memory fences for the X SYNC extension. Xwayland always
# compiles miext/sync/misyncshm.c (gated `build_dri3 or build_xwayland`, and
# build_xwayland is hardcoded true), which #includes <X11/xshmfence.h> and links
# xshmfence_*(). No Procursus recipe existed. 1.3.2 is iOS-portable:
#   * backend: auto-picks the PORTABLE pthread primitives (no linux/futex.h on the
#     iOS SDK); we force --disable-futex for determinism.
#   * SHM alloc: memfd_create/SHM_ANON/O_TMPFILE are all #ifdef-guarded and absent
#     on Darwin, so it falls through to the portable mkstemp path. Point that at a
#     writable dir with --with-shared-memory-dir=/var/jb/tmp (Linux default /dev/shm
#     doesn't exist on iOS).
# NB the fence primitives are only exercised by DRI3/GL clients (X0 has none), so
# even if Darwin process-shared condvars are imperfect they're not hit at runtime;
# the library just needs to compile + link. (Revisit for the X1/GL path.)

SUBPROJECTS          += libxshmfence
LIBXSHMFENCE_VERSION := 1.3.2
DEB_LIBXSHMFENCE_V   ?= $(LIBXSHMFENCE_VERSION)

libxshmfence-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://xorg.freedesktop.org/archive/individual/lib/libxshmfence-$(LIBXSHMFENCE_VERSION).tar.xz)
	$(call EXTRACT_TAR,libxshmfence-$(LIBXSHMFENCE_VERSION).tar.xz,libxshmfence-$(LIBXSHMFENCE_VERSION),libxshmfence)

ifneq ($(wildcard $(BUILD_WORK)/libxshmfence/.build_complete),)
libxshmfence:
	@echo "Using previously built libxshmfence."
else
libxshmfence: libxshmfence-setup xorgproto
	cd $(BUILD_WORK)/libxshmfence && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-futex \
		--with-shared-memory-dir=/var/jb/tmp
	+$(MAKE) -C $(BUILD_WORK)/libxshmfence
	+$(MAKE) -C $(BUILD_WORK)/libxshmfence install \
		DESTDIR=$(BUILD_STAGE)/libxshmfence
	$(call AFTER_BUILD,copy)
endif

libxshmfence-package: libxshmfence-stage
	# libxshmfence.mk Package Structure
	rm -rf $(BUILD_DIST)/libxshmfence{1,-dev}
	mkdir -p $(BUILD_DIST)/libxshmfence{1,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# runtime dylib + its real install-name target. `libxshmfence.1.dylib`
	# is a symlink to `libxshmfence.1.0.0.dylib`; ship both or dyld sees a
	# dangling @rpath dependency at runtime.
	cp -a $(BUILD_STAGE)/libxshmfence/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libxshmfence.1*.dylib \
		$(BUILD_DIST)/libxshmfence1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# -dev: headers, .pc, .a, unversioned .dylib symlink
	cp -a $(BUILD_STAGE)/libxshmfence/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/{libxshmfence.{a,dylib},pkgconfig} \
		$(BUILD_DIST)/libxshmfence-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libxshmfence/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libxshmfence-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# libxshmfence.mk Sign
	$(call SIGN,libxshmfence1,general.xml)

	# libxshmfence.mk Make .debs
	$(call PACK,libxshmfence1,DEB_LIBXSHMFENCE_V)
	$(call PACK,libxshmfence-dev,DEB_LIBXSHMFENCE_V)

	# libxshmfence.mk Build cleanup
	rm -rf $(BUILD_DIST)/libxshmfence{1,-dev}

.PHONY: libxshmfence libxshmfence-package
