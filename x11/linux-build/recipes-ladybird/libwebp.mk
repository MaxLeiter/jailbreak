ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# libwebp.mk — Ladybird leaf closure. BUMP 1.2.2 -> 1.6.0 (Ladybird pin). Rewritten to the official
# GitHub release + CMake (the old chromium-googlesource autotools hack is dead weight and dragged in
# libgif/libtiff we do not build). All CLI tools OFF, mux library OFF (Ladybird only decodes); builds
# libwebp + libwebpdemux + libsharpyuv (new split lib in 1.x). Optional libpng/libjpeg-turbo are
# staged (Wave 2) and auto-detected for the encoder path but no CLI tool needs them. +ios1 marker.

SUBPROJECTS     += libwebp
LIBWEBP_VERSION := 1.6.0
DEB_LIBWEBP_V   ?= $(LIBWEBP_VERSION)+ios1

libwebp-setup: setup
	$(call GITHUB_ARCHIVE,webmproject,libwebp,$(LIBWEBP_VERSION),v$(LIBWEBP_VERSION))
	# Stale-tree guard: wipe a mismatched (gtk-era 1.2.2) tree so 1.6.0 extracts.
	if [ -d $(BUILD_WORK)/libwebp ] && ! grep -q "VERSION $(LIBWEBP_VERSION)" $(BUILD_WORK)/libwebp/CMakeLists.txt 2>/dev/null; then \
		echo "libwebp: stale source tree (not $(LIBWEBP_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/libwebp $(BUILD_STAGE)/libwebp; \
	fi
	$(call EXTRACT_TAR,libwebp-$(LIBWEBP_VERSION).tar.gz,libwebp-$(LIBWEBP_VERSION),libwebp)

ifneq ($(wildcard $(BUILD_WORK)/libwebp/.build_complete),)
libwebp:
	@echo "Using previously built libwebp."
else
libwebp: libwebp-setup libpng16 libjpeg-turbo
	cd $(BUILD_WORK)/libwebp && cmake . \
		$(DEFAULT_CMAKE_FLAGS) \
		-DBUILD_SHARED_LIBS=ON \
		-DWEBP_ENABLE_SIMD=ON \
		-DWEBP_BUILD_ANIM_UTILS=OFF \
		-DWEBP_BUILD_CWEBP=OFF \
		-DWEBP_BUILD_DWEBP=OFF \
		-DWEBP_BUILD_GIF2WEBP=OFF \
		-DWEBP_BUILD_IMG2WEBP=OFF \
		-DWEBP_BUILD_VWEBP=OFF \
		-DWEBP_BUILD_WEBPINFO=OFF \
		-DWEBP_BUILD_WEBPMUX=OFF \
		-DWEBP_BUILD_LIBWEBPMUX=ON \
		-DWEBP_BUILD_EXTRAS=OFF
	+$(MAKE) -C $(BUILD_WORK)/libwebp
	+$(MAKE) -C $(BUILD_WORK)/libwebp install \
		DESTDIR="$(BUILD_STAGE)/libwebp"
	$(call AFTER_BUILD,copy)
endif

libwebp-package: .SHELLFLAGS=-O extglob -c
libwebp-package: libwebp-stage
	# libwebp.mk Package Structure
	rm -rf \
		$(BUILD_DIST)/libwebp{7,-dev,demux2} \
		$(BUILD_DIST)/libsharpyuv0
	mkdir -p \
		$(BUILD_DIST)/libwebp-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{include,lib/pkgconfig} \
		$(BUILD_DIST)/libwebp{7,demux2}/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libsharpyuv0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libwebp.mk Prep libwebp7 (runtime versioned dylib)
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebp.[0-9]*.dylib $(BUILD_DIST)/libwebp7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# libwebpmux (Ladybird LibImageDecoders links WebP::libwebpmux unconditionally); bundle its
	# runtime .dylib alongside libwebp7 (dev symlink+header ride the libwebp-dev glob below).
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebpmux.[0-9]*.dylib $(BUILD_DIST)/libwebp7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	# libwebpdecoder (decode-only lib; Ladybird links libwebpdecoder.3 explicitly). libwebp's CMake
	# always builds+installs the `webpdecoder` target but the old package step dropped it -> the
	# engine's runtime closure referenced a libwebpdecoder.3 that no deb shipped. Bundle it into
	# libwebp7 (same version, same dir). Folds the on-device libwebpdecoder.3 -> libwebp.7 symlink hack.
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebpdecoder.[0-9]*.dylib $(BUILD_DIST)/libwebp7/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libwebp.mk Prep libwebpdemux2
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebpdemux.[0-9]*.dylib $(BUILD_DIST)/libwebpdemux2/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libwebp.mk Prep libsharpyuv0 (new split lib in webp 1.x)
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libsharpyuv.[0-9]*.dylib $(BUILD_DIST)/libsharpyuv0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libwebp.mk Prep libwebp-dev (headers, unversioned dylibs, static, pkgconfig, cmake config)
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include $(BUILD_DIST)/libwebp-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/libwebp/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/!(*.[0-9]*.dylib) $(BUILD_DIST)/libwebp-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libwebp.mk Sign
	$(call SIGN,libwebp7,general.xml)
	$(call SIGN,libwebpdemux2,general.xml)
	$(call SIGN,libsharpyuv0,general.xml)

	# libwebp.mk Make .debs
	$(call PACK,libwebp7,DEB_LIBWEBP_V)
	$(call PACK,libwebpdemux2,DEB_LIBWEBP_V)
	$(call PACK,libsharpyuv0,DEB_LIBWEBP_V)
	$(call PACK,libwebp-dev,DEB_LIBWEBP_V)

	# libwebp.mk Build cleanup
	rm -rf $(BUILD_DIST)/libwebp{7,-dev,demux2} $(BUILD_DIST)/libsharpyuv0

.PHONY: libwebp libwebp-package
