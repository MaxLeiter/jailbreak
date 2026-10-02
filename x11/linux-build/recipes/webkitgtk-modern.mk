ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# WebKitGTK 2.54 (GTK3 API 4.1) for the Epiphany 43 / Geary 46 lane, built with the OPT-IN
# clang-19 + libc++-19-headers toolchain (tools/xios-clang19-env.sh, "mode B"). This recipe is a
# sibling of webkitgtk.mk (2.44.4, clang 14): separate SUBPROJECT, build_work/build_stage dirs,
# patch dir (ports/webkitgtk-modern) and variable names, so neither can disturb the other. It
# produces the SAME four package names at a higher version (2.54.0+ios1); only one producer is
# published. Plan and evidence: docs/webkitgtk-toolchain-plan.md.
#
# Driver: build-webkit-modern.sh (sources the toolchain env, stages this patch stack, then runs
# build-gnome.sh for the targets). XIOS_CC19/XIOS_CXX19/XIOS_AR19/XIOS_RANLIB19 come from the env.
#
# 2.54 renders with Skia only (no Cairo path); JIT stays off with the C-loop interpreter exactly as
# in the 2.44 recipe (JIT/hardware-GL work lives in a separate dormant lane, patches 0015-0018).

SUBPROJECTS            += webkitgtk-modern
WEBKITGTK_MODERN_VERSION := 2.54.0
# Immutable commit of tag webkitgtk-2.54.0 (peeled), used to hydrate the files the release
# tarball prunes for Apple ports.
WEBKITGTK_MODERN_COMMIT  := 5220e80b97a253c60ed899361654142ab5021998
DEB_WEBKITGTK_MODERN_V   ?= $(WEBKITGTK_MODERN_VERSION)+ios1
WEBKIT_NINJA_JOBS        ?= 6

# Hydration must happen BEFORE the patch stack: patches 0006 etc. edit files the tarball prunes
# (the "silent-skip trap": DO_PATCH only reports the last patch's exit status).
webkitgtk-modern-setup: setup
	$(call DOWNLOAD_FILES,$(BUILD_SOURCE),https://webkitgtk.org/releases/webkitgtk-$(WEBKITGTK_MODERN_VERSION).tar.xz)
	$(call EXTRACT_TAR,webkitgtk-$(WEBKITGTK_MODERN_VERSION).tar.xz,webkitgtk-$(WEBKITGTK_MODERN_VERSION),webkitgtk-modern)
	bash /work/recipes/hydrate-webkit-apple-sources-modern.sh $(BUILD_WORK)/webkitgtk-modern $(WEBKITGTK_MODERN_COMMIT)
	$(call DO_PATCH,webkitgtk-modern,webkitgtk-modern,-p1)
	@# Fail loudly if any patch did not apply (.rej files).
	@if find $(BUILD_WORK)/webkitgtk-modern -name '*.rej' | grep -q .; then \
		echo "ERROR: webkitgtk-modern patch stack left rejects"; \
		find $(BUILD_WORK)/webkitgtk-modern -name '*.rej'; exit 1; fi

webkitgtk-modern-configure: webkitgtk-modern-setup
	bash /work/recipes/stage-webkitgtk-deps.sh $(BUILD_BASE)
	# Keep CMake/Ninja's build tree so a failed 1,600-step engine build can resume
	# after a narrow source patch. Version changes are handled by EXTRACT_TAR.
	# WebKit's FindWayland selects the target scanner from BUILD_BASE when
	# cross-compiling, then tries to execute that arm64 Mach-O on Linux. Use
	# Wayland's version-matched build-machine scanner for protocol codegen.
	# The first WebGL revision stays in WebKitWebProcess. GTK's 2.44 port maps
	# ENABLE_WEBGL to its bundled ANGLE implementation; a separate GPU process
	# is not required for initial context/rendering proof.
	cd $(BUILD_WORK)/webkitgtk-modern && cmake -S . -B build -GNinja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DCMAKE_C_COMPILER=$(XIOS_CC19) \
		-DCMAKE_CXX_COMPILER=$(XIOS_CXX19) \
		-DCMAKE_AR=$(XIOS_AR19) \
		-DCMAKE_RANLIB=$(XIOS_RANLIB19) \
		-DPORT=GTK \
		-DCMAKE_BUILD_TYPE=Release \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
		-DWAYLAND_SCANNER=$(BUILD_WORK)/wayland/native-root/bin/wayland-scanner \
		-DGETTEXT_MSGFMT_EXECUTABLE=/usr/bin/msgfmt \
		-DGETTEXT_MSGMERGE_EXECUTABLE=/usr/bin/msgmerge \
		-DUSE_GSTREAMER=OFF \
		-DGLIB_COMPILE_RESOURCES_EXECUTABLE=/usr/bin/glib-compile-resources \
		-DUSE_SYSTEM_SYSPROF_CAPTURE=OFF \
		-DUSE_SYSPROF_CAPTURE=OFF \
		-DUSE_SYSTEM_UNIFDEF=ON \
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
		-DENABLE_WEBGL=ON \
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

ifneq ($(wildcard $(BUILD_WORK)/webkitgtk-modern/.build_complete),)
webkitgtk-modern:
	@echo "Using previously built WebKitGTK."
else
webkitgtk-modern: webkitgtk-modern-configure
	cd $(BUILD_WORK)/webkitgtk-modern && ninja -C build -j$(WEBKIT_NINJA_JOBS) WebKit
	+DESTDIR="$(BUILD_STAGE)/webkitgtk-modern" ninja -C $(BUILD_WORK)/webkitgtk-modern/build install
	$(call AFTER_BUILD,copy)
endif

webkitgtk-modern-wtf: webkitgtk-modern-configure
	cd $(BUILD_WORK)/webkitgtk-modern && ninja -C build -j$(WEBKIT_NINJA_JOBS) WTF

webkitgtk-modern-jsc: webkitgtk-modern-configure
	cd $(BUILD_WORK)/webkitgtk-modern && ninja -C build -j$(WEBKIT_NINJA_JOBS) JavaScriptCore

webkitgtk-modern-webcore: webkitgtk-modern-configure
	cd $(BUILD_WORK)/webkitgtk-modern && ninja -C build -j$(WEBKIT_NINJA_JOBS) WebCore

webkitgtk-modern-webkit: webkitgtk-modern-configure
	cd $(BUILD_WORK)/webkitgtk-modern && ninja -C build -j$(WEBKIT_NINJA_JOBS) WebKit

webkitgtk-modern-package: webkitgtk-modern-stage
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
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjavascriptcoregtk-4.1.0*.dylib \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -f "$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1/jsc" ]; then \
		mkdir -p $(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
		cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1/jsc \
			$(BUILD_DIST)/libjavascriptcoregtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
	fi

	# JavaScriptCore development headers, pkg-config file and linker symlink.
	mkdir -p $(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/JavaScriptCore \
		$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/jsc \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libjavascriptcoregtk-4.1.dylib \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/javascriptcoregtk-4.1.pc \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	# WebKitGTK runtime: versioned library, web/network processes, injected
	# bundle and translations.
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebkit2gtk-4.1.0*.dylib \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	if [ -d "$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/webkit2gtk-4.1" ]; then \
		cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/webkit2gtk-4.1 \
			$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib; \
	fi
	if [ -d "$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1" ]; then \
		mkdir -p $(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
		cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1/WebKit* \
			$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/libexec/webkit2gtk-4.1; \
	fi
	if [ -d "$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale" ]; then \
		mkdir -p $(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
		cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share/locale \
			$(BUILD_DIST)/libwebkit2gtk-4.1-0/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/share; \
	fi

	# Procursus links target Mach-O files through libiosexec using @rpath, but
	# WebKit's install step strips its build-tree rpaths. Give the JSC shell,
	# helper processes, and runtime libraries a stable rootless lookup path
	# before SIGN; otherwise the helpers abort before JavaScript/WebKit starts.
	for root in \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-0 \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0; do \
		find $$root -type f -exec sh -c 'file "$$1" | grep -q "Mach-O" && \
			$(I_N_T) -add_rpath $(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib "$$1" 2>/dev/null || true' sh {} \;; \
	done

	# WebKitGTK and web-extension development surfaces.
	mkdir -p $(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/webkit \
		$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/webkit2 \
		$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1/webkitdom \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/include/webkitgtk-4.1
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/libwebkit2gtk-4.1.dylib \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib
	cp -a $(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/webkit2gtk-4.1.pc \
		$(BUILD_STAGE)/webkitgtk-modern/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig/webkit2gtk-web-extension-4.1.pc \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev/$(MEMO_PREFIX)$(MEMO_SUB_PREFIX)/lib/pkgconfig

	$(call SIGN,libjavascriptcoregtk-4.1-0,general.xml)
	# WebGL's bundled ANGLE backend opens AGX/IOGPU from WebKitWebProcess.
	# The GPU-client profile deliberately excludes Procursus general.xml's
	# no-container entitlement, which prevents graphics user-client access.
	$(call SIGN,libwebkit2gtk-4.1-0,iosc-gpu-client-ent.xml,,,nogeneral)
	$(call PACK,libjavascriptcoregtk-4.1-0,DEB_WEBKITGTK_MODERN_V)
	$(call PACK,libjavascriptcoregtk-4.1-dev,DEB_WEBKITGTK_MODERN_V)
	$(call PACK,libwebkit2gtk-4.1-0,DEB_WEBKITGTK_MODERN_V)
	$(call PACK,libwebkit2gtk-4.1-dev,DEB_WEBKITGTK_MODERN_V)

	rm -rf $(BUILD_DIST)/libjavascriptcoregtk-4.1-0 \
		$(BUILD_DIST)/libjavascriptcoregtk-4.1-dev \
		$(BUILD_DIST)/libwebkit2gtk-4.1-0 \
		$(BUILD_DIST)/libwebkit2gtk-4.1-dev

.PHONY: webkitgtk-modern webkitgtk-modern-setup webkitgtk-modern-configure webkitgtk-modern-wtf webkitgtk-modern-jsc \
	webkitgtk-modern-webcore webkitgtk-modern-webkit webkitgtk-modern-package
