ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# WebKitGTK 4.1 configure/engine-first port for the Geary 46 lane.
#
# This deliberately exposes configure and component targets before the package
# target. WebKit is too large to hide host-tool, process-model, and iOS
# portability failures behind one opaque build. The first milestone uses GTK3 +
# Cairo, keeps both X11 and Wayland backends, and selects JavaScriptCore's C-loop
# interpreter because executable-memory JIT tiers are not a credible default for
# a rootless iOS package.

SUBPROJECTS       += webkitgtk
# 2.46+ switched to C++23 constructs that the current iOS cctools Clang 14
# misparses. Geary 46 only requires WebKitGTK 4.1 >= 2.30, so use the newest
# C++20 release line and keep the compiler upgrade as a separate toolchain job.
WEBKITGTK_VERSION := 2.44.4
WEBKITGTK_COMMIT  := e4715b88387c15a3ff8b7cc7a2efbde89c484710
DEB_WEBKITGTK_V   ?= $(WEBKITGTK_VERSION)+ios1

webkitgtk-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://webkitgtk.org/releases/webkitgtk-$(WEBKITGTK_VERSION).tar.xz)
	$(call EXTRACT_TAR,webkitgtk-$(WEBKITGTK_VERSION).tar.xz,webkitgtk-$(WEBKITGTK_VERSION),webkitgtk)
	$(call DO_PATCH,webkitgtk,webkitgtk,-p1)

webkitgtk-configure: webkitgtk-setup
	bash /work/recipes/stage-webkitgtk-deps.sh $(BUILD_BASE)
	bash /work/recipes/hydrate-webkit-apple-sources.sh $(BUILD_WORK)/webkitgtk $(WEBKITGTK_COMMIT)
	# Keep CMake/Ninja's build tree so a failed 1,600-step engine build can resume
	# after a narrow source patch. Version changes are handled by EXTRACT_TAR.
	# WebKit's FindWayland selects the target scanner from BUILD_BASE when
	# cross-compiling, then tries to execute that arm64 Mach-O on Linux. Use
	# Wayland's version-matched build-machine scanner for protocol codegen.
	cd $(BUILD_WORK)/webkitgtk && cmake -S . -B build -GNinja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DPORT=GTK \
		-DCMAKE_BUILD_TYPE=Release \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DWAYLAND_SCANNER=$(BUILD_WORK)/wayland/native-root/bin/wayland-scanner \
		-DUSE_APPLE_ICU=OFF \
		-DUSE_GTK4=OFF \
		-DENABLE_QUARTZ_TARGET=OFF \
		-DENABLE_WAYLAND_TARGET=ON \
		-DENABLE_X11_TARGET=ON \
		-DENABLE_INTROSPECTION=OFF \
		-DENABLE_DOCUMENTATION=OFF \
		-DENABLE_API_TESTS=OFF \
		-DENABLE_LAYOUT_TESTS=OFF \
		-DENABLE_MINIBROWSER=OFF \
		-DENABLE_WEBDRIVER=OFF \
		-DENABLE_BUBBLEWRAP_SANDBOX=OFF \
		-DENABLE_JOURNALD_LOG=OFF \
		-DENABLE_GAMEPAD=OFF \
		-DENABLE_SPEECH_SYNTHESIS=OFF \
		-DUSE_GBM=OFF \
		-DUSE_LIBDRM=OFF \
		-DENABLE_GPU_PROCESS=OFF \
		-DENABLE_WEBGL=OFF \
		-DENABLE_VIDEO=OFF \
		-DENABLE_WEB_AUDIO=OFF \
		-DENABLE_MEDIA_STREAM=OFF \
		-DENABLE_MEDIA_RECORDER=OFF \
		-DENABLE_WEB_CODECS=OFF \
		-DENABLE_WEB_RTC=OFF \
		-DENABLE_ENCRYPTED_MEDIA=OFF \
		-DENABLE_PDFJS=OFF \
		-DENABLE_SPELLCHECK=OFF \
		-DUSE_AVIF=OFF \
		-DUSE_JPEGXL=OFF \
		-DUSE_WOFF2=OFF \
		-DUSE_LCMS=OFF \
		-DUSE_LIBHYPHEN=OFF \
		-DUSE_LIBBACKTRACE=OFF \
		-DUSE_LIBSECRET=ON \
		-DENABLE_XSLT=ON \
		-DENABLE_JIT=OFF \
		-DENABLE_DFG_JIT=OFF \
		-DENABLE_FTL_JIT=OFF \
		-DENABLE_WEBASSEMBLY=OFF \
		-DENABLE_WEBASSEMBLY_BBQJIT=OFF \
		-DENABLE_WEBASSEMBLY_OMGJIT=OFF \
		-DENABLE_SAMPLING_PROFILER=OFF \
		-DENABLE_C_LOOP=ON

ifneq ($(wildcard $(BUILD_WORK)/webkitgtk/.build_complete),)
webkitgtk:
	@echo "Using previously built WebKitGTK."
else
webkitgtk: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 WebKit
	+DESTDIR="$(BUILD_STAGE)/webkitgtk" ninja -C $(BUILD_WORK)/webkitgtk/build install
	$(call AFTER_BUILD,copy)
endif

webkitgtk-wtf: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 WTF

webkitgtk-jsc: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 JavaScriptCore

webkitgtk-webcore: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 WebCore

webkitgtk-webkit: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 WebKit

webkitgtk-package: webkitgtk-stage
	rm -rf $(BUILD_DIST)/libjavascriptcoregtk-4.1-0 \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0 \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev
	mkdir -p \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# JavaScriptCore runtime: versioned library plus the command-line shell.
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjavascriptcoregtk-4.1.0*.dylib \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -f "$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1/jsc" ]; then \
		mkdir -p $(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
		cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1/jsc \
			$(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
	fi

	# JavaScriptCore development headers, pkg-config file and linker symlink.
	mkdir -p $(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/JavaScriptCore \
		$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/jsc \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjavascriptcoregtk-4.1.dylib \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/javascriptcoregtk-4.1.pc \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# WebKitGTK runtime: versioned library, web/network processes, injected
	# bundle and translations.
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebkit2gtk-4.1.0*.dylib \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/webkit2gtk-4.1" ]; then \
		cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/webkit2gtk-4.1 \
			$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1" ]; then \
		mkdir -p $(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
		cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1/WebKit* \
			$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
	fi
	if [ -d "$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale" ]; then \
		mkdir -p $(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale \
			$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# WebKitGTK and web-extension development surfaces.
	mkdir -p $(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/webkit \
		$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/webkit2 \
		$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/webkitdom \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebkit2gtk-4.1.dylib \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/webkit2gtk-4.1.pc \
		$(BUILD_STAGE)/webkitgtk/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/webkit2gtk-web-extension-4.1.pc \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	$(call SIGN,libjavascriptcoregtk-4.1-0,general.xml)
	$(call SIGN,libwebkit2gtk-4.1-0,general.xml)
	$(call PACK,libjavascriptcoregtk-4.1-0,DEB_WEBKITGTK_V)
	$(call PACK,libjavascriptcoregtk-4.1-dev,DEB_WEBKITGTK_V)
	$(call PACK,libwebkit2gtk-4.1-0,DEB_WEBKITGTK_V)
	$(call PACK,libwebkit2gtk-4.1-dev,DEB_WEBKITGTK_V)

	rm -rf $(BUILD_DIST)/libjavascriptcoregtk-4.1-0 \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0 \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev

.PHONY: webkitgtk webkitgtk-setup webkitgtk-configure webkitgtk-wtf webkitgtk-jsc \
	webkitgtk-webcore webkitgtk-webkit webkitgtk-package
