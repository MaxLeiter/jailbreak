ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

SUBPROJECTS        += libsndfile
# 1.0.31 -> 1.2.2 (CVE-2022-33065 and earlier), plus the CVE-2024-50612 and
# CVE-2026-37555 fixes that no release carries yet (ports/libsndfile/patches).
# Soname stays libsndfile.1.dylib. The real file moves from libsndfile.1.0.31.dylib
# to libsndfile.1.0.37.dylib, so the old name ships as a compat symlink: it is a path
# Procursus's package owns and the shadow gate's parity rule checks. Consumers link
# @rpath/libsndfile.1.dylib, not that name.
LIBSNDFILE_VERSION := 1.2.2
DEB_LIBSNDFILE_V   ?= $(LIBSNDFILE_VERSION)+ios1

libsndfile-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE), \
		https://github.com/libsndfile/libsndfile/releases/download/$(LIBSNDFILE_VERSION)/libsndfile-$(LIBSNDFILE_VERSION).tar.xz)
	$(call EXTRACT_TAR,libsndfile-$(LIBSNDFILE_VERSION).tar.xz,libsndfile-$(LIBSNDFILE_VERSION),libsndfile)
	$(call DO_PATCH,libsndfile,libsndfile,-p1)

ifneq ($(wildcard $(BUILD_WORK)/libsndfile/.build_complete),)
libsndfile:
	@echo "Using previously built libsndfile."
else
libsndfile: libsndfile-setup flac libogg libvorbis libopus
	cd $(BUILD_WORK)/libsndfile && ./configure -C \
		$(DEFAULT_CONFIGURE_FLAGS) \
		--disable-mpeg \
		--disable-sqlite \
		--disable-alsa
	+$(MAKE) -C $(BUILD_WORK)/libsndfile
	+$(MAKE) -C $(BUILD_WORK)/libsndfile install \
		DESTDIR=$(BUILD_STAGE)/libsndfile
	$(call AFTER_BUILD,copy)
endif

libsndfile-package: libsndfile-stage
	# libsndfile.mk Package Structure
	rm -rf $(BUILD_DIST)/libsndfile1{,-dev} \
		$(BUILD_DIST)/sndfile-programs
	mkdir -p $(BUILD_DIST)/libsndfile1{,-dev}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/sndfile-programs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share

	# libsndfile.mk Prep libsndfile1
	cp -a $(BUILD_STAGE)/libsndfile/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsndfile.1*.dylib $(BUILD_DIST)/libsndfile1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	[ -e $(BUILD_DIST)/libsndfile1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsndfile.1.0.31.dylib ] || \
		ln -s $$(readlink $(BUILD_DIST)/libsndfile1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsndfile.1.dylib) $(BUILD_DIST)/libsndfile1/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsndfile.1.0.31.dylib

	# libsndfile.mk Prep libsndfile1-dev
	cp -a $(BUILD_STAGE)/libsndfile/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsndfile.{dylib,a} $(BUILD_DIST)/libsndfile1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libsndfile/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig $(BUILD_DIST)/libsndfile1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/libsndfile/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libsndfile1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)

	# libsndfile.mk Prep sndfile-programs
	cp -a $(BUILD_STAGE)/libsndfile/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/sndfile-programs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libsndfile/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/man $(BUILD_DIST)/sndfile-programs/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share

	# libsndfile.mk Sign
	$(call SIGN,libsndfile1,general.xml)
	$(call SIGN,sndfile-programs,general.xml)

	# libsndfile.mk Make .debs
	$(call PACK,libsndfile1,DEB_LIBSNDFILE_V)
	$(call PACK,libsndfile1-dev,DEB_LIBSNDFILE_V)
	$(call PACK,sndfile-programs,DEB_LIBSNDFILE_V)

	# libsndfile.mk Build cleanup
	rm -rf $(BUILD_DIST)/libsndfile1{,-dev} \
		$(BUILD_DIST)/sndfile-programs

.PHONY: libsndfile libsndfile-package
