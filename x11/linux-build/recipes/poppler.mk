ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# poppler.mk — Poppler, the PDF rendering library (poppler.freedesktop.org), built with the
# glib bindings ONLY (libpoppler-glib). This is the one genuinely new dependency the Papers
# GTK4 document viewer pulls in. Plain CMake project; every external dep it needs at this
# feature level is already in our tree (freetype, fontconfig, cairo, glib, libjpeg-turbo,
# libpng — all in the GTK4 base), so it adds ZERO new sub-deps.
#
# Configured MINIMAL to avoid dep sprawl (see the -D flags): only the glib frontend is built,
# the qt5/qt6/cpp frontends + all utils/tests are off, and every optional codec/feature that
# would drag in a NEW library (nss, gpgme, libcurl, lcms, openjpeg, libtiff, boost) is off.
# DCT (JPEG) uses the already-present libjpeg-turbo. GObject-Introspection is OFF (the girs are
# an on-device g-ir pass, like the rest of the stack); Papers links poppler-glib directly, not
# via typelib, so this costs nothing for the viewer.
#
# 24.08.0 is a stable point release; its core C++ library SONAME is libpoppler.so.140
# (-> libpoppler140) and the glib binding is the long-stable libpoppler-glib.so.8
# (-> libpoppler-glib8). Package split mirrors libgee: runtime libpoppler140 +
# libpoppler-glib8 + a combined -dev (headers/.pc/bare symlinks).

SUBPROJECTS      += poppler
POPPLER_VERSION  := 24.08.0
POPPLER_SOV      := 140
DEB_POPPLER_V    ?= $(POPPLER_VERSION)

poppler-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://poppler.freedesktop.org/poppler-$(POPPLER_VERSION).tar.xz)
	$(call EXTRACT_TAR,poppler-$(POPPLER_VERSION).tar.xz,poppler-$(POPPLER_VERSION),poppler)

ifneq ($(wildcard $(BUILD_WORK)/poppler/.build_complete),)
poppler:
	@echo "Using previously built poppler."
else
# Deps (freetype/fontconfig/cairo/glib/libjpeg/libpng) are pre-staged in build_base; no
# make-level prereqs (mutter/kcoreaddons precedent — the GTK4 volume is fully warmed).
poppler: poppler-setup
	# Wipe the build dir so a prior crashed configure can't leave a poisoned CMake cache.
	rm -rf $(BUILD_WORK)/poppler/build
	cd $(BUILD_WORK)/poppler && cmake -B build \
		$(DEFAULT_CMAKE_FLAGS) \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DBUILD_SHARED_LIBS=ON \
		-DENABLE_GLIB=ON \
		-DENABLE_GOBJECT_INTROSPECTION=OFF \
		-DENABLE_QT5=OFF \
		-DENABLE_QT6=OFF \
		-DENABLE_CPP=OFF \
		-DENABLE_UTILS=OFF \
		-DBUILD_GTK_TESTS=OFF \
		-DBUILD_QT5_TESTS=OFF \
		-DBUILD_QT6_TESTS=OFF \
		-DBUILD_CPP_TESTS=OFF \
		-DBUILD_MANUAL_TESTS=OFF \
		-DENABLE_BOOST=OFF \
		-DENABLE_NSS3=OFF \
		-DENABLE_GPGME=OFF \
		-DENABLE_LIBCURL=OFF \
		-DENABLE_LCMS=OFF \
		-DENABLE_LIBTIFF=OFF \
		-DENABLE_LIBOPENJPEG=none \
		-DENABLE_DCTDECODER=libjpeg \
		-DENABLE_ZLIB_UNCOMPRESS=OFF
	+$(MAKE) -C $(BUILD_WORK)/poppler/build
	+$(MAKE) -C $(BUILD_WORK)/poppler/build install DESTDIR="$(BUILD_STAGE)/poppler"
	$(call AFTER_BUILD,copy)
endif

poppler-package: poppler-stage
	rm -rf $(BUILD_DIST)/libpoppler$(POPPLER_SOV) $(BUILD_DIST)/libpoppler-glib8 $(BUILD_DIST)/libpoppler-dev
	mkdir -p $(BUILD_DIST)/libpoppler$(POPPLER_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpoppler-glib8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libpoppler-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libpoppler<N>: the core C++ dylib (real file + soname symlink). The glob's literal '.'
	# after "libpoppler" excludes libpoppler-glib.* (which begins "libpoppler-").
	cp -a $(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpoppler.*.dylib \
		$(BUILD_DIST)/libpoppler$(POPPLER_SOV)/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# libpoppler-glib8: the glib binding dylib (real file + soname symlink).
	cp -a $(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpoppler-glib.*.dylib \
		$(BUILD_DIST)/libpoppler-glib8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# -dev: headers, .pc files, the bare (unversioned) symlinks, and the gdk helper header.
	cp -a $(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include \
		$(BUILD_DIST)/libpoppler-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpoppler.dylib \
		$(BUILD_DIST)/libpoppler-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	cp -a $(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libpoppler-glib.dylib \
		$(BUILD_DIST)/libpoppler-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib 2>/dev/null || true
	if [ -d "$(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig" ]; then \
		cp -a $(BUILD_STAGE)/poppler/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
			$(BUILD_DIST)/libpoppler-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi

	$(call SIGN,libpoppler$(POPPLER_SOV),general.xml)
	$(call SIGN,libpoppler-glib8,general.xml)
	$(call PACK,libpoppler$(POPPLER_SOV),DEB_POPPLER_V)
	$(call PACK,libpoppler-glib8,DEB_POPPLER_V)
	$(call PACK,libpoppler-dev,DEB_POPPLER_V)
	rm -rf $(BUILD_DIST)/libpoppler$(POPPLER_SOV) $(BUILD_DIST)/libpoppler-glib8 $(BUILD_DIST)/libpoppler-dev

.PHONY: poppler poppler-package
