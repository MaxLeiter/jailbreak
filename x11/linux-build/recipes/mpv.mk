ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# mpv.mk — mpv, the Wayland-native GPU media player, for the iosc desktop (github.com/mpv-player/mpv).
# Pinned to 0.36.0 ON PURPOSE: mpv 0.37+ makes libplacebo (>=6.338) a HARD dependency (for the
# vo=gpu-next default), and libplacebo is not built on procursus-vol-wayland. In 0.36 libplacebo is
# optional (meson `auto`), so we disable it and use the classic OpenGL renderer, --vo=gpu, over the
# desktop's EGL/GLES (the `angle`/mesa stack imv also links) on a wl_surface via wayland-egl. That
# is the zero-copy GPU video path — the point of shipping mpv here.
#
# VIDEO: gl + egl + egl-wayland + wayland. All X11/DRM/GBM/VAAPI/VDPAU/Vulkan and every macOS/iOS
# ObjC path (cocoa, gl-cocoa, videotoolbox-gl, ios-gl, audiounit, swift) are DISABLED — the ObjC
# framework sources transitively pull Foundation -> the jailbreak's broken xpc/session.h (same wall
# ffmpeg's videotoolbox probe hit), and we don't need them for the wayland-egl renderer.
# AUDIO: PulseAudio (-Dpulse=enabled) AND the native iOS audiounit AO (-Daudiounit=enabled, the
# RemoteIO/AVAudioSession path). `coreaudio` stays disabled — that AO is macOS-only (AudioHardware
# default-device APIs absent on iOS). audiounit's AVAudioSession probe used to fail on the broken
# xpc/session.h; build-wayland-apps.sh's os/object.h sendable-macro backport unblocks it. So mpv
# has BOTH a self-contained native AO (audiounit) and the PA `pulse` AO for the desktop's PA 17
# daemon (module-xios-sink). The libpulse CLIENT lib (libpulse.dylib + pulse/*.h + libpulse.pc,
# built on procursus-vol-shell as the libpulse0/-dev debs) is staged into build_base from /out by
# build-wayland-apps.sh before the make loop — libpulse is NOT a Procursus subproject on this volume,
# so it is staged as a prebuilt deb rather than listed as a make prerequisite. Runtime Depends:
# libpulse0. FFmpeg here is our lean decode-first build (software decoders, no external codecs).
#
# BUILD-HOST TOOLS (via build-wayland-apps.sh): native wayland-scanner (mpv codegens its wayland
# protocol glue), python3 (mpv's build scripts). DEPENDS (target): ffmpeg(libav*/libsw*), libass,
# freetype, fontconfig, harfbuzz, libfribidi, wayland, wayland-protocols, libxkbcommon, mesa(EGL/GL),
# libjpeg-turbo (screenshots), zlib.

SUBPROJECTS  += mpv
MPV_VERSION  := 0.36.0
DEB_MPV_V    ?= $(MPV_VERSION)+ios1

mpv-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/mpv-player/mpv/archive/refs/tags/v$(MPV_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(MPV_VERSION).tar.gz,mpv-$(MPV_VERSION),mpv)
	# Darwin/iOS portability shim (pipe2), force-included into every mpv C TU via c_args below.
	cp $(BUILD_INFO)/mpv-compat.h $(BUILD_WORK)/mpv/mpv-compat.h
	# mpv's meson only registers the ObjC language (needed for ao_audiounit.m) after detecting a
	# macOS SDK via `xcrun`/xcodebuild — which don't exist in this Linux->iOS cross env, so
	# macos_sdk_version stays '0.0' and add_languages('objc') never runs, aborting with
	# "No host machine compiler for ao_audiounit.m". Force an unconditional add_languages('objc')
	# (the cross file supplies objc = $(CC)); the dormant macos_sdk block is left alone so its
	# empty-path -isysroot link flags are never added. Idempotent-guarded.
	grep -q "XIOS-force-objc" $(BUILD_WORK)/mpv/meson.build || \
		sed -i "s|^xcrun = find_program('xcrun'|add_languages('objc') # XIOS-force-objc\nxcrun = find_program('xcrun'|" \
			$(BUILD_WORK)/mpv/meson.build
	rm -rf $(BUILD_WORK)/mpv/build && mkdir -p $(BUILD_WORK)/mpv/build
	echo -e "[host_machine]\n \
	system = 'darwin'\n \
	cpu_family = '$(shell echo $(GNU_HOST_TRIPLE) | cut -d- -f1)'\n \
	cpu = '$(MEMO_ARCH)'\n \
	endian = 'little'\n \
	[properties]\n \
	root = '$(BUILD_BASE)'\n \
	needs_exe_wrapper = true\n \
	[built-in options]\n \
	prefix ='$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)'\n \
	c_args = ['-Wno-error', '-include', '$(BUILD_WORK)/mpv/mpv-compat.h', '-I$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include']\n \
	objc_args = ['-Wno-error', '-I$(BUILD_BASE)$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include']\n \
	[binaries]\n \
	c = '$(CC)'\n \
	cpp = '$(CXX)'\n \
	objc = '$(CC)'\n \
	pkgconfig = '$(BUILD_TOOLS)/cross-pkg-config'\n" > $(BUILD_WORK)/mpv/build/cross.txt

ifneq ($(wildcard $(BUILD_WORK)/mpv/.build_complete),)
mpv:
	@echo "Using previously built mpv."
else
mpv: mpv-setup ffmpeg libass freetype fontconfig harfbuzz libfribidi wayland wayland-protocols libxkbcommon mesa libjpeg-turbo
	# native wayland-scanner on PATH + a native pkg-config at its .pc (same trick as foot/imv).
	cd $(BUILD_WORK)/mpv/build && \
		printf "[binaries]\npkgconfig = 'pkg-config'\n[built-in options]\npkg_config_path = ['$(WAYLAND_NATIVE_ROOT)/lib/pkgconfig']\n" > native.txt && \
		PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" meson \
		--cross-file cross.txt \
		--native-file native.txt \
		--buildtype=release \
		-Dcplayer=true \
		-Dlibmpv=false \
		-Dtests=false \
		-Dbuild-date=false \
		-Dgl=enabled \
		-Degl=enabled \
		-Degl-wayland=enabled \
		-Dwayland=enabled \
		-Djpeg=enabled \
		-Dzlib=enabled \
		-Diconv=enabled \
		-Dlibplacebo=disabled \
		-Dlibplacebo-next=disabled \
		-Dvulkan=disabled \
		-Dvulkan-interop=disabled \
		-Dshaderc=disabled \
		-Dspirv-cross=disabled \
		-Dx11=disabled \
		-Dgl-x11=disabled \
		-Degl-x11=disabled \
		-Dxv=disabled \
		-Dvdpau=disabled \
		-Dvdpau-gl-x11=disabled \
		-Dvaapi=disabled \
		-Dvaapi-x11=disabled \
		-Dvaapi-x-egl=disabled \
		-Dvaapi-drm=disabled \
		-Dvaapi-wayland=disabled \
		-Ddrm=disabled \
		-Degl-drm=disabled \
		-Dgbm=disabled \
		-Ddmabuf-wayland=disabled \
		-Dcocoa=disabled \
		-Dgl-cocoa=disabled \
		-Dvideotoolbox-gl=disabled \
		-Dios-gl=disabled \
		-Dmacos-cocoa-cb=disabled \
		-Dmacos-media-player=disabled \
		-Dmacos-touchbar=disabled \
		-Dswift-build=disabled \
		-Dcaca=disabled \
		-Dsixel=disabled \
		-Dsdl2=disabled \
		-Dsdl2-video=disabled \
		-Dsdl2-gamepad=disabled \
		-Dsdl2-audio=disabled \
		-Dplain-gl=disabled \
		-Daudiounit=enabled \
		-Dcoreaudio=disabled \
		-Dalsa=disabled \
		-Djack=disabled \
		-Dopenal=disabled \
		-Dopensles=disabled \
		-Doss-audio=disabled \
		-Dpipewire=disabled \
		-Dpulse=enabled \
		-Dsndio=disabled \
		-Dwasapi=disabled \
		-Dlua=disabled \
		-Djavascript=disabled \
		-Dlibarchive=disabled \
		-Duchardet=disabled \
		-Drubberband=disabled \
		-Dvapoursynth=disabled \
		-Dcdda=disabled \
		-Ddvdnav=disabled \
		-Dcplugins=disabled \
		-Dlcms2=disabled \
		-Dlibbluray=disabled \
		-Ddvbin=disabled \
		-Dzimg=disabled \
		-Dlibavdevice=disabled \
		-Dhtml-build=disabled \
		-Dmanpage-build=disabled \
		-Dpdf-build=disabled \
		..
	+PATH="$(WAYLAND_NATIVE_ROOT)/bin:$$PATH" ninja -C $(BUILD_WORK)/mpv/build
	+DESTDIR="$(BUILD_STAGE)/mpv" ninja -C $(BUILD_WORK)/mpv/build install
	$(call AFTER_BUILD,copy)
endif

mpv-package: mpv-stage
	rm -rf $(BUILD_DIST)/mpv
	mkdir -p $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	cp -a $(BUILD_STAGE)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)
	if [ -d "$(BUILD_STAGE)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share" ]; then \
		cp -a $(BUILD_STAGE)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi
	if [ -d "$(BUILD_STAGE)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc" ]; then \
		cp -a $(BUILD_STAGE)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/etc $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX); \
	fi

	$(call SIGN,mpv,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,mpv,DEB_MPV_V)
	rm -rf $(BUILD_DIST)/mpv

.PHONY: mpv mpv-package
