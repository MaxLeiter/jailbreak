ifneq ($(PROCURSUS),1)
$(error Use the main Makefile)
endif

# WebKitGTK 4.1 configure/engine-first port for the Geary 46 lane.
#
# This deliberately exposes configure, WTF, and JavaScriptCore targets before a
# package target. WebKit is too large to hide host-tool, process-model, and iOS
# portability failures behind a speculative package recipe. The first milestone
# uses GTK3 + Cairo, keeps both X11 and Wayland backends, and selects
# JavaScriptCore's C-loop interpreter because executable-memory JIT tiers are not
# a credible default for a rootless iOS package.

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
	cd $(BUILD_WORK)/webkitgtk && cmake -S . -B build -GNinja \
		$(DEFAULT_CMAKE_FLAGS) \
		-DPORT=GTK \
		-DCMAKE_BUILD_TYPE=Release \
		-DPKG_CONFIG_EXECUTABLE=$(BUILD_TOOLS)/cross-pkg-config \
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

webkitgtk: webkitgtk-configure
	@echo "WebKitGTK configure milestone complete; compile/package targets are intentionally not enabled yet."

webkitgtk-wtf: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 WTF

webkitgtk-jsc: webkitgtk-configure
	cd $(BUILD_WORK)/webkitgtk && ninja -C build -j4 JavaScriptCore

.PHONY: webkitgtk webkitgtk-setup webkitgtk-configure webkitgtk-wtf webkitgtk-jsc
