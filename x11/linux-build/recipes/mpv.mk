ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# Pinned to 0.36.0: 0.37+ hard-requires libplacebo (not built here), so this uses the classic
# vo=gpu OpenGL/EGL renderer instead. ObjC paths (cocoa/videotoolbox-gl/ios-gl) are disabled —
# Foundation pulls in the jailbreak's broken xpc/session.h (same wall ffmpeg's videotoolbox probe hit).

SUBPROJECTS  += mpv
MPV_VERSION  := 0.36.0
DEB_MPV_V    ?= $(MPV_VERSION)+ios2

mpv-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://github.com/mpv-player/mpv/archive/refs/tags/v$(MPV_VERSION).tar.gz)
	$(call EXTRACT_TAR,v$(MPV_VERSION).tar.gz,mpv-$(MPV_VERSION),mpv)
	# Darwin/iOS portability shim (pipe2), force-included into every mpv C TU via c_args below.
	cp $(BUILD_INFO)/mpv-compat.h $(BUILD_WORK)/mpv/mpv-compat.h
	$(call DO_PATCH,mpv,mpv,-p1)
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

	# GPU Wayland launch wrapper + its .desktop. mpv links /var/jb/lib/angle/libEGL.dylib
	# (the iosc wayland-egl->ANGLE/Metal->IOSurface shim shipped by the angle deb), so the
	# wrapper just carries the render env kgx uses and forces the wayland GL VO. Plain
	# shell scripts (not Mach-O) so SIGN below skips them.
	cp $(BUILD_INFO)/mpv-iosc $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/mpv-iosc
	chmod 0755 $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/bin/mpv-iosc
	mkdir -p $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications
	cp $(BUILD_INFO)/mpv-iosc.desktop \
		$(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/mpv-iosc.desktop
	chmod 0644 $(BUILD_DIST)/mpv/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/applications/mpv-iosc.desktop

	$(call SIGN,mpv,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,mpv,DEB_MPV_V)
	rm -rf $(BUILD_DIST)/mpv

.PHONY: mpv mpv-package
