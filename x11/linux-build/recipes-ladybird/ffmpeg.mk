ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Minimal ffmpeg, required even though playback itself is an M2 concern: Ladybird's
# Meta/CMake/check_for_dependencies.cmake unconditionally pkg_check_modules(REQUIRED) for
# exactly libavcodec, libavformat, libavutil, libswresample (no swscale/avfilter/avdevice
# check), so configure fails without an ffmpeg 7.1.x present.
#
# Builds the smallest ffmpeg providing those four .pc files: --disable-everything (no codecs/
# muxers/parsers, those come in M2), --disable-autodetect (no zlib/lzma/iconv/framework
# pull-in), and avdevice/avfilter/swscale/postproc disabled. No external -lXXX deps or ObjC
# framework probes (videotoolbox/audiotoolbox off), so the dylibs depend only on each other +
# libSystem. Replaces both the stock Procursus recipe and the ffmpeg-5.1.2 override (ffmpeg-5
# API; Ladybird needs the ffmpeg-7 API, so no reuse).
#
# SONAMEs: libavutil.59 libavcodec.61 libavformat.61 libswresample.5. No CLI tools (--disable-programs).

SUBPROJECTS    += ffmpeg
FFMPEG_VERSION := 7.1.1
DEB_FFMPEG_V   ?= $(FFMPEG_VERSION)+ios1

ffmpeg-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ffmpeg.org/releases/ffmpeg-$(FFMPEG_VERSION).tar.xz)
	# Stale-tree guard: no old ffmpeg tree is expected on this volume (build_base was clean of
	# libav*), but guard anyway so a re-run can't mislabel a wrong-version tree.
	if [ -d $(BUILD_WORK)/ffmpeg ] && ! grep -qs "$(FFMPEG_VERSION)" $(BUILD_WORK)/ffmpeg/RELEASE 2>/dev/null; then \
		echo "ffmpeg: stale source tree in build_work (not $(FFMPEG_VERSION)), wiping"; \
		rm -rf $(BUILD_WORK)/ffmpeg $(BUILD_STAGE)/ffmpeg; \
	fi
	$(call EXTRACT_TAR,ffmpeg-$(FFMPEG_VERSION).tar.xz,ffmpeg-$(FFMPEG_VERSION),ffmpeg)
	# Upstream Ladybird (overlay-ports/ffmpeg/0100-ladybird-symbol-version-nodes.patch) renames the ELF/Mach
	# symbol-version nodes so a system FFmpeg can be loaded beside this one; its CMake now looks for the
	# libavcodec-ladybird/libavformat-ladybird/libavutil-ladybird/libswresample-ladybird .pc files, which
	# --build-suffix=-ladybird produces.
	for l in avcodec:AVCODEC avformat:AVFORMAT avutil:AVUTIL swresample:SWRESAMPLE; do \
		sed -i "s/^LIB$${l#*:}_MAJOR {/LIB$${l#*:}_LADYBIRD_MAJOR {/" $(BUILD_WORK)/ffmpeg/lib$${l%%:*}/lib$${l%%:*}.v; \
	done

ifneq ($(wildcard $(BUILD_WORK)/ffmpeg/.build_complete),)
ffmpeg:
	@echo "Using previously built ffmpeg."
else
ffmpeg: ffmpeg-setup
	cd $(BUILD_WORK)/ffmpeg && ./configure \
		--cross-prefix="$(GNU_HOST_TRIPLE)-" \
		--prefix=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX) \
		--enable-shared \
		--enable-static \
		--enable-pthreads \
		--build-suffix=-ladybird \
		--enable-cross-compile \
		--target-os=darwin \
		--arch=$(MEMO_ARCH) \
		--cc="$(CC)" \
		--cxx="$(CXX)" \
		--nm="$(NM)" \
		--ar="$(AR)" \
		--ranlib="$(RANLIB)" \
		--strip="$(STRIP)" \
		--host-cc="$(CC_FOR_BUILD)" \
		--host-cflags="$(CFLAGS_FOR_BUILD)" \
		--host-ldflags="$(LDFLAGS_FOR_BUILD)" \
		--disable-everything \
		--disable-autodetect \
		--disable-programs \
		--disable-doc \
		--disable-debug \
		--disable-network \
		--disable-avdevice \
		--disable-avfilter \
		--disable-swscale \
		--disable-postproc \
		--disable-videotoolbox \
		--disable-audiotoolbox \
		--disable-sdl2 \
		--disable-xlib \
		--disable-libxcb \
		--disable-vaapi \
		--disable-vdpau
	# ffmpeg hardcodes an @rpath-less INSTALL_NAME_DIR; point it at the deb libdir so the dylibs'
	# LC_ID_DYLIB resolves once installed under /var/jb/usr/lib (AFTER_BUILD also @rpath-izes).
	sed -i -e 's|^INSTALL_NAME_DIR=.*$$|INSTALL_NAME_DIR=$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib|' \
		$(BUILD_WORK)/ffmpeg/ffbuild/config.mak
	+$(MAKE) -C $(BUILD_WORK)/ffmpeg
	+$(MAKE) -C $(BUILD_WORK)/ffmpeg install \
		DESTDIR=$(BUILD_STAGE)/ffmpeg
	$(call AFTER_BUILD,copy)
endif

ffmpeg-package: ffmpeg-stage
	rm -rf \
		$(BUILD_DIST)/libavcodec{61,-dev} \
		$(BUILD_DIST)/libavformat{61,-dev} \
		$(BUILD_DIST)/libavutil{59,-dev} \
		$(BUILD_DIST)/libswresample{5,-dev}
	mkdir -p \
		$(BUILD_DIST)/libavcodec-ladybird61/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavcodec-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libavformat-ladybird61/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavformat-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libavutil-ladybird59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavutil-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libswresample-ladybird5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libswresample-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include}

	# runtime dylibs (versioned soname)
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavcodec-ladybird.61*.dylib    $(BUILD_DIST)/libavcodec-ladybird61/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavformat-ladybird.61*.dylib   $(BUILD_DIST)/libavformat-ladybird61/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavutil-ladybird.59*.dylib     $(BUILD_DIST)/libavutil-ladybird59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libswresample-ladybird.5*.dylib  $(BUILD_DIST)/libswresample-ladybird5/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# -dev: unversioned .dylib + .a + headers + .pc
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavcodec-ladybird.{dylib,a}    $(BUILD_DIST)/libavcodec-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavcodec          $(BUILD_DIST)/libavcodec-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavcodec-ladybird.pc $(BUILD_DIST)/libavcodec-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavformat-ladybird.{dylib,a}   $(BUILD_DIST)/libavformat-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavformat         $(BUILD_DIST)/libavformat-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavformat-ladybird.pc $(BUILD_DIST)/libavformat-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavutil-ladybird.{dylib,a}     $(BUILD_DIST)/libavutil-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavutil           $(BUILD_DIST)/libavutil-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavutil-ladybird.pc  $(BUILD_DIST)/libavutil-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libswresample-ladybird.{dylib,a} $(BUILD_DIST)/libswresample-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libswresample       $(BUILD_DIST)/libswresample-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libswresample-ladybird.pc $(BUILD_DIST)/libswresample-ladybird-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	$(call SIGN,libavcodec-ladybird61,general.xml)
	$(call SIGN,libavformat-ladybird61,general.xml)
	$(call SIGN,libavutil-ladybird59,general.xml)
	$(call SIGN,libswresample-ladybird5,general.xml)

	$(call PACK,libavcodec-ladybird61,DEB_FFMPEG_V)
	$(call PACK,libavcodec-ladybird-dev,DEB_FFMPEG_V)
	$(call PACK,libavformat-ladybird61,DEB_FFMPEG_V)
	$(call PACK,libavformat-ladybird-dev,DEB_FFMPEG_V)
	$(call PACK,libavutil-ladybird59,DEB_FFMPEG_V)
	$(call PACK,libavutil-ladybird-dev,DEB_FFMPEG_V)
	$(call PACK,libswresample-ladybird5,DEB_FFMPEG_V)
	$(call PACK,libswresample-ladybird-dev,DEB_FFMPEG_V)

	rm -rf \
		$(BUILD_DIST)/libavcodec{61,-dev} \
		$(BUILD_DIST)/libavformat{61,-dev} \
		$(BUILD_DIST)/libavutil{59,-dev} \
		$(BUILD_DIST)/libswresample{5,-dev}

.PHONY: ffmpeg ffmpeg-package
