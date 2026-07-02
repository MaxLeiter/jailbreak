ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# ffmpeg.mk (Xios/Wayland lean override) — FFmpeg 5.1.2, built decode-first for the mpv media
# player on the iosc Wayland desktop. This deliberately REPLACES the stock Procursus ffmpeg
# recipe, whose configure pulls a ~30-package external-codec tree (aom, dav1d, rav1e[Rust],
# x264/x265, tesseract, sdl2, ...) that is not built on procursus-vol-wayland. Instead we ship
# FFmpeg's own native decoders/demuxers/parsers/protocols (which cover H.264/HEVC/VP8/VP9/AV1-sw/
# AAC/MP3/Opus/Vorbis/FLAC/matroska/mp4/webm/... out of the box), with NO external -lXXX deps.
# Both Apple frameworks (VideoToolbox HW decode + AudioToolbox) are now ENABLED. Their ObjC
# framework probes transitively pull Foundation -> NSXPCConnection -> xpc/session.h, which used to
# hard-fail because the cross toolchain's iPhoneOS16.5.sdk os/object.h predates the
# OS_OBJECT_DECL_SENDABLE_* macros session.h needs (clang: "a parameter list without types is only
# allowed in a function definition"). build-wayland-apps.sh now backports those 3 macros into the
# SDK's os/object.h before configure, so both probes compile. VideoToolbox gives HW-accelerated
# H.264/HEVC decode; AudioToolbox adds Apple's native AAC/etc decoders. These link only Apple SYSTEM
# frameworks (VideoToolbox/CoreMedia/CoreVideo/AudioToolbox), so the soname debs stay self-contained
# (they depend only on each other) — which is why we also override the stock controls (Procursus's
# libavcodec59.control Depends on libvpx7/libdav1d6/... which don't exist here).
# NOTE: the libavdevice AudioToolbox in/out DEVICE (libavdevice/audiotoolbox.m) is force-disabled:
# it uses the macOS-only CoreAudio HAL (AudioDeviceID/kAudioHardwarePropertyDevices/AudioObject*),
# which does not exist on iOS. Only the libavcodec AudioToolbox CODECS (AAC via AudioConverter) and
# the VideoToolbox HW decoders are kept — those are iOS-supported. (mpv builds with
# -Dlibavdevice=disabled anyway, so it never touches libavdevice.)
#
# SONAMEs (5.1.2): libavutil.57 libavcodec.59 libavformat.59 libavdevice.59 libavfilter.8
# No `ffmpeg`/`ffplay`/`ffprobe` CLI deb (--disable-programs) — mpv only links the libs.

SUBPROJECTS    += ffmpeg
FFMPEG_VERSION := 5.1.2
DEB_FFMPEG_V   ?= $(FFMPEG_VERSION)

ffmpeg-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://ffmpeg.org/releases/ffmpeg-$(FFMPEG_VERSION).tar.xz)
	$(call EXTRACT_TAR,ffmpeg-$(FFMPEG_VERSION).tar.xz,ffmpeg-$(FFMPEG_VERSION),ffmpeg)

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
		--enable-videotoolbox \
		--enable-audiotoolbox \
		--disable-indev=audiotoolbox \
		--disable-outdev=audiotoolbox \
		--disable-programs \
		--disable-doc \
		--disable-debug \
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
	# ffmpeg.mk Package Structure
	rm -rf \
		$(BUILD_DIST)/libavcodec{59,-dev} \
		$(BUILD_DIST)/libavdevice{59,-dev} \
		$(BUILD_DIST)/libavfilter{8,-dev} \
		$(BUILD_DIST)/libavformat{59,-dev} \
		$(BUILD_DIST)/libavutil{57,-dev} \
		$(BUILD_DIST)/libswresample{4,-dev} \
		$(BUILD_DIST)/libswscale{6,-dev}
	mkdir -p \
		$(BUILD_DIST)/libavcodec59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavcodec-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libavdevice59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavdevice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libavfilter8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavfilter-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libavformat59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavformat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libavutil57/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libavutil-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libswresample4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libswresample-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include} \
		$(BUILD_DIST)/libswscale6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libswscale-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/{lib/pkgconfig,include}

	# runtime dylibs (versioned soname) -> libXXX<N>
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavcodec.59*.dylib     $(BUILD_DIST)/libavcodec59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavdevice.59*.dylib    $(BUILD_DIST)/libavdevice59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavfilter.8*.dylib     $(BUILD_DIST)/libavfilter8/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavformat.59*.dylib    $(BUILD_DIST)/libavformat59/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavutil.57*.dylib      $(BUILD_DIST)/libavutil57/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libswresample.4*.dylib   $(BUILD_DIST)/libswresample4/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libswscale.6*.dylib      $(BUILD_DIST)/libswscale6/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib

	# -dev: unversioned .dylib + .a + headers + .pc
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavcodec.{dylib,a}     $(BUILD_DIST)/libavcodec-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavcodec           $(BUILD_DIST)/libavcodec-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavcodec.pc  $(BUILD_DIST)/libavcodec-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavdevice.{dylib,a}    $(BUILD_DIST)/libavdevice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavdevice          $(BUILD_DIST)/libavdevice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavdevice.pc $(BUILD_DIST)/libavdevice-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavfilter.{dylib,a}    $(BUILD_DIST)/libavfilter-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavfilter          $(BUILD_DIST)/libavfilter-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavfilter.pc $(BUILD_DIST)/libavfilter-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavformat.{dylib,a}    $(BUILD_DIST)/libavformat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavformat          $(BUILD_DIST)/libavformat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavformat.pc $(BUILD_DIST)/libavformat-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libavutil.{dylib,a}      $(BUILD_DIST)/libavutil-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libavutil            $(BUILD_DIST)/libavutil-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libavutil.pc   $(BUILD_DIST)/libavutil-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libswresample.{dylib,a}  $(BUILD_DIST)/libswresample-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libswresample        $(BUILD_DIST)/libswresample-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libswresample.pc $(BUILD_DIST)/libswresample-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libswscale.{dylib,a}     $(BUILD_DIST)/libswscale-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/libswscale           $(BUILD_DIST)/libswscale-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include
	cp -a $(BUILD_STAGE)/ffmpeg/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/libswscale.pc  $(BUILD_DIST)/libswscale-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# ffmpeg.mk Sign
	$(call SIGN,libavcodec59,general.xml)
	$(call SIGN,libavdevice59,general.xml)
	$(call SIGN,libavfilter8,general.xml)
	$(call SIGN,libavformat59,general.xml)
	$(call SIGN,libavutil57,general.xml)
	$(call SIGN,libswresample4,general.xml)
	$(call SIGN,libswscale6,general.xml)

	# ffmpeg.mk Make .debs
	$(call PACK,libavcodec59,DEB_FFMPEG_V)
	$(call PACK,libavcodec-dev,DEB_FFMPEG_V)
	$(call PACK,libavdevice59,DEB_FFMPEG_V)
	$(call PACK,libavdevice-dev,DEB_FFMPEG_V)
	$(call PACK,libavfilter8,DEB_FFMPEG_V)
	$(call PACK,libavfilter-dev,DEB_FFMPEG_V)
	$(call PACK,libavformat59,DEB_FFMPEG_V)
	$(call PACK,libavformat-dev,DEB_FFMPEG_V)
	$(call PACK,libavutil57,DEB_FFMPEG_V)
	$(call PACK,libavutil-dev,DEB_FFMPEG_V)
	$(call PACK,libswresample4,DEB_FFMPEG_V)
	$(call PACK,libswresample-dev,DEB_FFMPEG_V)
	$(call PACK,libswscale6,DEB_FFMPEG_V)
	$(call PACK,libswscale-dev,DEB_FFMPEG_V)

	# ffmpeg.mk Build cleanup
	rm -rf \
		$(BUILD_DIST)/libavcodec{59,-dev} \
		$(BUILD_DIST)/libavdevice{59,-dev} \
		$(BUILD_DIST)/libavfilter{8,-dev} \
		$(BUILD_DIST)/libavformat{59,-dev} \
		$(BUILD_DIST)/libavutil{57,-dev} \
		$(BUILD_DIST)/libswresample{4,-dev} \
		$(BUILD_DIST)/libswscale{6,-dev}

.PHONY: ffmpeg ffmpeg-package
